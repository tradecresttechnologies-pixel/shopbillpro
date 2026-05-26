// supabase/functions/shop-page/index.ts
//
// v8.0 — SSR shop website renderer.
//
// HOW THIS IS REACHED
//   vercel.json rewrites /s/:slug → this function. So a request like
//   https://app.shopbillpro.in/s/indian-curry arrives here with the
//   slug in the URL path (or in the ?slug= query string after the
//   Vercel rewrite).
//
// WHAT IT DOES
//   1. Detect crawler via User-Agent (Googlebot, Bingbot, facebookexternalhit,
//      WhatsApp, Twitterbot, LinkedInBot, Slackbot, embedly, etc.)
//   2. Fetch shop data via sbp_resolve_shop_slug RPC (anon key)
//   3. For HUMANS: return the original s.html shell unchanged, with
//      meta tags injected into <head> so when the user shares the URL,
//      preview crawlers (which always re-fetch) see real OG tags.
//      The shell still loads the existing JS for full interactivity.
//   4. For CRAWLERS: return a fully server-rendered page —
//      • Real <title>, description, OG, Twitter Card, canonical
//      • JSON-LD structured data (LocalBusiness / Restaurant / etc.)
//      • Full body content (AI-mode shops: raw ai_html;
//        legacy shops: a server-rendered minimal HTML so Google
//        sees text, not the JS shell)
//
// CACHE
//   Cache-Control: public, s-maxage=300, stale-while-revalidate=600
//   So Vercel's CDN holds for 5 min, serves stale up to 10 min during
//   revalidation. Shop owners republishing wait <5 min.
//
// REQUIRED SECRETS (set via Supabase Edge Function Secrets)
//   SUPABASE_URL                — auto-set by Supabase
//   SUPABASE_ANON_KEY           — auto-set by Supabase
//
// THIS FILE IS SAFE TO SERVE WITH NO AUTH HEADER — it queries via anon.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")      ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const APP_HOST = "app.shopbillpro.in";
const APP_ORIGIN = "https://" + APP_HOST;

// Crawler User-Agent fragments (lowercase match). Conservative list —
// when in doubt we serve human HTML, since humans get correct meta tags too.
const CRAWLER_UA_FRAGMENTS = [
  "googlebot", "bingbot", "slurp", "duckduckbot", "baiduspider",
  "yandex", "facebookexternalhit", "whatsapp", "twitterbot",
  "linkedinbot", "slackbot", "discordbot", "telegrambot",
  "embedly", "applebot", "pinterestbot", "redditbot",
  "petalbot", "ahrefsbot", "semrushbot",
];

function isCrawler(ua: string | null): boolean {
  if (!ua) return false;
  const lower = ua.toLowerCase();
  return CRAWLER_UA_FRAGMENTS.some(f => lower.includes(f));
}

function escHtml(s: unknown): string {
  return String(s == null ? "" : s).replace(/[&<>"']/g, c => (
    { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c] as string
  ));
}

function escAttr(s: unknown): string { return escHtml(s); }

