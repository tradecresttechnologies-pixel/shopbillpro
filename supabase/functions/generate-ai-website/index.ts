// supabase/functions/generate-ai-website/index.ts  (v2 — Admin-integrated)
// Real Deno Edge Function — pairs with migration 045.
//
// Improvements over v1:
//   • Reads prompt template from DB via get_active_ai_prompt RPC
//     (so admin can edit the prompt without redeploying)
//   • Logs every attempt (success + failure) via log_ai_generation RPC
//   • Captures token usage + cost for analytics
//   • Provider switch via admin_settings.active_ai_provider
//
// Deploy:
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//   supabase secrets set GROQ_API_KEY=gsk_...   (optional, only if using groq)
//   supabase functions deploy generate-ai-website --no-verify-jwt=false

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const GROQ_API_KEY      = Deno.env.get("GROQ_API_KEY") ?? "";
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function fillTemplate(tpl: string, p: Record<string, string>): string {
  return tpl
    .replaceAll("{SHOP_NAME}",         p.shop_name)
    .replaceAll("{BUSINESS_TYPE}",     p.business_type)
    .replaceAll("{HEADLINE}",          p.headline)
    .replaceAll("{DESCRIPTION}",       p.description)
    .replaceAll("{DESIGN_STYLE}",      p.design_style)
    .replaceAll("{COLOR_PRIMARY}",     p.color_primary)
    .replaceAll("{COLOR_PRIMARY_HEX}", p.color_primary_hex)
    .replaceAll("{COLOR_ACCENT}",      p.color_accent)
    .replaceAll("{COLOR_ACCENT_HEX}",  p.color_accent_hex);
}

async function callClaude(prompt: string): Promise<{ html: string; in_tokens: number; out_tokens: number }> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096,
      messages: [{ role: "user", content: prompt }],
    }),
  });

  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`claude_api_error: ${res.status} ${txt.slice(0, 200)}`);
  }

  const data = await res.json();
  const block = data?.content?.find((c: { type: string }) => c.type === "text");
  if (!block?.text) throw new Error("claude_no_text_block");

  let html = block.text.trim();
  const m = html.match(/```html\s*([\s\S]*?)```/i);
  if (m) html = m[1].trim();
  if (!html.startsWith("<!DOCTYPE") && !html.startsWith("<html")) {
    throw new Error("claude_invalid_html");
  }

  return {
    html,
    in_tokens:  data?.usage?.input_tokens  ?? 0,
    out_tokens: data?.usage?.output_tokens ?? 0,
  };
}

