# FIX: Shop pages (/s/{slug}) showing raw code instead of rendering

## ROOT CAUSE
The Supabase edge function `shop-page` returns the correct HTML body, but on
**GET** requests Supabase's gateway labels the response `content-type: text/plain`
with `x-content-type-options: nosniff`. `nosniff` forces browsers to obey that
label, so they display the HTML as source text (and ignore `<meta charset>`,
causing the `Curry Â·` / `dark→light` mojibake).

Vercel proxied that wrong header straight through. The `/sitemap-shops.xml` route
already had a `headers` override for this exact issue — `/s/{slug}` never did.
(HEAD requests returned text/html, which is why earlier header checks looked fine.)

## THE FIX (1 file)
`vercel.json` — added a `headers` override for `/s/:slug` and `/s/:slug/:rest*`
forcing `Content-Type: text/html; charset=utf-8`. Mirrors the proven sitemap fix.
Verified live that a Vercel headers rule DOES override the proxied upstream
content-type (the sitemap route already does this successfully).

## DEPLOY PATHS
| File | Destination | Action |
|---|---|---|
| `vercel.json` | `vercel.json` (repo ROOT — the app project) | **REPLACE** |

> This is the ROOT vercel.json (app.shopbillpro.in project), NOT site/vercel.json.

## TEST AFTER DEPLOY (~1–2 min)
PowerShell:
  (Invoke-WebRequest "https://app.shopbillpro.in/s/glitz-glam").Headers["Content-Type"]
  → should be: text/html; charset=utf-8
Then open https://app.shopbillpro.in/s/glitz-glam in any browser/phone → renders
as the real website, not code. No service worker / cache clearing needed.

## NOTE
No function redeploy needed — fix is purely at the Vercel proxy layer.
Any other route that proxies a Supabase function and must render/serve a specific
type will need the same headers override (pattern now established for 2 routes).
