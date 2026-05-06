# ShopBill Pro — Batch 013 Hotfix (Customer load + Sidebar scroll + Loyalty page)

**Date:** 6 May 2026 (post Batch 013 deploy)
**Type:** Hotfix bundle — fixes 3 issues from your test screenshot
**Risk:** Low — additive (1 new RPC, 1 new page) + 2 surgical edits
**Time to deploy:** ~3 min (SQL) + ~30 sec (Vercel auto-deploy)

---

## What this fixes

You reported 3 issues after Batch 013 deploy:

1. **"Could not load customers" toast** on customer-history.html (picker mode showed empty list)
2. **Loyalty in sidebar** redirected to settings.html which had no anchor — confusing dead-end
3. **Sidebar scroll resets to top** every time you click a menu item — breaks flow on shops with many modules

This hotfix delivers a fix for each, plus a proper Loyalty admin page (overview + config + recent activity) that didn't exist before.

---

## Files in this hotfix (5 files)

| File | Action | Purpose |
|------|--------|---------|
| `customer-history.html` | MODIFIED | Use `joined_at` (which exists) instead of `updated_at` (which doesn't); add localStorage fallback |
| `lib/sidebar-engine.js` | MODIFIED | Preserve scroll position via sessionStorage; loyalty href → `loyalty.html` |
| `loyalty.html` | NEW | Admin overview page (stats + config + recent activity) |
| `db/migrations/014_loyalty_overview.sql` | NEW | RPC `sbp_loyalty_admin_overview` for shop-wide stats |
| `HOTFIX_README.md` | NEW | This file |

---

## Fix 1 — Customers loading bug

**Root cause:** I queried `customers` with `.order('updated_at', { nullsLast: true })` but the customers table doesn't have an `updated_at` column. Existing code in customers.html sorts by `name` or just selects without ordering.

**Fix:** Use `joined_at` (which does exist — added in 009_loyalty.sql) for ordering. If the Supabase query fails for any reason (network, RLS, missing column), fall back to the `sbp_customers` localStorage cache that customers.html populates on every page load. This way the picker shows something even offline.

```js
// Before (broken):
.order('updated_at', { ascending: false, nullsLast: true })

// After (works + has cache fallback):
.order('joined_at', { ascending: false })
// catch → localStorage.getItem('sbp_customers')
```

## Fix 2 — Loyalty destination

**Root cause:** In Batch 012 I set `loyalty.href = 'settings.html#loyalty'`, but settings.html had no `#loyalty` anchor or section. Clicking Loyalty dumped users on a generic settings page with no obvious next step.

**Fix:** Built a proper `loyalty.html` admin overview page following the same pattern as services.html / appointments.html / customer-history.html. It shows:

- **Hero banner** — "Loyalty is active" or "Loyalty is currently OFF" with a quick-enable button
- **Stats grid** (4 cards): Active Members, Outstanding Points, Lifetime Earned (with redeemed tally), Expiring in 30 days OR Last 30 days txn count
- **Program Settings card** — current config (earn rate, redeem rate, expiry, etc.) with "Edit" link → opens config modal with full form
- **Recent Activity** — last 30 transactions across all customers, each clickable to drill into that customer's full timeline
- **"Manage per customer →"** link to customers.html for per-customer balance management

Backend: `sbp_loyalty_admin_overview(p_shop_id)` RPC aggregates everything in one call (config + stats + recent_txns_with_names). API-first, jsonb envelope, owner check, read-only.

Plan-locked: shows the standard upgrade banner if the shop is on the Free tier (loyalty is Pro+).

## Fix 3 — Sidebar scroll position

**Root cause:** Every page navigation re-renders the sidebar via `innerHTML = ...`, which wipes scrollTop on `.dsb-nav` back to 0. For shops with many sidebar items (16+ vertical modules), users had to re-scroll to find their place every time.

**Fix:** Added `_wireScrollPersist(layout, containers)` to the sidebar engine. It attaches a debounced scroll listener to `.dsb-nav`, saves scrollTop to `sessionStorage` (key: `sbp_dsb_scroll`), and restores it synchronously on each render. sessionStorage (not localStorage) — should reset between browser sessions, not persist forever.

Only applies to the desktop sidebar (mobile bnav is fixed-height, doesn't scroll; mobile drawer always reopens fresh by design).

---

## Deploy steps

### Step 1 — SQL in Supabase SQL Editor

```sql
\i db/migrations/014_loyalty_overview.sql
```

Or paste manually. Idempotent, completes in <2 sec.

### Step 2 — Verify

```sql
-- (1) RPC exists
SELECT pg_get_function_arguments(oid)
FROM pg_proc WHERE proname = 'sbp_loyalty_admin_overview';
-- Expected: "p_shop_id uuid"

-- (2) Smoke test — replace with your real shop ID:
SELECT sbp_loyalty_admin_overview('<your-shop-uuid>');
-- Expected: {ok:true, config:{...}, stats:{...}, recent_txns:[...]}
```

### Step 3 — Push 4 files to GitHub PWA repo

```
db/migrations/014_loyalty_overview.sql      (new)
lib/sidebar-engine.js                        (modified)
loyalty.html                                 (new)
customer-history.html                        (modified)
```

Vercel auto-deploys ~30 sec.

---

## Smoke test checklist

### Fix 1 — Customer history picker
- [ ] Hard-refresh (Ctrl-Shift-R), click sidebar History
- [ ] No "Could not load customers" toast
- [ ] Recent customers list shows your real customers
- [ ] Search box filters them by name/phone

### Fix 2 — Loyalty page
- [ ] Click "Loyalty" in sidebar — navigates to `loyalty.html` (NOT settings)
- [ ] Hero banner shows program status (active/disabled)
- [ ] Stats grid shows real numbers (active members, outstanding points)
- [ ] Program Settings card shows current config values
- [ ] Click "✏️ Edit" — modal opens with all fields pre-populated
- [ ] Toggle "Program Enabled" + change earn rate, hit Save → settings persist on reload
- [ ] Recent Activity list shows last txns with customer names
- [ ] Click any txn — navigates to customer-history.html for that customer

### Fix 3 — Sidebar scroll position
- [ ] Open sidebar (desktop, ≥1024px wide), scroll down to bottom (Loyalty / Logout area)
- [ ] Click any menu item to navigate to a different page
- [ ] After page loads, sidebar should still be scrolled to where you left it (NOT jumped back to top)
- [ ] Repeat across several pages — position holds throughout the session
- [ ] Close browser tab and reopen — sidebar resets to top (sessionStorage cleared by design)

### Mobile sanity
- [ ] On a phone (<1024px), sidebar hidden as expected; bottom nav appears
- [ ] No regressions to customer-history.html, services.html, appointments.html

---

## Rollback plan

| Layer | Rollback |
|-------|----------|
| RPC | `DROP FUNCTION sbp_loyalty_admin_overview(uuid);` |
| loyalty.html | Delete the file from repo |
| sidebar-engine.js | `git revert <commit>` and push (reverts loyalty href + scroll persist) |
| customer-history.html | `git revert <commit>` and push (reverts query fix) |

No data is created, modified, or destroyed by this hotfix. RPC is read-only. Page is consumer-only. Rollback risk minimal.

---

## After this hotfix

You're back to a clean state. Tier 1 verticals all complete (Salon at 95% — Stylists deliberately deferred). The 3 user-reported issues from this morning's test are fixed.

Open queue (unchanged from earlier):
- BUG-011: Mobile accessibility for Marketing/Plans/Team pages
- BUG-012: Manual billing payment-mode field timing
- BUG-013: localStorage `sbp_pending_shop` resume for email-confirm signups
- BUG-016: Marketing pamphlet redesign
- Brand assets / images / soft-beta list (external)

External: CIN still ticking.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Batch 013 Hotfix (6 May 2026)*
