# Batch 1B-C (Lib Patch Only) — Sidebar Engine Update

**Status:** Lib code only. Patches `lib/sidebar-engine.js` to support desktop layout. **Does NOT wire it into any page.** Live site behavior is unchanged after this deploy.

**Risk:** Very low. The patched lib is uploaded but not called by any page. If everything goes wrong with this deploy, no user-facing change happens.

**Time:** ~5 minutes deploy + 2 minutes verify.

---

## What This Batch Does

Patches `lib/sidebar-engine.js` so it can render **two distinct layouts** correctly:

| Layout | Used by | CSS classes output | Container |
|---|---|---|---|
| `mobile-bottom` | (existing) Mobile bnav | `.ni`, `.ni-ic`, `.ni-lb`, `.nav-fab` (already correct) | Caller-provided `#bnav` |
| `desktop` ⭐ NEW | (next sub-batch) 16 user-facing pages | `.dsb-item`, `.dsb-ic`, `.dsb-logo`, `.dsb-brand`, `.dsb-nav`, `.dsb-footer`, `.dsb-ver` | Auto-mounts `<div id="dsb">` on body |

The desktop branch:
- Renders an SVG shield logo + "ShopBill Pro" brand
- Renders nav items with bilingual `<span class="lang-en">/<span class="lang-hi">` pairs
- Renders a logout button at footer that signs out via Supabase
- Auto-mounts `<div id="dsb">` to body if no container provided
- Only mounts on screens ≥ 1024px (matches existing `@media(max-width:1023px){#dsb{display:none!important}}` rule)
- Normalizes `currentPage` so callers can pass `'dashboard'` or `'dashboard.html'` interchangeably
- "Settings" label on desktop (proper page name); "More" label on mobile bnav (5-slot overflow convention)

---

## Why This Is A Lib-Only Deploy

In the original 1B-C plan, my recommendation was: **patch the lib first, deploy it (zero impact), THEN wire pages to it**. This separation protects against the highest-risk class of bugs in 1B-C — CSS class mismatches that would break the sidebar on every page simultaneously.

Until any page calls `SBPSidebar.render({ layout: 'desktop', ... })`, the patched lib just sits at `app.shopbillpro.in/lib/sidebar-engine.js` doing nothing. Existing pages still use their own inline `var nav=[...]` arrays and `<div id="dsb">` injection. **No visible change anywhere.**

The next sub-batch ("1B-C pilot") will wire `dashboard.html` to call the lib and verify it renders correctly. After that, scaling to 15 more pages becomes safe.

---

## Files In This Batch

| File | Action |
|---|---|
| `lib/sidebar-engine.js` | REPLACE — adds desktop layout (~93 lines net additions) |
| `service-worker.js` | REPLACE — bumped to v1.5.4 |

That's it. **Two files.**

---

## Deploy Steps

### Step 1 — Replace the 2 files

In your local repo:
1. Copy `lib/sidebar-engine.js` from the ZIP → overwrite `lib/sidebar-engine.js` at repo
2. Copy `service-worker.js` from the ZIP → overwrite at repo root

### Step 2 — Commit and push

```bash
git add lib/sidebar-engine.js service-worker.js
git commit -m "Batch 1B-C: lib patch — desktop sidebar rendering with .dsb-* classes (not yet wired)"
git push
```

Wait ~60 sec for Vercel deploy.

### Step 3 — Verify the lib is updated on server

```
https://app.shopbillpro.in/lib/sidebar-engine.js
```

Open in a browser tab. Search (Ctrl+F) for `BATCH 1B-C` — you should see ~10 occurrences. If yes → lib deployed. If not → file didn't update (check git push went through).

### Step 4 — Verify live site is unchanged

Open the dashboard in incognito. Click around to other pages.

**Expected:**
- ✅ Sidebar looks identical to before (still rendered by each page's inline JS)
- ✅ Mobile bnav unchanged
- ✅ Beta banner from 1B-A still shows (if you have a beta test shop)
- ✅ Plans page panel from 1B-E still works
- ✅ Nothing broken anywhere

This is a "no visible change" deploy. Confirming nothing broke is the verification.

---

## What's Next (NOT in this batch)

The pilot wiring sub-batch (call it **1B-C-Pilot**) will:

1. Modify `dashboard.html` ONLY — replace the inline `var nav=[...]` block + `<div id="dsb">` injection with a single `SBPSidebar.render({ layout: 'desktop', currentPage: 'dashboard' })` call
2. Deploy to production
3. Verify dashboard.html renders correctly with the new lib
4. Test edge cases: active beta user, free user, different shop_types
5. Soak for 24 hours (real-world clicks, no console errors)

After that succeeds, **1B-C-Scale** wires the remaining 15 pages in batches of 4.

If pilot fails for any reason, we fix the lib (or revert) before touching any other page. **The lib being uploaded but unused is the safe staging ground.**

---

## Rollback (If Needed)

```bash
git revert HEAD
git push
```

Reverts both files. Lib goes back to mobile-bnav-only output. No user-visible change since no page was using it yet.

---

## Smart Sidebar Behavior (As Picked)

You chose Smart sidebar over Uniform. After pilot wiring, here's what users will see:

- **Universal core** (always shown): Home, Bills, +New Bill (FAB), Customers, Stock, Reports, Settings
- **Vertical modules** (vary by shop_type): from `MODULE_CATALOG` based on `get_shop_modules(shop_id)` RPC
- **Coming Soon badges**: Modules not yet built show with `coming-soon` class + toast on click

For your "Viraj Enterprises" beta shop (`shop_type='d2c_brand'`), the lib will fetch `get_shop_modules` and show D2C-specific items (online_orders, courier, loyalty if defined for d2c_brand profile). For a salon shop, it would show stylists, customer_history, appointments. This is the platform thesis — different shops see different sidebars.

For pilot verification: after wiring dashboard.html, your test shop will probably see fewer items than the current 15-item uniform sidebar. **That's expected**, not a bug. If you want to add more items to a shop's sidebar, the right place is in the `sbp_module_profiles` table (configured via `/admin-categories.html`).

---

## Reply Path

This deploy should pass smoothly because it's lib-only with no page integration yet. If verification confirms nothing broke, we proceed to pilot wiring in the next session.

- **"Lib deployed, site unchanged — ready for pilot"** → I'll prep 1B-C-Pilot (dashboard.html wiring) when you're ready
- **"Got error: ___"** → paste, debug
