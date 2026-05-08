# BATCH 018.2 — Admin Sidebar FIX (replaces 018.1 + hotfix)

**Date:** 8 May 2026 · 4:40 AM IST
**Severity:** This SUPERSEDES Batch 018.1 and its hotfix. Use these 15 files instead.

## What was broken (and is now fixed)

Batch 018.1 replaced the admin sidebar but **dropped two HTML IDs that page JavaScript depended on**:

1. **`id="logoutBtn"`** — used by 8 admin pages via `document.getElementById('logoutBtn').addEventListener(...)`. When the ID was missing, `getElementById` returned null, `.addEventListener` threw `TypeError`, and **the entire post-sidebar JS chain halted on those pages** — including the calls that fetch and render data. That's why Dashboard, Analytics, Users, Subscriptions etc. showed empty content.

2. **`id="pendingBadge"`** — referenced by admin-dashboard.html for the Subscriptions notification dot. Missing was non-fatal (the JS had an `if(badge)` guard) but lost the feature.

3. **Browser console showed errors** like `Cannot read properties of null (reading 'addEventListener')` on every affected page.

## What this batch does

- Re-applies the unified sidebar to all 15 admin pages
- **Adds back `id="logoutBtn"`** on the logout `<div>` so legacy `getElementById` wiring works
- Adds a clean helper `<script>` block before `</body>` that defines `window.goTo()` and `window.logout()` — the latter integrates with `AdminAuth.getInstance().logout()` if available, then clears sessionStorage and redirects to login
- Strips any older broken injection from Batch 018.1
- No duplicate IDs across pages
- Preserves all original page content (KPI containers, charts, tables, forms)

## Files

```
batch018_2/
├── BATCH_018_2_DEPLOY.md           ← you are here
└── admin-*.html                    ← 15 admin pages, all corrected
```

## Deploy

Copy each `admin-*.html` to your repo root, **overwriting** the broken versions from Batches 018.1 and the hotfix. Push, Vercel auto-deploys.

```
git add admin-*.html
git commit -m "Batch 018.2: fix sidebar sync — restore id=logoutBtn IDs that JS depends on, fixes blank dashboards"
git push
```

## Then test

1. Hard-refresh admin-dashboard.html (Ctrl+Shift+R)
2. Open DevTools (F12) → Console tab
3. Run this 2-liner to set the right token:
   ```js
   sessionStorage.setItem('sbp_admin_token', 'SBP_ADMIN_2024_SECURE');
   location.reload();
   ```
4. After reload, check console — should show **0 red errors** (or just info messages, no errors)
5. Dashboard should populate with KPI cards (Total Shops 4, MRR 0, ARR 0, etc.)
6. Click sidebar items → all 15 pages navigate correctly
7. Logout button works (clears sessionStorage + redirects to login)

## Known item parked

The notification dot on Subscriptions nav-item (red badge showing pending verification count) was removed in this fix to avoid duplicate-ID with admin-subscriptions.html's filter button. We can rebuild it cleanly in a later batch with a unique ID like `navPendingBadge`. Non-blocking.

## After this works → security TODO

Once the admin panel is fully functional:
1. Visit admin-settings → "Change Admin Password" section → set a strong password
2. The local fallback hash in `admin-auth.js` (line 32) should be updated to match. I'll send a small patch separately.
3. Save the new password in your password manager.

The default `SBP_ADMIN_2024_SECURE` is published in code comments and unsafe to leave in production.

---

**Built by Claude · Batch 018.2 · 8 May 2026 · ShopBill Pro · TradeCrest Technologies Pvt. Ltd.**
