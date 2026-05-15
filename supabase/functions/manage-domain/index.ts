// supabase/functions/manage-domain/index.ts
//
// Fully automated custom domain management via Vercel API.
// No manual steps required — this function:
//   • Adds domains to your Vercel project (action='connect')
//   • Checks if DNS has propagated (action='verify')
//   • Removes domains from Vercel (action='disconnect')
//
// Required Supabase Edge Function Secrets (set via Supabase Dashboard):
//   VERCEL_API_TOKEN   — from vercel.com/account/tokens
//   VERCEL_PROJECT_ID  — from vercel.com → project → Settings → General
//
// Called from website-builder.html (authenticated shop owner only).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY    = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const VERCEL_API_TOKEN     = Deno.env.get("VERCEL_API_TOKEN") ?? "";
const VERCEL_PROJECT_ID    = Deno.env.get("VERCEL_PROJECT_ID") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ── Vercel API helpers ──────────────────────────────────────────────

async function vercelRequest(method: string, path: string, body?: unknown) {
  const res = await fetch(`https://api.vercel.com${path}`, {
    method,
    headers: {
      "Authorization": `Bearer ${VERCEL_API_TOKEN}`,
      "Content-Type":  "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  const text = await res.text();
  let data: Record<string, unknown> = {};
  try { data = JSON.parse(text); } catch { data = { raw: text }; }

  return { status: res.status, ok: res.status >= 200 && res.status < 300, data };
}

async function addDomainToVercel(domain: string) {
  // Add both apex and www variants so either works
  const apexRes = await vercelRequest(
    "POST",
    `/v10/projects/${VERCEL_PROJECT_ID}/domains`,
    { name: domain }
  );

  // Also add www. variant (ignore error if already exists)
  await vercelRequest(
    "POST",
    `/v10/projects/${VERCEL_PROJECT_ID}/domains`,
    { name: `www.${domain}` }
  ).catch(() => {});

  return apexRes;
}

async function getDomainFromVercel(domain: string) {
  return vercelRequest(
    "GET",
    `/v9/projects/${VERCEL_PROJECT_ID}/domains/${domain}`
  );
}

async function removeDomainFromVercel(domain: string) {
  // Remove both apex and www variants
  const apexRes = await vercelRequest(
    "DELETE",
    `/v9/projects/${VERCEL_PROJECT_ID}/domains/${domain}`
  );
  await vercelRequest(
    "DELETE",
    `/v9/projects/${VERCEL_PROJECT_ID}/domains/www.${domain}`
  ).catch(() => {});
  return apexRes;
}

// ── DNS instructions builder ────────────────────────────────────────

function buildDnsInstructions(domain: string) {
  return {
    summary: `Add these DNS records in your domain registrar (GoDaddy / Namecheap / Hostinger):`,
    records: [
      {
        type: "CNAME",
        name: "www",
        value: "cname.vercel-dns.com",
        ttl: "Auto",
        note: "For www.${domain} — works with all registrars"
      },
      {
        type: "A",
        name: "@",
        value: "76.76.21.21",
        ttl: "Auto",
        note: "For root domain (${domain}) — Vercel's IP"
      }
    ],
    note: "DNS changes take 5–60 minutes to propagate. Click 'Check Status' after updating.",
    helpful: {
      godaddy:   "My Products → DNS → Add Record",
      namecheap: "Domain List → Manage → Advanced DNS → Add New Record",
      hostinger: "Domains → Manage → DNS / Nameservers → Add Record"
    }
  };
}

// ── Main handler ────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  // Verify credentials are configured
  if (!VERCEL_API_TOKEN || VERCEL_API_TOKEN.length < 10) {
    return json({
      ok: false,
      error: "vercel_token_not_configured",
      message: "Add VERCEL_API_TOKEN to Supabase Edge Function Secrets."
    }, 500);
  }
  if (!VERCEL_PROJECT_ID || !VERCEL_PROJECT_ID.startsWith("prj_")) {
    return json({
      ok: false,
      error: "vercel_project_id_not_configured",
      message: "Add VERCEL_PROJECT_ID to Supabase Edge Function Secrets."
    }, 500);
  }

  // Auth check — must be an authenticated shop owner
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ ok: false, error: "no_auth" }, 401);
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const sbAdmin = SUPABASE_SERVICE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)
    : null;

  // Get caller's shop_id
  const shopRes = await sb.from("shops").select("id").limit(1).single();
  if (shopRes.error || !shopRes.data?.id) {
    return json({ ok: false, error: "no_shop" }, 401);
  }
  const shopId = shopRes.data.id as string;

  const body = await req.json().catch(() => ({}));
  const { action, domain } = body as { action: string; domain: string };

  if (!action) return json({ ok: false, error: "missing_action" }, 400);

  // ── ACTION: connect ──────────────────────────────────────────────
  if (action === "connect") {
    if (!domain) return json({ ok: false, error: "missing_domain" }, 400);

    console.log(`[manage-domain] connect: ${domain} for shop ${shopId}`);

    // Step 1: Add to Vercel
    const vercelRes = await addDomainToVercel(domain);
    console.log(`[manage-domain] Vercel add status: ${vercelRes.status}`, vercelRes.data);

    // Vercel returns 409 if domain already exists in project — treat as success
    const vercelOk = vercelRes.ok || vercelRes.status === 409;

    if (!vercelOk) {
      // Try to extract a friendly error
      const errMsg = (vercelRes.data as { error?: { message?: string } })?.error?.message
        ?? `Vercel API error ${vercelRes.status}`;
      console.error(`[manage-domain] Vercel error:`, errMsg);
      return json({ ok: false, error: "vercel_error", message: errMsg });
    }

    // Step 2: Check if Vercel already sees DNS as configured
    const checkRes = await getDomainFromVercel(domain);
    const isConfigured = (checkRes.data as { configured?: boolean })?.configured === true;

    // Step 3: Update DB status
    const newStatus = isConfigured ? "active" : "pending_dns";
    if (sbAdmin) {
      await sbAdmin.rpc("sbp_update_custom_domain_status", {
        p_shop_id:   shopId,
        p_domain:    domain,
        p_status:    newStatus,
        p_vercel_id: (vercelRes.data as { id?: string })?.id ?? null,
      });
    }

    return json({
      ok:          true,
      domain,
      status:      newStatus,
      configured:  isConfigured,
      dns_instructions: isConfigured ? null : buildDnsInstructions(domain),
      message: isConfigured
        ? `✅ Domain ${domain} is connected and live!`
        : `Domain added to Vercel. Now update your DNS records as shown.`,
    });
  }

  // ── ACTION: verify ───────────────────────────────────────────────
  if (action === "verify") {
    if (!domain) return json({ ok: false, error: "missing_domain" }, 400);

    console.log(`[manage-domain] verify: ${domain} for shop ${shopId}`);

    const checkRes = await getDomainFromVercel(domain);
    const isConfigured = (checkRes.data as { configured?: boolean })?.configured === true;
    const isVerified   = (checkRes.data as { verified?: boolean })?.verified === true;

    const newStatus = isConfigured ? "active" : "pending_dns";

    // Update DB
    if (sbAdmin) {
      await sbAdmin.rpc("sbp_update_custom_domain_status", {
        p_shop_id:   shopId,
        p_domain:    domain,
        p_status:    newStatus,
        p_vercel_id: null,
      });
    }

    return json({
      ok:         true,
      domain,
      status:     newStatus,
      configured: isConfigured,
      verified:   isVerified,
      message: isConfigured
        ? `✅ ${domain} is live! SSL certificate will be ready in a few minutes.`
        : `⏳ DNS not yet propagated. This can take up to 60 minutes. Try again soon.`,
      dns_instructions: isConfigured ? null : buildDnsInstructions(domain),
    });
  }

  // ── ACTION: disconnect ───────────────────────────────────────────
  if (action === "disconnect") {
    if (!domain) return json({ ok: false, error: "missing_domain" }, 400);

    console.log(`[manage-domain] disconnect: ${domain} for shop ${shopId}`);

    // Remove from Vercel
    const removeRes = await removeDomainFromVercel(domain);
    console.log(`[manage-domain] Vercel remove status: ${removeRes.status}`);

    // Update DB (regardless of Vercel response — domain might already be removed)
    if (sbAdmin) {
      await sbAdmin.rpc("sbp_update_custom_domain_status", {
        p_shop_id:   shopId,
        p_domain:    domain,
        p_status:    "removed",
        p_vercel_id: null,
      });
    }

    return json({
      ok:      true,
      domain,
      status:  "removed",
      message: `${domain} has been disconnected from your website.`,
    });
  }

  return json({ ok: false, error: "unknown_action", action }, 400);
});
