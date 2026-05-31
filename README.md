# FIX: Shop pages (/s/{slug}) — rendering + resource blocking

## SYMPTOMS (in order they appeared)
1. Page showed RAW CODE instead of rendering.            → Content-Type fix (done)
2. Page renders but stuck "Loading shop profile…",       → CSP fix (this update)
   fonts/CSS/scripts show (blocked:csp), button unstyled.

## ROOT CAUSE (both symptoms = same source)
Supabase's gateway adds two bad headers to the function's GET response:
  - `content-type: text/plain`  → browser shows source instead of rendering
  - `content-security-policy: default-src 'none'; sandbox`
        → blocks ALL fonts, styles, scripts, images the shell needs to load,
          so it never finishes ("Loading…") and stays unstyled.
Neither header is in your function code — they are Supabase platform defaults.
Vercel proxied both straight through. The `/s/` route had no header override
(the `/sitemap-shops.xml` route already overrides Content-Type for the same reason;
sitemap was unaffected by CSP because XML loads no sub-resources).

## THE FIX (1 file) — vercel.json
Added a `headers` override for `/s/:slug` and `/s/:slug/:rest*`:
  - Content-Type: text/html; charset=utf-8   (makes it render)
  - X-Content-Type-Options: nosniff
  - Content-Security-Policy: permissive policy allowing self + https CDNs
    (Supabase, Google Fonts, jsdelivr) for script/style/font/img/connect.
    This REPLACES Supabase's blocking `default-src 'none'; sandbox`.

## DEPLOY PATHS
| File | Destination | Action |
|---|---|---|
| `vercel.json` | repo ROOT (app.shopbillpro.in project) | **REPLACE** |

> ROOT vercel.json, NOT site/vercel.json. No function redeploy needed.

## TEST AFTER DEPLOY (~1–2 min)
PowerShell:
  $r = Invoke-WebRequest "https://app.shopbillpro.in/s/glitz-glam"
  $r.Headers["Content-Type"]              # text/html; charset=utf-8
  $r.Headers["Content-Security-Policy"]   # should be the permissive policy, NOT 'sandbox'
Then hard-reload https://app.shopbillpro.in/s/glitz-glam (Ctrl+Shift+R):
  - Page fully renders, styled, no "Loading…" stuck state.
  - Network tab: no more (blocked:csp) rows; fonts + css?family=Outfit load 200.

## IF CSP STILL SHOWS 'sandbox' AFTER DEPLOY
That would mean Vercel isn't overriding the upstream CSP (only Content-Type).
Fallback then is to make the function self-host fonts/inline styles, OR proxy
sub-resources through the same origin. Report back the CSP header value and we
pivot. (Content-Type override is already proven to work live via the sitemap route.)
