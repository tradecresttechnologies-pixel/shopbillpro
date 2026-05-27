# ShopBill Pro — v8.2 Cloud-For-Everyone Sync Fix

**Bundle:** `ShopBillPro_v8.2_cloud_for_everyone.zip`
**Date:** 2026-05-27
**Files changed:** 5 (`customers.html`, `bills.html`, `stock.html`, `pos-admin.html`, `billing.html`)
**Pricing rule change:** Free plan now gets cloud sync (locked May 27 2026, supersedes "Free = local-only" rule).

---

## What changed and why

Until now, four pages (customers, bills, stock, pos-admin) and the billing
page had Pro-plan gates on every cloud read AND every cloud write:

```js
if (isPro() && _online && _shopId) {
  // talk to cloud
} else {
  // localStorage only
}
```

This produced two real-world problems:

1. **Data invisible on second device.** A user creates a customer on their
   laptop. Logs in from phone. Customer Book is empty — because Free plan
   never wrote to cloud, and Pro plan reads were also gated (the gate
   misfired when `localStorage.sbp_shop` was stale on the fresh device).

2. **Beta-program weirdness.** Every active beta shop is Business-tier, so
   `isPro()` *should* return true everywhere. But the moment `sbp_shop` is
   missing or stale on a device, `_sbpPlanInfo()` falls back to `'free'`,
   the gate blocks, and the user experiences total data invisibility on
   that device.

3. **Cross-device data loss when localStorage clears.** Free plan users
   who clear browser cache, switch browsers, reinstall — lose everything.

**The fix:** drop `isPro()` from all 13 cloud-access gates (4 reads + 9
writes/storage uploads across 5 files). Cloud sync now works for any
plan whenever the user is online.

## What this does NOT change

- **Free plan still has a watermark** on bills ("Powered by ShopBill Pro").
  That's the viral acquisition channel and stays unchanged.
- **Pro/Business feature gates are intact.** Loyalty program, WhatsApp
  sending, advanced reports, GSTR, multi-vertical, online ordering,
  multi-user PINs, audit log — all still Pro/Business only. These are
  the actual value drivers.
- **Offline behavior is unchanged.** Every page still reads localStorage
  first (instant), only attempts cloud if `_online`, falls back
  gracefully if cloud is unreachable. Offline writes still go to
  localStorage with `local_*` IDs.
- **No sync queue yet.** Offline writes created while disconnected
  still don't auto-sync back to cloud on reconnect. That's the v8.3
  work — a separate batch.

## Cost impact

At ~50 MB/year per active shop and your 1,000-paying-user target,
Supabase storage cost is **₹0** (well within the 8 GB Pro tier
included). At 10,000 active shops total, ~₹2,300/month. Negligible
against revenue at that scale.

---

## DEPLOY PATHS

| Action  | Path                  | Notes                                          |
|---------|-----------------------|------------------------------------------------|
| REPLACE | `customers.html`      | Repo root. 4 cloud-access gates unlocked.      |
| REPLACE | `bills.html`          | Repo root. 1 read gate unlocked.               |
| REPLACE | `stock.html`          | Repo root. 1 read gate unlocked.               |
| REPLACE | `pos-admin.html`      | Repo root. 3 gates unlocked (product CRUD + photo). |
| REPLACE | `billing.html`        | Repo root. 4 gates unlocked (bill save, customer create, payment update, init read). |

All 5 files at repo root. No SQL migrations. No Edge Functions. No
Supabase changes. No vercel.json changes.

## Deploy steps

1. GitHub Desktop → drop the 5 files into repo root (overwrite).
2. Commit: "v8.2 — Cloud-for-everyone: unlock cloud sync for Free plan"
3. Push to main → Vercel auto-deploys (~2 min).
4. Existing users hard-refresh (Ctrl+Shift+R) on their devices. Cloud
   sync becomes active immediately for every plan.

---

## Verification

### Test 1 — Customer Book visible on second device (the original bug)

1. On Device A (laptop), open customers.html, create 3 customers.
2. Check Supabase: `SELECT count(*) FROM customers WHERE shop_id = '<id>'`
   → should be 3 (was 0 before v8.2 if shop was on Free).
3. Open the app on Device B (different browser / incognito / phone)
   with the same login.
4. Open Customers page.

**Expected after v8.2:** all 3 customers appear within 1-2 seconds.

### Test 2 — POS bill on Free plan syncs to cloud

1. Set a test shop to `plan = 'free'` in Supabase.
2. Open billing.html → POS Mode → create a bill.
3. Check Supabase: `SELECT count(*) FROM bills WHERE shop_id = '<id>'`
   → should INCREASE by 1.
4. **Before v8.2:** count stayed flat (Free wrote only locally).
5. **After v8.2:** count increases.

### Test 3 — Stock decrement syncs on Free plan

1. Same free-plan test shop.
2. POS Mode → bill that includes a stocked product.
3. Confirm bill.
4. Check Supabase: `SELECT stock_qty FROM products WHERE id = '<pid>'`
   → should DECREASE by the qty sold.

### Test 4 — Offline behavior still works

1. DevTools → Network → Offline mode.
2. Open billing.html.
3. Create a bill.
4. **Expected:** "📶 Offline — data saved locally" banner visible;
   bill saves with `local_*` ID in localStorage; UI shows it normally.
5. No errors thrown.

### Test 5 — Existing Pro/Business shops unaffected

Open any Pro/Business shop. Everything that worked before still works.
The change strictly adds capability for Free; it doesn't change anything
for higher tiers.

---

## What this enables

After v8.2 deploys, the architecture is uniform: **cloud sync is plan-
agnostic; Free vs Pro/Business is purely about feature access**.

This makes v8.3 (sync queue for offline writes) much cleaner to build —
no need to special-case Free behavior. Just: every write attempts
cloud, queues if offline, drains on reconnect.

---

## Rollback

`git revert` the v8.2 commit. The 5 files return to their pre-v8.2
state with `isPro()&&...&&_shopId` gates restored. Free plan returns
to local-only behavior. No data loss (cloud-stored data stays in
cloud regardless).

Memory rule needs to be reverted separately if rolling back the
strategic decision.