// ── shop_type → Schema.org @type mapping ─────────────────────────────
// Aligned with lib/sidebar-engine.js MACRO_BY_SHOP_TYPE.
// Schema.org @type list: https://schema.org/LocalBusiness
function schemaTypeForShopType(shopType: string | null): string {
  const t = String(shopType || "").toLowerCase();

  // Food / restaurant
  if (["restaurant","cafe","qsr","ice_cream","cloud_kitchen","tiffin",
       "catering","bar_lounge","food_other","bakery_retail"].includes(t)) {
    if (t === "cafe") return "CafeOrCoffeeShop";
    if (t === "bar_lounge") return "BarOrPub";
    if (t === "bakery_retail") return "Bakery";
    if (t === "ice_cream") return "IceCreamShop";
    return "Restaurant";
  }

  // Beauty / wellness
  if (["salon","unisex_salon","nail_beauty"].includes(t)) return "BeautySalon";
  if (t === "spa") return "DaySpa";
  if (["gym","yoga","sports_club","wellness"].includes(t)) return "HealthClub";
  if (t === "tattoo") return "TattooParlor";

  // Healthcare
  if (t === "dentist") return "Dentist";
  if (t === "optician") return "Optician";
  if (t === "vet") return "VeterinaryCare";
  if (t === "lab") return "MedicalClinic";
  if (t === "physio") return "Physiotherapy";
  if (["clinic","counselling"].includes(t)) return "MedicalClinic";

  // Hospitality
  if (["hotel","boutique_hotel"].includes(t)) return "Hotel";
  if (["resort"].includes(t)) return "Resort";
  if (["homestay","guesthouse","service_apartment","hostel",
        "dharamshala","day_room","pg_hostel"].includes(t)) return "LodgingBusiness";
  if (t === "banquet") return "EventVenue";
  if (t === "camping") return "Campground";

  // Retail
  if (t === "jewellery") return "JewelryStore";
  if (t === "garments") return "ClothingStore";
  if (t === "pharmacy") return "Pharmacy";
  if (t === "footwear") return "ShoeStore";
  if (t === "furniture") return "FurnitureStore";
  if (t === "hardware") return "HardwareStore";
  if (t === "mobile_elec") return "ElectronicsStore";
  if (t === "stationery") return "OfficeEquipmentStore";
  if (t === "gift_shop") return "Store";
  if (t === "auto_parts") return "AutoPartsStore";
  if (t === "pet_shop") return "PetStore";
  if (t === "plant_nursery") return "GardenStore";
  if (t === "kirana") return "GroceryStore";
  if (t === "dairy") return "GroceryStore";
  if (t === "fruit_veg") return "GroceryStore";
  if (t === "tea_pan") return "ConvenienceStore";

  // Education
  if (t === "library") return "Library";
  if (t === "driving_school") return "DrivingSchool";
  if (["coaching","art_class","online_course","skill_training",
        "personal_coach"].includes(t)) return "EducationalOrganization";

  // Services
  if (t === "photographer") return "ProfessionalService";
  if (t === "movers") return "MovingCompany";
  if (t === "car_wash") return "AutoWash";
  if (t === "device_repair") return "ProfessionalService";
  if (t === "travel_agent") return "TravelAgency";
  if (t === "cab_transport") return "TaxiService";

  return "LocalBusiness";
}

// ── Build JSON-LD ────────────────────────────────────────────────────
function buildJsonLd(opts: {
  shopName:     string;
  shopType:     string | null;
  description:  string;
  url:          string;
  phone:        string;
  whatsapp:     string;
  email:        string;
  addr:         string;
  city:         string;
  hours:        string;
  photoUrl:     string;
}): string {
  const schemaType = schemaTypeForShopType(opts.shopType);

  const ld: Record<string, unknown> = {
    "@context":  "https://schema.org",
    "@type":     schemaType,
    "name":      opts.shopName,
    "url":       opts.url,
  };

  if (opts.description) ld["description"] = opts.description;
  if (opts.phone)       ld["telephone"]   = opts.phone;
  if (opts.email)       ld["email"]       = opts.email;
  if (opts.photoUrl)    ld["image"]       = opts.photoUrl;

  if (opts.addr || opts.city) {
    ld["address"] = {
      "@type": "PostalAddress",
      "streetAddress":   opts.addr || undefined,
      "addressLocality": opts.city || undefined,
      "addressCountry":  "IN",
    };
  }

  // Opening hours: pass through as-is for crawlers to interpret.
  // (We don't try to parse "Mon-Sat 10AM-9PM" into openingHoursSpecification
  //  — too lossy across the 76 shop verticals. Free-text in description is
  //  fine for Schema.org per their LocalBusiness docs.)
  if (opts.hours) ld["openingHours"] = opts.hours;

  // contactPoint helps for Restaurant/Hotel/Clinic — sameAs for WhatsApp
  // would need verified business profile, skip for now.
  if (opts.whatsapp && opts.whatsapp !== opts.phone) {
    ld["contactPoint"] = {
      "@type": "ContactPoint",
      "telephone": opts.whatsapp,
      "contactType": "customer service",
    };
  }

  return JSON.stringify(ld);
}

// ── Build meta tags block (used for BOTH crawlers and humans) ───────
function buildMetaBlock(opts: {
  title:        string;
  description:  string;
  url:          string;
  canonical:    string;
  photoUrl:     string;
  shopType:     string | null;
  jsonLd:       string;
}): string {
  const ogType = (() => {
    const t = String(opts.shopType || "").toLowerCase();
    if (["restaurant","cafe","qsr","bar_lounge","cloud_kitchen"].includes(t)) {
      return "restaurant.restaurant";
    }
    return "business.business";
  })();

  const img = opts.photoUrl
    ? `<meta property="og:image" content="${escAttr(opts.photoUrl)}">
<meta name="twitter:image" content="${escAttr(opts.photoUrl)}">`
    : "";

  return `<title>${escHtml(opts.title)}</title>
<meta name="description" content="${escAttr(opts.description)}">
<link rel="canonical" href="${escAttr(opts.canonical)}">
<meta property="og:title" content="${escAttr(opts.title)}">
<meta property="og:description" content="${escAttr(opts.description)}">
<meta property="og:url" content="${escAttr(opts.url)}">
<meta property="og:type" content="${ogType}">
<meta property="og:site_name" content="ShopBill Pro">
${img}
<meta name="twitter:card" content="${opts.photoUrl ? "summary_large_image" : "summary"}">
<meta name="twitter:title" content="${escAttr(opts.title)}">
<meta name="twitter:description" content="${escAttr(opts.description)}">
<script type="application/ld+json">${opts.jsonLd}</script>`;
}

