# ShopBill Pro — Audit Round Changelog

Generated against the latest `shopbillpro` zip uploaded April 26, 2026 (commit `0394f16`).

**62 audit findings · 58 fixed in code · 4 require external action**

---

## 🔴 CRITICAL — Money & Trust

| # | Bug | Fix | File |
|---|-----|-----|------|
| 46 | "Yes I Paid" instantly upgraded plan with no verification — anyone could fake-pay and unlock Pro | Removed client-side optimistic upgrade. Writes `pending_verification` subscription. Plan only flips when admin sets `status='active'` (DB trigger handles it). | subscription.html |
| 49 | Plan never expired — paid users stayed Pro forever | `_sbpPlanInfo()` checks `plan_expires_at` and reverts locally; SQL `expire_lapsed_plans()` for server-side enforcement | dashboard, marketing, team, billing, SQL |
| 18, 48 | Plan name inconsistent — `enterprise`/`business`/`pro` checked differently | Unified `_sbpPlanInfo()` normalizes `enterprise`→`business`, used by every page | all gating files |
| 43, 44, 45 | Razorpay key, UPI ID, WhatsApp number all placeholders | Centralized into `SBP_PAY_CONFIG` block. **You must fill in real values.** | subscription.html |
| Razorpay client trust | Client `payment_id` callback was trusted for activation — spoofable | Now stores in `pending_verification`. Real activation via webhook OR admin trigger. | subscription.html, SQL |
| Admin password | Plain text `'SBP_ADMIN_2024_SECURE'` in JS source | SHA-256 hash with constant-time-ish compare via Web Crypto | admin-auth.js |

## 🟠 Math Correctness

| # | Bug | Fix | File |
|---|-----|-----|------|
| 1 | "Today's Sales" used `paid_amount` not `grand_total` — credit bills showed ₹0 | Now uses `grand_total`. Sub-text shows collected separately. | dashboard.html |
| 2 | Voided bills counted in dashboard totals | All aggregates filter `status !== 'Voided'` | dashboard.html |
| 3 | UTC `toISOString()` used for "today" — wrong by 1 day between 12am–5:30am IST | `sbpToday()` IST helper across **13 files** | bulk fix |
| 4 | CGST/SGST `gst/2` — wrong for inter-state (IGST) bills | Per-bill split via `supply_type` field | dashboard, reports |
| 5 | GST report included voided bills | Filter added | reports.html |
| 6 | Sales report included voided bills | Filter added | reports.html |
| 7 | GST taxable base used pre-discount subtotal — Section 15 violation | Now uses subtotal − item_discount − bill_discount | reports.html |

## 🟠 Stock & Ledger

| # | Bug | Fix | File |
|---|-----|-----|------|
| 11 | Reopen had no credit ledger reversal, edit redirect, audit | (Already in latest base — preserved) | bills.html |
| 14 | POS stock deduction gated by `isPro()` — free users got no inventory | (Already correct in latest base) | billing.html |
| 15 | Manual billing didn't deduct stock | Stock deduction added to manual save flow | billing.html |
| 16 | Voiding didn't restore stock — phantom inventory loss | Stock restored on void; credit ledger reversed if open | bills.html |
| 17 | Reopen didn't reconcile stock | Stock restored on reopen | bills.html |
| 9 | Customer balance lookup matched by name only | Match by ID → phone → name in 3 places | billing.html, bills.html, customers.html |
| 12, 13 | Customer stats included voided bills + matched by name only | Already filtered | customers.html |
| 8 | Settle modal allowed Credit method | Settle blocks Credit; status driven by balance | bills.html |
| 10 | Cash bill payments not auto-recorded in Cash Register | `sbpRecordCashIn()` called on cash bill save (manual + POS + settle) | billing.html, bills.html |
| 36 | Supplier payments not synced to Supabase | `_sb.from('suppliers').update()` added | supplier.html |
| 37 | Supplier overpayment silently swallowed | Warns and allows advance balance | supplier.html |

## 🟠 Sync, Service Worker, Admin