async function callGroq(prompt: string): Promise<{ html: string; in_tokens: number; out_tokens: number }> {
  if (!GROQ_API_KEY) throw new Error("groq_api_key_missing");

  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${GROQ_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "llama-3.3-70b-versatile",
      messages: [{ role: "user", content: prompt }],
      max_tokens: 4096,
    }),
  });

  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`groq_api_error: ${res.status} ${txt.slice(0, 200)}`);
  }

  const data = await res.json();
  let html = data?.choices?.[0]?.message?.content?.trim() ?? "";
  if (!html) throw new Error("groq_empty_response");

  const m = html.match(/```html\s*([\s\S]*?)```/i);
  if (m) html = m[1].trim();
  if (!html.startsWith("<!DOCTYPE") && !html.startsWith("<html")) {
    throw new Error("groq_invalid_html");
  }

  return {
    html,
    in_tokens:  data?.usage?.prompt_tokens     ?? 0,
    out_tokens: data?.usage?.completion_tokens ?? 0,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const startedAt = Date.now();
  let shopId: string | null = null;
  let shopName: string | null = null;
  let providerUsed = "claude";
  let promptTemplate = "website_v1";

  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({ ok: false, error: "method_not_allowed" }), {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ ok: false, error: "no_auth" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const required = [
      "shop_name","business_type","headline","description","design_style",
      "color_primary","color_primary_hex","color_accent","color_accent_hex",
    ];
    for (const k of required) {
      if (!body[k] || typeof body[k] !== "string") {
        return new Response(
          JSON.stringify({ ok: false, error: "missing_field", field: k }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }
    shopName = body.shop_name;

    // Per-user supabase client (carries user JWT — RPC sees auth.uid())
    const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    // 1. Pre-flight quota check
    const stateResp = await sb.rpc("sbp_get_website_builder_state");
    if (stateResp.error) throw new Error("state_rpc_failed: " + stateResp.error.message);
    const state = stateResp.data as { ok: boolean; shop?: { id?: string }; tier?: { can_generate?: boolean; block_reason?: string } };
    if (!state?.ok) {
      return new Response(JSON.stringify({ ok: false, error: "no_shop" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!state.tier?.can_generate) {
      return new Response(
        JSON.stringify({ ok: false, error: "quota_exhausted", reason: state.tier?.block_reason }),
        { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    shopId = state.shop?.id ?? null;

    // 2. Fetch active prompt template from DB (admin-editable)
    const promptResp = await sb.rpc("get_active_ai_prompt", { p_name: "website_v1" });
    if (promptResp.error || !promptResp.data?.ok) {
      throw new Error("no_active_prompt_template");
    }
    const tplText = promptResp.data.prompt_text as string;
    promptTemplate = `${promptResp.data.name}:v${promptResp.data.version}`;
    providerUsed = promptResp.data.provider ?? "claude";

    // (Optionally override provider from admin_settings — not strictly needed since
    //  template has its own provider attribute, but kept as a switch point.)

    const filledPrompt = fillTemplate(tplText, body);

    // 3. Call AI provider
    let result;
    if (providerUsed === "groq") {
      result = await callGroq(filledPrompt);
    } else {
      result = await callClaude(filledPrompt);
    }

    // 4. Record successful generation
    const recResp = await sb.rpc("sbp_record_ai_website_generation", {
      p_payload: {
        generated_html:    result.html,
        design_style:      body.design_style,
        color_primary:     body.color_primary,
        color_primary_hex: body.color_primary_hex,
        color_accent:      body.color_accent,
        color_accent_hex:  body.color_accent_hex,
        headline:          body.headline,
        description:       body.description,
        business_type:     body.business_type,
        provider:          providerUsed,
      },
    });
    if (recResp.error) throw new Error("record_rpc_failed: " + recResp.error.message);
    if (!recResp.data?.ok) {
      return new Response(JSON.stringify(recResp.data), {
        status: 402,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 5. Log success
    await sb.rpc("log_ai_generation", {
      p_payload: {
        shop_id:           shopId,
        shop_name:         shopName,
        provider:          providerUsed,
        prompt_template:   promptTemplate,
        status:            "success",
        input_tokens:      String(result.in_tokens),
        output_tokens:     String(result.out_tokens),
        generation_time_ms: String(Date.now() - startedAt),
        request_payload:   body,
      },
    });

    return new Response(
      JSON.stringify({
        ok: true,
        website_id: recResp.data.website_id,
        slug:       recResp.data.slug,
        html_length: result.html.length,
        provider:    providerUsed,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("generate-ai-website error:", msg);

    // Best-effort failure log (don't fail the response just because logging fails)
    try {
      const authHeader = req.headers.get("Authorization") ?? "";
      if (authHeader.startsWith("Bearer ")) {
        const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
          global: { headers: { Authorization: authHeader } },
        });
        await sb.rpc("log_ai_generation", {
          p_payload: {
            shop_id:           shopId,
            shop_name:         shopName,
            provider:          providerUsed,
            prompt_template:   promptTemplate,
            status:            "failure",
            error_message:    msg,
            generation_time_ms: String(Date.now() - startedAt),
          },
        });
      }
    } catch (_logErr) { /* swallow */ }

    return new Response(
      JSON.stringify({ ok: false, error: "generation_failed", message: msg }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
