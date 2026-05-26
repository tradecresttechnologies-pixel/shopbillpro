// supabase/functions/shop-sitemap/index.ts
//
// v8.0 — Public sitemap for shop websites.
//
// HOW THIS IS REACHED
//   vercel.json rewrites /sitemap-shops.xml → this function.
//
// WHAT IT RETURNS
//   A standard sitemap.xml listing every published shop. For shops with
//   a connected custom_domain (active), the custom-domain URL is the
//   primary entry; the /s/{slug} URL is omitted (avoids duplicate-content
//   penalty since Google would see two URLs with same content).
//
// CACHE
//   Cache-Control: public, s-maxage=3600 (1 hour)
//   Sitemaps don't need to be real-time. Crawlers re-fetch hourly.
//
// REQUIRED SECRETS
//   SUPABASE_URL, SUPABASE_ANON_KEY (auto-set)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")      ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const APP_ORIGIN = "https://app.shopbillpro.in";

function escXml(s: unknown): string {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

function isoDate(d: unknown): string {
  if (!d) return new Date().toISOString().slice(0, 10);
  try {
    return new Date(String(d)).toISOString().slice(0, 10);
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin":  "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
      },
    });
  }
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("method_not_allowed", { status: 405 });
  }
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return new Response("misconfigured", { status: 500 });
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const { data, error } = await sb.rpc("sbp_public_shop_sitemap");

  if (error) {
    console.error("[shop-sitemap] RPC error:", error);
    return new Response("rpc_error", { status: 500 });
  }

  const rows: Array<{ slug: string; custom_domain: string | null; updated_at: string | null }> =
    Array.isArray(data) ? data : [];

  const urls: string[] = [];
  for (const r of rows) {
    if (!r.slug) continue;
    const lastmod = isoDate(r.updated_at);

    // If a custom_domain is active, use that as the canonical URL.
    // The /s/{slug} alias still works but isn't in the sitemap (avoids
    // duplicate-content signal to Google).
    if (r.custom_domain && /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(r.custom_domain)) {
      urls.push(
        `  <url>\n` +
        `    <loc>https://${escXml(r.custom_domain)}/</loc>\n` +
        `    <lastmod>${escXml(lastmod)}</lastmod>\n` +
        `    <changefreq>weekly</changefreq>\n` +
        `    <priority>0.7</priority>\n` +
        `  </url>`
      );
    } else {
      urls.push(
        `  <url>\n` +
        `    <loc>${APP_ORIGIN}/s/${escXml(r.slug)}</loc>\n` +
        `    <lastmod>${escXml(lastmod)}</lastmod>\n` +
        `    <changefreq>weekly</changefreq>\n` +
        `    <priority>0.7</priority>\n` +
        `  </url>`
      );
    }
  }

  const xml =
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
    urls.join("\n") + "\n" +
    `</urlset>\n`;

  return new Response(xml, {
    status: 200,
    headers: {
      "Content-Type":  "application/xml; charset=utf-8",
      "Cache-Control": "public, s-maxage=3600, stale-while-revalidate=7200",
    },
  });
});