// ── 404 / error response ────────────────────────────────────────────
function errorHtml(title: string, message: string, status = 404): Response {
  const body = `<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="noindex">
<title>${escHtml(title)} — ShopBill Pro</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;background:#FAFAFC;color:#0F0E18;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;margin:0}.wrap{max-width:420px;text-align:center}.emoji{font-size:56px;margin-bottom:8px}h1{font-size:24px;font-weight:800;margin:0 0 8px}p{font-size:15px;color:#5E5A7A;line-height:1.55;margin:0 0 20px}a{display:inline-block;background:linear-gradient(135deg,#F5A623,#FF6B35);color:#fff;font-weight:700;padding:12px 24px;border-radius:12px;text-decoration:none}</style>
</head><body><div class="wrap"><div class="emoji">🔎</div><h1>${escHtml(title)}</h1><p>${escHtml(message)}</p><a href="https://shopbillpro.in/">Explore ShopBill Pro</a></div></body></html>`;
  return new Response(body, {
    status,
    headers: {
      "Content-Type":  "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=60",
    },
  });
}

// ── Fetch shop data via RPC ─────────────────────────────────────────
// deno-lint-ignore no-explicit-any
async function fetchShopBySlug(sb: any, slug: string) {
  const { data, error } = await sb.rpc("sbp_resolve_shop_slug", { p_slug: slug });
  if (error) {
    console.error("[shop-page] resolve_shop_slug error:", error);
    return { ok: false, error };
  }
  if (!data || data.ok === false) {
    return { ok: false, error: data?.error || "not_found" };
  }
  // Redirect case (slug was renamed within 12 months)
  if (data.redirect === true && data.new_slug) {
    return { ok: true, redirect: data.new_slug };
  }
  return { ok: true, data };
}

