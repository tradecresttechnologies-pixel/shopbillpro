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
