// supabase/functions/generate-ai-website/index.ts  (v3.5 — HIGHLIGHTS_DATA token for prompt v4 / migration 087.1+088)
//
// Passes {ROOMS_DATA} and {AMENITIES_DATA} to the prompt template.
// The AI builds room cards and amenity lists from the shop owner's real
// data instead of inventing them. Also removes all Claude/Anthropic
// references from the user-facing flow — branding is "ShopBill Pro AI".

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY    = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const ANTHROPIC_ENV_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const GROQ_ENV_KEY      = Deno.env.get("GROQ_API_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const sbAdmin = SUPABASE_SERVICE_KEY
  ? createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)
  : null;

/** Provider name → Vault secret name. Both 'claude' and 'anthropic' map to
 *  anthropic_api_key (Anthropic the company makes Claude the model). */
function vaultKeyFor(provider: string): { keyName: string; envFallback: string } {
  const p = (provider || "").toLowerCase();
  if (p === "groq") {
    return { keyName: "groq_api_key", envFallback: GROQ_ENV_KEY };
  }
  // Default: claude/anthropic
  return { keyName: "anthropic_api_key", envFallback: ANTHROPIC_ENV_KEY };
}

async function getApiKey(provider: string): Promise<string> {
  const { keyName, envFallback } = vaultKeyFor(provider);
  if (sbAdmin) {
    try {
      const { data, error } = await sbAdmin.rpc("_internal_get_ai_secret", { p_key: keyName });
      if (!error && data && typeof data === "string" && data.length > 10) {
        return data;
      }
      if (error) console.error("vault lookup error:", error);
    } catch (e) {
      console.error("vault lookup threw:", e);
    }
  }
  return envFallback;
}

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
    .replaceAll("{COLOR_ACCENT_HEX}",  p.color_accent_hex)
    .replaceAll("{HERO_IMAGE_URL}",    p.hero_image_url || "")
    .replaceAll("{ROOMS_DATA}",        p.rooms_data    || "(none provided — invent 3 plausible rooms)")
    .replaceAll("{AMENITIES_DATA}",    p.amenities_data || "(none provided — invent 6 relevant amenities)")
    .replaceAll("{HIGHLIGHTS_DATA}",   p.highlights_data || "(none provided — invent 3-4 plausible items based on business type)");
}

async function callClaude(prompt: string, apiKey: string): Promise<{ html: string; in_tokens: number; out_tokens: number }> {
  if (!apiKey) throw new Error("anthropic_api_key_missing");

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-20250514",
      max_tokens: 8192,
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

async function callGroq(prompt: string, apiKey: string): Promise<{ html: string; in_tokens: number; out_tokens: number }> {
  if (!apiKey) throw new Error("groq_api_key_missing");

  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "llama-3.3-70b-versatile",
      messages: [{ role: "user", content: prompt }],
      max_tokens: 8192,
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

    // 1b. NEW (v3.2+): Fetch shop generation context (hero photo + v3.3 rooms + amenities)
    let heroImageUrl  = "";
    let roomsData     = "";
    let amenitiesData = "";
    let highlightsData = "";
    if (shopId) {
      try {
        const ctxResp = await sb.rpc("sbp_get_website_generation_context", { p_shop_id: shopId });
        if (!ctxResp.error && ctxResp.data?.ok) {
          heroImageUrl = (ctxResp.data.hero_image_url as string) || "";

          // v3.3: format rooms for prompt
          const rooms = ctxResp.data.rooms as Array<Record<string, string>> || [];
          if (rooms.length > 0) {
            roomsData = rooms.map((r, i) => {
              const parts = [`Room ${i+1}: ${r.name || 'Room'}`];
              if (r.price)       parts.push(`Price: ₹${r.price}/night`);
              if (r.capacity)    parts.push(`Capacity: ${r.capacity} guests`);
              if (r.bed)         parts.push(`Bed: ${r.bed}`);
              if (r.description) parts.push(`Description: ${r.description}`);
              return parts.join(" | ");
            }).join("\n");
          }

          // v3.3: format amenities for prompt
          const amenities = ctxResp.data.amenities as string[] || [];
          if (amenities.length > 0) {
            amenitiesData = amenities.join(", ");
          }

          // v3.5: format highlights for prompt (087.1+088 — universal real data)
          const highlights = ctxResp.data.highlights_data as Array<Record<string, string>> || [];
          if (highlights.length > 0) {
            highlightsData = highlights.map((h, i) => {
              const parts = [`Item ${i+1}: ${h.name || ''}`];
              if (h.price)       parts.push(`Price: ₹${h.price}`);
              if (h.category)    parts.push(`Category: ${h.category}`);
              if (h.description) parts.push(`Description: ${h.description}`);
              return parts.join(" | ");
            }).join("\n");
          }
        } else if (ctxResp.error) {
          console.warn("hero context fetch failed:", ctxResp.error.message);
        }
      } catch (e) {
        console.warn("hero context fetch threw:", e);
      }
    }

    // 2. Fetch active prompt template
    const promptResp = await sb.rpc("get_active_ai_prompt", { p_name: "website_v1" });
    if (promptResp.error || !promptResp.data?.ok) {
      throw new Error("no_active_prompt_template");
    }
    const tplText = promptResp.data.prompt_text as string;
    promptTemplate = `${promptResp.data.name}:v${promptResp.data.version}`;
    providerUsed = promptResp.data.provider ?? "claude";

    const filledPrompt = fillTemplate(tplText, {
      ...body,
      hero_image_url:  heroImageUrl,
      rooms_data:      roomsData,
      amenities_data:  amenitiesData,
      highlights_data: highlightsData,
    });

    // 3. Fetch the right API key — handles 'claude' OR 'anthropic' OR 'groq'
    const apiKey = await getApiKey(providerUsed);
    if (!apiKey) {
      const { keyName } = vaultKeyFor(providerUsed);
      throw new Error(`${keyName}_not_configured`);
    }

    // 4. Call provider
    const p = providerUsed.toLowerCase();
    let result;
    if (p === "groq") {
      result = await callGroq(filledPrompt, apiKey);
    } else {
      result = await callClaude(filledPrompt, apiKey);
    }

    // 5. Record successful generation
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

    // 6. Log success
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