// ── Render full SSR page (crawler version) ──────────────────────────
function renderCrawlerHtml(shop: any, slug: string, url: string): string {
  const content = shop.content || {};
  const shopName = content.name || shop.shop_name || "Shop";
  const tagline  = content.tagline || "";
  const phone    = content.phone   || "";
  const wa       = content.whatsapp || phone || "";
  const email    = content.email   || "";
  const addr     = content.address || "";
  const city     = content.city    || "";
  const hours    = content.hours   || "";
  const photoUrl = content.photo_url || "";
  const services = Array.isArray(content.services) ? content.services : [];

  const desc = tagline
    || (city ? `${shopName} in ${city}. Contact, address, hours.` : `${shopName}. Contact, address, hours.`);

  const canonicalUrl = url;
  const title = `${shopName} · ShopBill Pro`;

  const jsonLd = buildJsonLd({
    shopName, shopType: shop.shop_type || null,
    description: desc, url: canonicalUrl,
    phone, whatsapp: wa, email,
    addr, city, hours, photoUrl,
  });

  const meta = buildMetaBlock({
    title, description: desc,
    url: canonicalUrl, canonical: canonicalUrl,
    photoUrl, shopType: shop.shop_type || null, jsonLd,
  });

  // ── AI-mode: inline the raw ai_html (already a full HTML doc) ──
  if (shop.ai_mode === true && shop.ai_html && typeof shop.ai_html === "string"
      && shop.ai_html.length > 50) {
    // Inject our meta block into the existing <head>. Falls back to
    // prepend if no <head> tag.
    const ai = shop.ai_html;
    if (/<head[^>]*>/i.test(ai)) {
      return ai.replace(/<head([^>]*)>/i, `<head$1>\n${meta}\n`);
    }
    if (/<html[^>]*>/i.test(ai)) {
      return ai.replace(/<html([^>]*)>/i, `<html$1><head>${meta}</head>`);
    }
    return `<!DOCTYPE html><html lang="en"><head>${meta}</head><body>${ai}</body></html>`;
  }

  // ── Legacy mode: render minimal but content-rich HTML ──
  const fullAddr = [addr, city].filter(Boolean).join(", ");
  let body = `<header><h1>${escHtml(shopName)}</h1>`;
  if (tagline) body += `<p class="tagline">${escHtml(tagline)}</p>`;
  body += `</header><main>`;

  if (photoUrl) {
    body += `<p><img src="${escAttr(photoUrl)}" alt="${escAttr(shopName)}" style="max-width:200px;border-radius:16px"></p>`;
  }

  body += `<section><h2>Contact</h2><ul>`;
  if (phone)    body += `<li>Phone: <a href="tel:${escAttr(phone)}">${escHtml(phone)}</a></li>`;
  if (wa && wa !== phone) {
    body += `<li>WhatsApp: <a href="https://wa.me/${escAttr(wa.replace(/[^0-9]/g,""))}">${escHtml(wa)}</a></li>`;
  }
  if (email)    body += `<li>Email: <a href="mailto:${escAttr(email)}">${escHtml(email)}</a></li>`;
  if (fullAddr) body += `<li>Address: ${escHtml(fullAddr)}</li>`;
  if (hours)    body += `<li>Hours: ${escHtml(hours)}</li>`;
  body += `</ul></section>`;

  if (services.length > 0) {
    body += `<section><h2>Services</h2><ul>`;
    for (const s of services) {
      const sName  = s.name || s.service_name || "";
      const sDesc  = s.description || "";
      const sPrice = s.price != null ? ` — ₹${escHtml(s.price)}` : "";
      if (sName) {
        body += `<li><strong>${escHtml(sName)}</strong>${sPrice}`;
        if (sDesc) body += ` — ${escHtml(sDesc)}`;
        body += `</li>`;
      }
    }
    body += `</ul></section>`;
  }

  body += `<footer><p>Powered by <a href="https://shopbillpro.in/">ShopBill Pro</a></p></footer></main>`;

  return `<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="index, follow">
${meta}
<style>body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;max-width:720px;margin:0 auto;padding:24px;color:#0F0E18;line-height:1.55}h1{font-size:32px;margin:0 0 4px}h2{font-size:20px;margin:24px 0 8px;color:#5E5A7A}.tagline{color:#5E5A7A;font-size:16px;margin:0 0 16px}ul{padding-left:20px}li{margin-bottom:6px}footer{margin-top:32px;padding-top:16px;border-top:1px solid #E5E5EE;color:#5E5A7A;font-size:13px}a{color:#FF6B35}</style>
</head><body>${body}</body></html>`;
}

// ── Render human shell — exactly the same s.html, but with real meta
//    injected so when humans share, crawlers re-fetching see good OG ──
//
// We DON'T duplicate the 1300-line s.html template here. Instead we
// fetch it from the Vercel deploy and inject meta tags. This keeps
// the JS client behaviour identical (interactive modals, gallery,
// services rendering, etc.) and avoids drift between two HTML files.
// Module-level cache for the s.html shell. Populated on first warm request;
// stays in memory for the lifetime of the Deno container (~minutes to hours).
// Refresh after CACHE_TTL_MS so an updated s.html eventually propagates.
let _shellCache: { html: string; fetchedAt: number } | null = null;
const SHELL_CACHE_TTL_MS = 5 * 60 * 1000;  // 5 min

async function getShell(reqOrigin: string): Promise<string | null> {
  const now = Date.now();
  if (_shellCache && (now - _shellCache.fetchedAt) < SHELL_CACHE_TTL_MS) {
    return _shellCache.html;
  }
  const shellUrl = reqOrigin + "/s.html";
  try {
    const r = await fetch(shellUrl, {
      headers: { "User-Agent": "shop-page-edge-fn/1.0" },
    });
    if (!r.ok) throw new Error("status " + r.status);
    const html = await r.text();
    _shellCache = { html, fetchedAt: now };
    return html;
  } catch (e) {
    console.error("[shop-page] shell fetch failed from", shellUrl, e);
    // If we have a stale cache, serve it
    if (_shellCache) {
      console.warn("[shop-page] serving stale shell from cache");
      return _shellCache.html;
    }
    return null;
  }
}

