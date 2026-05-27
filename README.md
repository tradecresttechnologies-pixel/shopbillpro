# ShopBill Pro — v8.1 PWA Install Fix + POS "Bill Now" Visibility Fix

**Bundle:** `ShopBillPro_v8.1_pwa_install_fix.zip`
**Date:** 2026-05-27
**Goal:** Restore PWA installability on Android/Chrome/Edge, fix manifest icon
paths, unblock the broken /login.html and /signup.html marketing-site CTAs,
AND fix the POS Mode "Bill Now" button being hidden behind the bottom nav on
tablets.

---

## What was broken

Three independent issues stacked together produced the "PWA install
doesn't work" symptom:

1. **`/login.html` and `/signup.html` returned 404** — the marketing site
   has 13+ buttons linking to these URLs but only `/login` and `/signup`
   (no `.html`) had redirects in `vercel.json`. Users clicking "Get
   started — Free" from the marketing site bounced before ever reaching
   the app where install would be offered.

2. **The Service Worker was a kill-switch that unregistered itself.**
   This was the right call back on 12-May-26 to escape the v1.4.0
   stale-cache disaster, but it eliminated PWA install capability as a
   side effect. Chrome/Edge require an active service worker with a
   fetch handler for the "Install app" omnibox icon and
   `beforeinstallprompt` event to fire. The v1.5.0 SW had neither.

3. **All 11 icon paths in `manifest.json` were wrong** — referenced
   `favicon32x32.png`, `icon48x48.png`, etc. (no hyphen, no folder)
   while the actual files are at `icons/favicon-32x32.png`,
   `icons/icon-48x48.png`. Chrome's PWA install criteria require at
   least one valid icon ≥144x144 to fetch successfully. Currently zero
   icons resolved → install criteria failed.

Plus two smaller fixes folded in:

4. **`manifest.json` Content-Type** — Vercel was serving as
   `application/json`. Now explicitly `application/manifest+json` per
   spec (matters for stricter browsers and Lighthouse audits).

5. **`Service-Worker-Allowed: /` header** — explicitly allows the SW to
   claim scope `/` from any registration path (defensive; we currently
   register from root so this is technically redundant, but harmless
   and protects against future scope changes).

Plus a critical responsive-layout overhaul that came in during the audit (separate from the PWA issue, but the same bundle):