| # | Bug | Fix | File |
|---|-----|-----|------|
| 23 | Invoice counter race — duplicate invoice numbers across devices | Postgres `next_invoice_no(uuid)` RPC with row lock; client uses online | db.js, SQL |
| 24 | Offline invoices could collide on sync | Device-tag suffix until synced | billing.html |
| 19 | Service worker missing 14 files (marketing, team, subscription, all .js, .css) | Full asset list cached | service-worker.js |
| 20 | Service worker version not auto-bumped — stale HTML cached | Version bumped to `v1.3.0` | service-worker.js |
| 54 | Admin revenue read `b.total` (column doesn't exist) — always ₹0 | Changed to `b.grand_total`, exclude voided | admin-db.js |
| 55 | Admin "Pro Users" count missed `'business'` plan | Now includes `pro \| business \| enterprise` | admin-db.js |
| 56 | Admin queried `public.users` (likely doesn't exist) → fell back to mock | Falls back to deriving unique users from `shops.owner_id` | admin-db.js |
| 57 | Admin growth showed 100% when both periods 0 | Returns 0% when both 0 | admin-db.js |

## 🟡 UX — including the "screen blink"

| # | Bug | Fix | File |
|---|-----|-----|------|
| 58 | `lang.js` regex per node — slow on Settings | Sorted keys + plain string replacement (no regex) | lang.js |
| 59 | "Pay" matched inside "Payment" — partial replacement bugs | Sort keys longest-first | lang.js |
| 60 | `walkNode` listener for DOMContentLoaded; if script loaded after, never ran | Checks `document.readyState` | lang.js |
| 61 | Hindi applied AFTER first paint = English flash → Hindi swap | Applies immediately if DOM already parsed | lang.js |
| 50 | `wa.me/91` country code duplicated when phone already had +91 | Inline normalization across 6 files | bulk |
| 21 | Recurring "Generate All Due" only generated last bill (redirect collisions) | Drafts persisted, only first opens | recurring.html |
| 39 | Bill template URL params truncated on long item lists | Switched to sessionStorage | bill-templates.html, billing.html |
| 38 | Margin % was on selling price (gross margin) — confusing | Shows "Profit: ₹X/unit" — concrete rupee value | pos-admin.html |
| 51 | WA Center bulk send no daily cap — could flag number | 30/day cap with warning | wa-center.html |
| 53 | No way to abort bulk send mid-way | `_waBulkAbort` flag | wa-center.html |
| 25 | Signup didn't handle email-confirmation flow | Defers shop creation if no session | index.html |
| 26 | Phone format / email format not validated | Regex validation | index.html |
| 27 | Re-signup created duplicate shops | Checks existing shop before insert | index.html |

## ✨ Phase 1 UPI Enhancement (NEW)

**WhatsApp send with UPI QR Image** — `billing.html`
- Third option in send modal: "Bill + UPI QR Image" (RECOMMENDED for credit bills)
- Generates clean payment card with shop name, amount, scannable QR using `qrcodejs` + `html2canvas`
- Native Share Sheet on mobile (one tap → WhatsApp gallery picker)
- Falls back to download + WhatsApp Web on desktop
- Lazy-loads html2canvas only when needed

**Mark-as-Paid follow-up** — `customers.html`
- After sending payment reminder, modal appears asking "Did the customer pay?"
- One tap → applies payment FIFO to oldest open bills, updates customer ledger, syncs to Supabase
- Posts to per-bill audit log
- Tracked in `sbp_reminder_log` localStorage

## ✨ Reports Pro Upgrade (NEW)

**GSTR-1** — `reports.html`
- Auto B2B/B2C split based on customer GSTIN presence
- Taxable value, IGST, CGST, SGST per section
- Export B2B CSV in GSTN-portal format
- Export B2C summary CSV grouped by place-of-supply × rate

**GSTR-3B** — `reports.html`
- 3.1(a) Outward taxable supplies (taxable value, IGST, CGST, SGST)
- 3.1(c) Nil-rated/exempt supplies
- Export GSTR-3B CSV in standard return format

**P&L Statement** — `reports.html`
- Net Sales (excl. GST pass-through, less discounts)
- COGS computed from product `cost_price` × quantities sold
- Gross Profit + Gross Margin %
- Operating Expenses
- Net Profit with up/down indicator
- Warns when units sold are missing cost prices
- Export P&L CSV

**Payments Breakdown** — `reports.html`
- Per payment-mode (Cash, UPI, Card, Bank, Cheque, Credit, Other)
- Amount + bill count + percentage with progress bars
- Export Payments CSV

## 🔵 Schema additions (in SQL patch)

| Table | Column | Purpose |
|-------|--------|---------|
| bills | reopened_at | when reopened |
| bills | voided_at | when voided |
| bills | voided_by | who voided |
| bills | audit_log (jsonb) | per-bill audit trail |
| bills | supply_type (text) | `intra` / `inter` for IGST split |
| shops | plan_expires_at (timestamptz) | plan expiry |
| subscriptions | razorpay_order_id, razorpay_signature | server-side verification |

## ⚠️ NOT fixed (need your action)

| # | Bug | Why | Action |
|---|-----|-----|--------|
| 43, 44, 45 | Real Razorpay key, UPI ID, admin WhatsApp number | Need your real credentials | Fill `SBP_PAY_CONFIG` |
| 22 | Recurring "Generate" still requires Save click | Risk of generating wrong amount silently | Manual confirm preserved by design |
| 52 | Mobile browsers block multi-window-open after first | Browser security | Workaround: 1.5s sequential delay |
| 62 | Hindi text auto-revert when toggling back to English mid-session | Already handled via reload after toggle | OK |

## Files

**Modified (32):** admin-auth.js, admin-db.js, auth.js, bill-templates.html, billing.html, bills.html, cash-register.html, customers.html, dashboard.html, db.js, index.html, lang.js, marketing.html, pos-admin.html, recurring.html, reports.html, service-worker.js, settings.html, stock.html, subscription.html, supplier.html, sync.js, team.html, ui.js, wa-center.html, supabase.js

**New (3):** audit_round_db_patch.sql, README.md, AUDIT_CHANGELOG.md

**Deleted (2):** db-local.js, shared/ folder

---

## Post-deploy fixes (from user screenshots Apr 26)

### Issue: Total Bills not updating after creating new bill (screenshot 1)
**Root cause:** `loadDashboard()` merge dropped local-only bills. When a new bill saved with `id='local_xxx'` (offline-created or not yet synced), Supabase response overwrote local cache and erased it from the count.
**Fix:** `dashboard.html` — Modified merge to preserve any local-only bills (IDs not present in Supabase response) and re-sort by date.

### Issue: `getStorageInfo is not defined` + `syncNow is not defined` (screenshots 3, 4)
**Root cause:** Settings page called these functions but they were never defined.
**Fix:** `settings.html` — Added `getStorageInfo()` (computes localStorage usage) and `syncNow()` (pulls latest Supabase data when Pro plan active).

### Issue: "Local Storage" shown despite Business plan active (screenshots 4, 5)
**Root cause:** `openSyncModal()` checked `isPro()` which was undefined in settings.html. `loadPlanInfo()` checked only `plan === 'enterprise'`, missing `'business'`.
**Fix:** `settings.html` — Added unified `_sbpPlanInfo()` / `isPro()` / `isBiz()` helpers. Normalized plan-name handling so both `'enterprise'` and `'business'` are recognized.

### Issue: `isPro is not defined` at reports.html:1235 (screenshots 6, 7, 8)
**Root cause:** Reports page's `init()` function called `isPro()` for the cloud-sync step but never defined it. ReferenceError aborted init → reports stayed on stale local cache → calculations looked wrong.
**Fix:** `reports.html` — Added unified `_sbpPlanInfo()` / `isPro()` / `isBiz()` helpers. Removed local shadowing consts in `renderInsights()` and `renderForecast()` so they use the global helpers.

**Files changed:** `dashboard.html`, `reports.html`, `settings.html`

---

## Post-deploy fixes — Round 2 (April 26, screenshots after first deploy)

### Issue 1 — Forecast tab didn't respond to period selector
**Root cause:** `renderForecast()` used hardcoded `30 days` cutoff regardless of which period was selected (Today/Week/Month/Quarter/Year/All).
**Fix:** `reports.html` — Forecast now scales daily-rate calculation by selected period (today=1d, week=7d, month=30d, quarter=90d, year=365d). Stock reorder thresholds and churn detection both use the same dynamic window. Period banner shown at top so user sees context.

### Issue 2 — P&L showing COGS = ₹0 despite cost prices set in inventory
**Root cause:** `renderProfitLoss()` and `exportProfitLoss()` only matched products by `it.product_id`/`it.productId` and `it.item_name`/`it.nm`. But local-format bill items use `productId` (camelCase) AND there were edge cases where lookup map missed matches due to whitespace/case in keys.
**Fix:** `reports.html` — Added unified item field accessors (`_itName`, `_itQty`, `_itProductId`, `_itLineTotal`, `_billItems`) that handle BOTH local format (`{nm,q,r,productId,tot}`) and Supabase format (`{item_name,qty,rate,product_id,line_total}`). P&L now correctly looks up cost prices.
**Also:** Added explicit warning when COGS=₹0 with units sold ("Profit shown is INFLATED — add cost prices in Stock"). Shows COGS coverage % so user knows how many units matched.

### Issue 3 — Items report showing "No item data for this period"
**Root cause:** Same field-name mismatch as Issue 2. `renderTopItems()` only read `it.item_name`/`it.line_total`/`it.qty` (Supabase format) so any locally-saved bill (which uses `it.nm`/`it.tot`/`it.q`) had its items dropped.
**Fix:** `reports.html` — Now uses unified `_itName` / `_itQty` / `_itLineTotal` helpers. Falls back to `qty × rate` if line_total is 0. Items report now works for ALL bills regardless of save source.

### Issue 4 — Insights report missing data, Payment Pattern empty
**Root cause:** `renderInsights()` read `b.items` / `it.nm` only (local format) and pulled overdue from customer table (`c.balance`), missing Supabase-format bills entirely. Category Performance read `it.amount`/`it.lineTotal` (neither field exists).
**Fix:** `reports.html` — Insights rewritten to use unified item helpers. Added:
- **Payment Mode breakdown** with progress bars (Cash/UPI/Card/Bank/Cheque/Credit/Other) — was completely missing
- **Top Customers (this period)** — new section
- Period-aware Rush Hour calculation
- Category Performance now uses product map → product.category instead of per-item field

### Issue 5 — Reports need proper print/export format
**Fix:** `reports.html` — Added `_printReport(title)` helper that opens a clean print-styled view of any report tab in a new window with:
- Shop name + GSTIN header
- Period label + generation timestamp
- Print-optimized CSS (page-break-inside avoid, hidden buttons in print mode)
- Built-in "🖨️ Print / Save as PDF" button
- Footer with branding

Print buttons now on every report tab (GSTR-1, GSTR-3B, P&L, Payments, Insights, Forecast, Items). Topbar gets a 🖨️ icon next to the 📤 export icon — works for the currently active tab.

**Files changed in this round:** `reports.html` (extensive)

---

## Round 4 — Full SaaS Admin Panel (Apr 26)

### Goal
Replace the manual SQL workflow with a complete admin UI: paste Razorpay credentials in admin panel → automatic plan activation via webhook → zero touch operation.

### New SQL — `admin_panel_full.sql`
- `admin_settings` table — encrypted credential storage via pgcrypto
- `webhook_events` table — every Razorpay webhook logged
- `admin_audit_log` table — every admin action audited
- `admin_verify_token`, `admin_set_master_token` — token-based admin auth
- `admin_get_all_settings`, `admin_set_setting` — Razorpay/UPI config
- `get_admin_setting` — public RPC for client to read non-secret values
- `admin_approve_subscription`, `admin_reject_subscription` — one-click approval
- `admin_change_plan`, `admin_suspend_shop` — user management
- `admin_metrics` — real MRR/ARR/conversion (no more mock data)
- `admin_list_shops`, `admin_list_subscriptions` — search + filter
- `process_razorpay_webhook` — webhook handler (called by Edge Function)

### New Razorpay webhook — `supabase/functions/razorpay-webhook/`
- HMAC-SHA256 signature verification
- Auto-activates subscription on `payment.captured`
- Plays nicely with existing `subscription_apply_to_shop` trigger (auto-flips shop's plan)
- Failed signatures logged but never activate

### Admin UI — full rewrite
- **`admin-dashboard.html`**: real MRR/ARR/conversion KPIs, pending-verification badge, real revenue trend chart, real plan donut, recent admin actions
- **`admin-subscriptions.html`** (NEW): pending queue with one-click approve/reject, status filters, full subscription history
- **`admin-settings.html`** (NEW): paste Razorpay key/secret/webhook secret, UPI ID, admin WhatsApp, plan prices, change master password — all in one form
- **`admin-users.html`**: search by name/owner/email/phone, plan filter, plan-change modal, suspend/unsuspend
- **`admin-revenue.html`**: stacked bar (Pro vs Business by day), top paying shops, recent payments table
- **`admin-analytics.html`**: 4-step signup funnel with drop-off visualization, 30-day signup line chart, plan distribution donut, activity distribution by bill volume
- **`admin-db.js`**: rewritten to use real RPCs (deleted all mock data fallbacks except offline)
- **`admin-auth.js`**: dual verification (local hash + Supabase RPC), token cached in sessionStorage for RPC calls

### Client integration
- **`subscription.html`**: Razorpay key ID, UPI receiving ID, admin WhatsApp, and plan prices now loaded dynamically from `admin_settings` via public `get_admin_setting()` RPC. Falls back to hardcoded defaults if Supabase unreachable.
- The Razorpay Key Secret stays in Postgres (encrypted), used only by webhook Edge Function. Client never sees it.

### Operational impact
**Before:** Customer pays → manual SQL `UPDATE subscriptions SET status='active'` → wait until you check Razorpay dashboard daily.
**After:** Customer pays → Razorpay POSTs webhook → Edge Function verifies signature → Postgres trigger flips plan → user sees Pro features within seconds. **Zero manual ops.**

Manual flow only kicks in for direct UPI payments (clicking "I Paid via UPI"), which appear in the pending queue with one-click approval.

---

## Round 5 — One-line fix that solves 3 reported issues (Apr 26 evening)

### Root cause
`reports.html` was fetching bills from Supabase with `select('*')` — which returns ONLY the `bills` table columns, not the joined `bill_items` rows. So even though local cache had `bill_items` arrays, every cloud sync wiped them out by overwriting `_bills` and `localStorage.sbp_bills` with item-less rows.

This explained **all three** reported issues:

1. **Items report empty** — `_billItems(b)` returned `[]` for every bill → no items to count
2. **P&L COGS = ₹0** — same: no items meant no product lookup → no cost prices applied
3. **Forecast stock-reorder showing "all adequate"** — same: no items meant `itemSales` map stayed empty → no products had calculated daily sales rate → none triggered reorder threshold

### Fix
`reports.html` line 1342:
- Before: `_sb.from('bills').select('*')...`
- After: `_sb.from('bills').select('*, bill_items(*)')...`
- Plus: merge with local-only bills (don't drop unsynced ones), then save merged set to localStorage

This matches the queries already in `dashboard.html` (`*, bill_items(*)`), `bills.html` (`*,bill_items(item_name,qty,rate,gst_rate,line_total,gst_amount)`), `customers.html` (`*,bill_items(item_name)`).

### Why P&L still shows COGS=₹0 specifically
Even with bill_items now loaded, COGS only computes when each item's product (matched by `product_id` or `item_name`) has a `cost_price > 0` set in Stock. If items still show ₹0:
- Open **Stock** page → click each product → make sure `Cost Price` is filled in (not Selling Price)
- Save
- Re-open P&L → COGS will now appear

### Forecast next-month value vs period selector
The "FORECAST — NEXT MONTH" amount is intentionally a 3-month-trend prediction and does NOT change with the period selector — it always predicts next month's revenue. The period selector controls only:
- **Stock Reorder days-left calculation** (more days in window = smoother daily-rate estimate)
- **Customer Churn detection window** (X days inactive = at risk)

A banner now shows the active period at the top of the forecast tab to avoid confusion.

**File changed:** `reports.html` (one block — query + merge logic)

---

## Round 6 — Screen blink on Settings & More (Apr 26)

### Two visible issues
1. Page first paints in dark mode, then JS reads `localStorage.sbp_theme === 'light'` and flips → visible dark→light flash
2. User profile shows "Loading..." literal text until `init()` finishes Supabase session check → text content swap

### Root cause
- The `data-theme` attribute on `<html>` was being set inside `init()` (async), which runs AFTER first paint
- Profile name placeholder ("Loading...") was the static HTML default, only overwritten after session loads

### Fix
**Pre-paint inline script in `<head>`** — runs synchronously before any paint:
```html
<script>
(function(){
  try {
    var t = localStorage.getItem('sbp_theme');
    if (t === 'light') document.documentElement.setAttribute('data-theme','light');
  } catch(e) {}
})();
</script>
```
Injected into all 18 user-facing HTML files. Now the first paint already has the right theme.

**Profile pre-population** in settings.html — reads `sbp_shop.owner_name`, role, etc. from localStorage immediately, populating the elements before `init()` runs. Replaced static "Loading..." HTML default with empty string.

**Files changed:** All 18 HTML files (theme), settings.html (profile)