async function renderHumanShell(
  shop: any,
  slug: string,
  url: string,
  reqOrigin: string,
): Promise<string> {
  const content = shop.content || {};
  const shopName = content.name || shop.shop_name || "Shop";
  const tagline  = content.tagline || "";
  const photoUrl = content.photo_url || "";
  const city     = content.city || "";
  const desc = tagline
    || (city ? `${shopName} in ${city}. Contact, address, hours.` : `${shopName}. Contact, address, hours.`);

  const jsonLd = buildJsonLd({
    shopName, shopType: shop.shop_type || null,
    description: desc, url, phone: content.phone || "",
    whatsapp: content.whatsapp || content.phone || "",
    email: content.email || "",
    addr: content.address || "", city: content.city || "",
    hours: content.hours || "", photoUrl,
  });
  const meta = buildMetaBlock({
    title: `${shopName} · ShopBill Pro`,
    description: desc, url, canonical: url,
    photoUrl, shopType: shop.shop_type || null, jsonLd,
  });

  const shell = await getShell(reqOrigin);
  if (!shell) {
    // No shell available — fall back to crawler HTML (functional but less interactive)
    return renderCrawlerHtml(shop, slug, url);
  }

  // Replace the placeholder meta block in s.html (lines 20-25 in current
  // version) with our real meta. The comment in s.html says:
  //   <!-- These get rewritten by JS once the slug resolves -->
  // We rewrite them server-side instead.
  //
  // Pattern: find the block from <title>...</title> through the OG type meta,
  // replace with our full meta block. Robust to whitespace changes.
  const replaced = shell.replace(
    /<title>[\s\S]*?<\/title>[\s\S]*?<meta property="og:type"[^>]*>/i,
    meta
  );

  if (replaced === shell) {
    // Replacement didn't fire (s.html changed structure). Inject after <head>.
    console.warn("[shop-page] meta replacement pattern missed, injecting after <head>");
    return shell.replace(/<head([^>]*)>/i, `<head$1>\n${meta}\n`);
  }

  return replaced;
}

// ── Main handler ────────────────────────────────────────────────────
Deno.serve(async (req) => {
  // CORS preflight (not strictly needed for HTML responses but safe)
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin":  "*",
        "Access-Control-Allow-Headers": "content-type",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
      },
    });
  }
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("method_not_allowed", { status: 405 });
  }

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
    return errorHtml("Configuration error",
      "Server not configured. Please contact support.", 500);
  }

  const reqUrl = new URL(req.url);

  // Slug resolution priority:
  //   1. ?slug=xxx (set by Vercel rewrite)
  //   2. Last path segment (covers direct calls to the edge function URL)
  let slug = reqUrl.searchParams.get("slug") || "";
  if (!slug) {
    // /functions/v1/shop-page/foo → take "foo"
    const parts = reqUrl.pathname.split("/").filter(Boolean);
    slug = parts[parts.length - 1] || "";
    if (slug === "shop-page") slug = "";  // direct call with no slug
  }
  slug = slug.trim().toLowerCase();

  if (!slug || slug.length < 1) {
    return errorHtml("Shop not specified",
      "No shop slug provided in the URL.", 400);
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  // Construct the canonical URL (what we tell crawlers is the page's
  // permanent address). We use APP_ORIGIN; custom-domain canonicals
  // are handled by domain-router.html for custom-domain traffic.
  const canonicalUrl = `${APP_ORIGIN}/s/${slug}`;

  const result = await fetchShopBySlug(sb, slug);
  if (!result.ok) {
    return errorHtml("Shop not found",
      `We couldn't find a shop at /s/${slug}. The owner may have unpublished it, or the link may be incorrect.`, 404);
  }

  if (result.redirect) {
    return new Response(null, {
      status: 301,
      headers: {
        "Location":      `/s/${result.redirect}`,
        "Cache-Control": "public, max-age=3600",
      },
    });
  }

  const shop = result.data;
  const ua = req.headers.get("user-agent");
  const crawler = isCrawler(ua);

  // Render
  const reqOrigin = req.headers.get("x-forwarded-host")
    ? `https://${req.headers.get("x-forwarded-host")}`
    : APP_ORIGIN;

  let html: string;
  if (crawler) {
    html = renderCrawlerHtml(shop, slug, canonicalUrl);
  } else {
    html = await renderHumanShell(shop, slug, canonicalUrl, reqOrigin);
  }

  return new Response(html, {
    status: 200,
    headers: {
      "Content-Type":  "text/html; charset=utf-8",
      "Cache-Control": "public, s-maxage=300, stale-while-revalidate=600",
      // Vary on UA so crawler and human responses are cached separately.
      "Vary":          "User-Agent",
      // Don't let crawlers index this Edge Function URL directly —
      // they should index the /s/{slug} URL on app.shopbillpro.in.
      // (Canonical link in HTML handles this; X-Robots-Tag would
      //  apply even when canonical present, so we don't set it.)
    },
  });
});