6. **POS Mode layout was broken on tablets — full responsive redesign.**
   The previous CSS had a 540px break (phone hides cart panel, shows FAB)
   and a 640px break (#app letterbox clamps to 480/600px) that together
   produced a broken zone at 541-1023px: cart panel rendered inline,
   bottom-nav was `position:fixed`, and there was no padding to keep
   the "Bill Now" button visible above the nav. Users on iPad-portrait,
   small Android tablets, and large foldables saw a cart with items but
   no way to checkout.

   **Fix scope:** Redesign POS Mode breakpoints to a coherent system
   that works at *every* viewport size, not just patch the broken zone.

   New responsive behavior:
   - **<1024px (all phones + all tablets, any orientation):** Cart panel
     hidden inline. FAB + bottom-sheet modal used. Same proven pattern
     that worked on phones, now extended to tablets.
   - **≥1024px (desktop + sidebar layout):** Inline side cart panel
     returns. Sidebar takes 220px, leaving ~800px+ for products
     side-by-side with the cart panel.

   Plus tablet-specific polish: at 640-1023px in POS Mode, `#app` is
   un-clamped (was forced to 480/600px); product grid uses 140px cells
   (was 100px) so tablets actually use their extra screen width
   instead of stretching tiny phone-sized cards. Manual Bill view and
   other pages are unaffected — the un-clamp is gated by a new
   `body.is-pos-mode` class that `switchMode()` toggles.

   Bonus: removed a stray triple-closing-brace `}}}` at the original
   line 428 that was a real CSS parse warning in strict browsers.

---

## DEPLOY PATHS

| Action  | Path                  | Notes                                          |
|---------|-----------------------|------------------------------------------------|
| REPLACE | `manifest.json`       | Repo root. Fixes all 11 icon paths.            |
| REPLACE | `service-worker.js`   | Repo root. v1.5.0 kill-switch → v1.6.0 pass-through. |
| REPLACE | `index.html`          | Repo root. Adds SW registration.               |
| REPLACE | `dashboard.html`      | Repo root. Replaces SW cleanup block with SW registration. |
| REPLACE | `billing.html`        | Repo root. CSS fix for POS "Bill Now" button visible on tablets. |
| REPLACE | `vercel.json`         | Repo root. Adds 2 redirects + manifest Content-Type header. |

All 6 files are at the repo root. No subdirectories touched. No SQL
migrations. No Edge Function changes. No Supabase work.

---

## Deploy steps

1. **GitHub Desktop:**
   - Drag the 5 unzipped files into the repo root (overwrite existing)
   - Commit: "v8.1 — Fix PWA install: SW + manifest icons + login.html redirects"
   - Push to main

2. **Wait ~2 min** for Vercel auto-deploy.

3. **Verify deployment** (steps in next section).

4. **Tell existing users to refresh once.** The old v1.5.0 SW will
   detect the new v1.6.0 SW on next page load, `skipWaiting +
   clients.claim` activates it immediately. After that single page
   load, all install machinery works normally. New users have nothing
   to do — they get v1.6.0 directly.

---

## Verification

### Test 1 — Manifest icons load

In a regular browser, open https://app.shopbillpro.in/manifest.json and
confirm:
- JSON loads (status 200)
- `icons[]` paths start with `/icons/icon-...` (with hyphens)

Then in browser DevTools → Application → Manifest, confirm:
- No "Failed to load icon" errors
- All icon sizes show preview thumbnails

### Test 2 — Service worker registers

DevTools → Application → Service Workers
- Status: "activated and is running"
- Source: `service-worker.js`
- Scope: `https://app.shopbillpro.in/`

Console should log:
```
[App] SW registered: https://app.shopbillpro.in/
[SW v1.6.0-minimal-pwa-enable] install — skipping waiting
[SW v1.6.0-minimal-pwa-enable] activate — claiming clients
```

### Test 3 — Install prompt appears

**Chrome desktop:** look at the right end of the URL bar. After ~30 sec
on the app, an "Install" icon (monitor with down arrow) should appear.
Clicking it opens the install dialog with the ShopBill icon, name, and
description.

**Android Chrome:** menu (⋮) → "Add to Home screen" or "Install app".

**Edge desktop:** Settings (⋯) → "Apps" → "Install this site as an app".

### Test 4 — Marketing-site CTAs no longer 404

```powershell
Invoke-WebRequest -Uri "https://app.shopbillpro.in/login.html" -MaximumRedirection 0 -ErrorAction SilentlyContinue | Select-Object StatusCode, @{N='Location';E={$_.Headers.Location}}
```

Expect: `StatusCode: 308` (or 307), `Location: /`

Repeat for `/signup.html`. Both should redirect to `/` (which is
`index.html`, the login/signup page).

### Test 5 — POS Mode works on every screen size

Open `app.shopbillpro.in/billing.html` in Chrome DevTools → toggle
device toolbar → cycle through:
- iPhone SE (375x667) — POS Mode → tap product → "🛒 Cart" FAB
  appears bottom-right → tap → cart sheet opens → "🧾 Bill Now"
  button visible at bottom → tap → checkout modal opens.
- iPad mini portrait (768x1024) — POS Mode → product grid uses
  bigger 140px tiles (better use of width) → "🛒 Cart" FAB
  bottom-right → same modal flow.
- iPad Pro landscape (1366x1024) — POS Mode → inline cart panel
  appears on right side → products + cart side-by-side → "🧾 Bill
  Now" visible at bottom of cart panel.
- Desktop 1920x1080 — same as iPad landscape, sidebar on the left
  is visible too.

All four should let users add items and generate a bill without
hidden buttons.

Before this fix: on iPad portrait (~768px), cart panel showed inline
but the "Bill Now" button was hidden under the fixed bottom nav.
Users could see items + total but had no way to checkout.

### Test 6 — Lighthouse PWA audit

Chrome DevTools → Lighthouse → check "Progressive Web App" → analyze.

Expect:
- ✓ Web app manifest meets the installability requirements
- ✓ Service worker registered
- ✓ Configured for a custom splash screen
- ✓ Sets theme color
- ✓ Content sized correctly for viewport

Some items will still flag (no `apple-touch-icon` link in some pages,
no offline page) — these are Phase B polish items, not blockers.

---

## What v1.6.0 SW does and doesn't do

**Does:**
- Install + activate immediately (`skipWaiting`, `clients.claim`)
- Wipe any lingering caches from v1.4.0/v1.5.0 on first activation
- Provide an empty `fetch` listener (satisfies Chrome's installability check)
- Accept `SKIP_WAITING` messages from the page for future update flows

**Does NOT:**
- Cache anything. Zero. The `fetch` handler never calls
  `event.respondWith()`, so the browser proceeds with its normal
  network fetch every time. This is by design — the v1.4.0 staleness
  bugs were caused by `cache.match()` returning old responses. v1.6.0
  cannot do this because it has no cache code.
- Offer offline support. Offline still relies on the app-layer
  localStorage cache of shops/customers/bills/products, which is
  already wired and unaffected by this change.
- Auto-update on every deploy. The SW file has
  `Cache-Control: no-store`, so browsers always re-fetch it on update
  checks (typically once every 24h, plus on every page load by spec).

If you ever want real offline caching, build a v1.7+ as a deliberate
feature with explicit cache versioning, kill-switch fallback, and
staged rollout. Don't add it to v1.6.

---

## Rollback

If the new SW causes any issue (extremely unlikely given it's a
no-op), three options in order of severity:

1. **Soft rollback** — Replace `service-worker.js` with a copy of the
   v1.5.0 kill-switch from the previous deploy. Users on next page
   load will unregister back to no-SW state.

2. **Revert vercel.json and index.html/dashboard.html SW registration
   blocks** to their pre-v8.1 state. Push. Existing v1.6.0 SW
   installations will stay until manually unregistered (browser
   DevTools → Application → Service Workers → Unregister), but new
   visits won't register the SW.

3. **Full revert** — `git revert` the v8.1 commit. Pushes everything
   back to v8.0 state.

The icon-path fix in manifest.json is strictly an improvement (current
paths are broken) — no reason to roll that back even if SW issue.

---

## What's NOT in this batch (deferred to v8.1+)

- **Marketing site "Download App" CTA** — the polish item from Batch B.
  Marketing site currently has no install button at all. Users have to
  visit `app.shopbillpro.in` to see the install banner. Adding a
  cross-origin install relay is a v8.2 candidate.
- **PWA screenshots** for richer install dialog — needs design work to
  create proper 1080x1920 (mobile) and 1920x1080 (desktop) screenshot
  images, then reference them in manifest.json.
- **Offline fallback page** — Lighthouse will flag this. Real offline
  needs the v1.7+ deliberate SW story above.
- **Web Share Target** — letting other apps share photos/text TO
  ShopBill would be cool but isn't a current pain point.
