// supabase/functions/generate-ai-website/index.ts
// Real Deno Edge Function (NOT a string wrapped in JS).
//
// Generates an HTML website via Claude API, then records it via the
// sbp_record_ai_website_generation RPC. Quota enforcement happens
// server-side inside that RPC (defense in depth).
//
// Deploy:
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//   supabase functions deploy generate-ai-website --no-verify-jwt=false
//
// Caller must include the user's JWT in Authorization header
// (the supabase-js client does this automatically when invoked via
//  _sb.functions.invoke).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const SUPABASE_URL      = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function buildClaudePrompt(p: Record<string, string>): string {
  return `You are an expert web designer. Generate a single self-contained HTML5 website.

BUSINESS:
- Name: ${p.shop_name}
- Type: ${p.business_type}
- Headline: ${p.headline}
- Description: ${p.description}
- Style: ${p.design_style}

COLORS (use exactly these):
- Primary: ${p.color_primary} (${p.color_primary_hex})
- Accent:  ${p.color_accent}  (${p.color_accent_hex})

REQUIREMENTS:
- Single HTML file. All CSS inside one <style> tag. No external CSS/JS frameworks.
- Mobile-first responsive. Works at 320px width.
- WCAG AA contrast on text.
- Sections: sticky header with shop name, hero with headline + CTA, services/products list (3-6 items inferred from business type), about block, contact (WhatsApp + email + address placeholders), footer with "Powered by ShopBill Pro".
- Use ${p.color_primary_hex} for header/hero background. Use ${p.color_accent_hex} for buttons and links.
- Clean Outfit/Inter style typography (use system-ui font stack).
- No JavaScript needed beyond a smooth-scroll snippet.
- Output ONLY the raw HTML, starting with <!DOCTYPE html>. No markdown fences, no commentary.`;
}

async function callClaude(prompt: string): Promise<string> {
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
  // strip code fences if Claude wrapped output despite instructions
  const m = html.match(/```html\s*([\s\S]*?)```/i);
  if (m) html = m[1].trim();
  if (!html.startsWith("<!DOCTYPE") && !html.startsWith("<html")) {
    throw new Error("claude_invalid_html");
  }
  return html;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

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

    // Per-user supabase client (carries user JWT — RPC sees auth.uid())
    const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    // 1. Pre-flight quota check (server source of truth)
    const stateResp = await sb.rpc("sbp_get_website_builder_state");
    if (stateResp.error) throw new Error("state_rpc_failed: " + stateResp.error.message);
    const state = stateResp.data as { ok: boolean; tier?: { can_generate?: boolean; block_reason?: string } };
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

    // 2. Generate HTML
    const html = await callClaude(buildClaudePrompt(body));

    // 3. Record via RPC (also re-checks quota, atomic with counter increment)
    const recResp = await sb.rpc("sbp_record_ai_website_generation", {
      p_payload: {
        generated_html:    html,
        design_style:      body.design_style,
        color_primary:     body.color_primary,
        color_primary_hex: body.color_primary_hex,
        color_accent:      body.color_accent,
        color_accent_hex:  body.color_accent_hex,
        headline:          body.headline,
        description:       body.description,
        business_type:     body.business_type,
        provider:          "claude",
      },
    });

    if (recResp.error) throw new Error("record_rpc_failed: " + recResp.error.message);
    if (!recResp.data?.ok) {
      return new Response(JSON.stringify(recResp.data), {
        status: 402,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({
        ok: true,
        website_id: recResp.data.website_id,
        slug:       recResp.data.slug,
        html_length: html.length,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("generate-ai-website error:", msg);
    return new Response(
      JSON.stringify({ ok: false, error: "generation_failed", message: msg }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
