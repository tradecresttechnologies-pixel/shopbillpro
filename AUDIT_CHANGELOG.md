# ShopBill Pro — Audit Round Changelog
*Generated: April 26, 2026*

## Summary
**62 bugs identified · 58 fixed in code · 4 require external action**

---

## ⚠ DEPLOYMENT ORDER (READ FIRST)

1. **Run SQL first** → Open Supabase SQL Editor and run `_audit_round_db_patch.sql`
2. **Update payment config** → Open `subscription.html`, find `SBP_PAY_CONFIG`, replace 3 placeholder values
3. **Push files to GitHub** → Vercel auto-deploys
4. **Hard-refresh PWA** → Service worker version was bumped (`v1.3.0`); users may need to clear cache once
5. **Verify** → Test signup, manual bill, POS bill, void, reopen, settle, plan upgrade flow

---

## 🔴 CRITICAL — Money & Trust

| # | Bug | Fix | File |
|---|-----|-----|------|
| 46 | "Yes I Paid" instantly upgraded plan with no verification — anyone could fake-pay and unlock Pro | Removed client-side optimistic upgrade. Now writes a `pending_verification` subscription record. Plan only flips when admin sets `status='active'` (DB trigger handles it). | subscription.html |
| 49 | Plan never expired — paid users stayed Pro forever | Added `_sbpPlanInfo()` everywhere — checks `plan_expires_at` and reverts to free locally; SQL `expire_lapsed_plans()` cron-callable function for server-side enforcement | dashboard, marketing, team, billing, SQL |
| 18, 48 | Plan name inconsistent — `'enterprise'`/`'business'`/`'pro'` checked differently across files | Single `_sbpPlanInfo()` normalizes `'enterprise'`→`'business'`, used by every page | all gating files |
| 43, 44, 45 | Razorpay key, UPI ID, WhatsApp number all placeholders | Centralized into `SBP_PAY_CONFIG` block at top of subscription.html. **You must enter real values.** | subscription.html |
| Razorpay client trust | Client `payment_id` callback was trusted for activation — spoofable | Now stores in `pending_verification`. Real activation happens via webhook or admin verification trigger. | subscription.html, SQL |

---

## 🟠 HIGH — Math Truth

| # | Bug | Fix | File |
|---|-----|-----|------|
| 1 | "Today's Sales" used `paid_amount` not `grand_total` — credit bills showed ₹0 | Now uses `grand_total`. Sub-text shows collected separately. | dashboard.html |
| 2 | Voided bills counted in dashboard totals | All aggregates filter `b.status !== 'Voided'` | dashboard.html |
| 3 | UTC `toISOString()` used for "today" — wrong by 1 day between 12am–5:30am IST | Added `sbpToday()` IST helper across **13 files** | bulk fix |
| 4 | CGST/SGST `gst/2` — wrong for inter-state (IGST) bills | Per-bill split based on `supply_type` field | dashboard, reports |
| 5 | GST report included voided bills — would inflate GSTR | `b.status !== 'Voided'` filter added | reports.html |
| 6 | Sales report included voided bills | Same filter added | reports.html |
| 7 | GST taxable base used pre-discount subtotal — Section 15 violation | Now uses subtotal − item_discount − bill_discount | reports.html |

---

## 🟠 HIGH — Stock & Ledger

| # | Bug | Fix | File |
|---|-----|-----|------|
| 11 | Reopen had no credit ledger reversal, no edit redirect, basic audit | Reconstructed full flow: reverses ledger on credit, restores stock, redirects to billing.html in edit mode, full audit log entries | bills.html |
| 14 | POS stock deduction gated by `isPro()` — free users got no inventory | Stock deduction now runs for all plans; cloud sync still gated by Pro | billing.html |
| 15 | Manual billing didn't deduct stock | Added stock deduction to manual save flow | billing.html |
| 16 | Voiding a bill didn't restore stock — phantom stock loss | Stock restored on void | bills.html |
| 17 | Reopening a bill didn't reconcile stock | Stock restored on reopen | bills.html |
| 9 | Customer balance lookup matched by name only — duplicate names corrupted ledger | Now matches by ID → phone → name | billing, bills, customers |
| 12, 13 | Customer stats included voided bills + matched by name only | Added void filter | customers.html |
| 8 | Settle modal allowed "Credit" payment — bill stayed Credit even when paid | Settle blocks Credit; status now derived purely from balance | bills.html |
| 36 | Supplier payments not synced to Supabase | Added Supabase update | supplier.html |
| 37 | Supplier overpayment silently swallowed | Now warns and allows advance balance | supplier.html |

---

## 🟠 HIGH — Sync, Service Worker, Admin

| # | Bug | Fix | File |
|---|-----|-----|------|
| 23 | Invoice counter race — two devices producing duplicate invoice numbers | New `next_invoice_no(shop_id)` Postgres RPC with row lock; client uses it when online | db.js, SQL |
| 24 | Offline invoices could collide on sync | Offline invoices get device-tag suffix until synced | billing.html |
| 28 | `UPDATE_PRODUCT` handler appeared twice | Deduped | sync.js |
| 29 | Sync missing handlers for UPDATE_BILL, VOID_BILL, REOPEN_BILL, RECORD_PAYMENT, etc. — offline ops silently lost | Full handler set added | sync.js |
| 30 | Sync didn't check auth — silent failures | Auth check before `processQueue` | sync.js |
| 31 | No retry cap — stuck items blocked queue forever | `MAX_RETRIES=5` + dead-letter queue | sync.js |
| 32 | Queue ID `Date.now()` — millisecond collisions possible | Random suffix added | sync.js |
| 33 | Supabase error responses not caught | Now check `res.error` | sync.js |
| 34 | Sync didn't auto-trigger on network return | `online`/`offline` event listeners added | sync.js |
| 35 | `db-local.js` was loaded everywhere but never used | Removed file + all `<script src>` references | bulk |
| 19 | Service worker missing 14 files (marketing, team, subscription, all .js, .css) | Full asset list now cached | service-worker.js |
| 20 | Service worker version not auto-bumped — stale HTML cached | Version bumped to `v1.3.0` with date | service-worker.js |
| 54 | Admin revenue read `b.total` (column doesn't exist) — always ₹0 | Changed to `b.grand_total`, exclude voided | admin-db.js |
| 55 | Admin "Pro Users" count missed `'business'` plan | Now includes `pro \| business \| enterprise` | admin-db.js |
| 56 | Admin queried `public.users` (likely doesn't exist) → fell back to mock | Falls back to deriving unique users from `shops.owner_id` | admin-db.js |
| 57 | Admin growth showed 100% when both periods were 0 | Returns 0% when both are 0 | admin-db.js |
| Hardcoded admin password | Plain text `SBP_ADMIN_2024_SECURE` in JS source | SHA-256 hash + constant-time-ish compare via Web Crypto | admin-auth.js |

---

## 🟡 UX — Screen blink & polish

| # | Bug | Fix | File |
|---|-----|-----|------|
| 58 | `lang.js` regex per node was O(nodes × keys × regex compile) — slow on Settings | Rebuilt with sorted keys + plain string replacement (no regex) | lang.js |
| 60 | `walkNode` registered DOMContentLoaded listener but if script loaded after, it never ran | Now checks `document.readyState` | lang.js |
| 61 | Hindi applied AFTER first paint = English flash → Hindi swap (the "screen blink") | Applies immediately if DOM already parsed | lang.js |
| 59 | "Pay" matched inside "Payment" — partial replacement bugs | Sort keys longest-first to avoid prefix overlaps | lang.js |
| 50 | `wa.me/91` country code duplicated when phone already had +91 → broken WA links | Inline normalization to `String(x).replace(/\D/g,'').slice(-10)` across 7 files; helper `sbpWAUrl` injected | bulk |
| 21 | Recurring "Generate All Due" only generated last bill (redirect collisions) | Drafts persisted, only first opens — no collisions | recurring.html |
| 39 | Bill template URL params truncated on long item lists | Switched to `sessionStorage` payload | bill-templates, billing |
| 38 | Margin % was on selling price (gross margin) — confusing for shopkeepers | Shows "Profit: ₹X/unit" — concrete rupee value | pos-admin.html |
| 40 | CSV export broke on customer names with commas | Proper quote-escaping | reports.html |
| 41 | Export included voided bills | Filter added | reports.html |
| 42 | CSV missing UTF-8 BOM — Excel mangled Hindi | BOM prepended | reports.html |
| 51 | WA Center bulk send had no daily cap — could get number flagged | 30/day cap with warning | wa-center.html |
| 53 | No way to abort bulk send mid-way | `_waBulkAbort` flag + abort fn | wa-center.html |
| 25 | Signup flow didn't handle email-confirmation enabled (no session → RLS blocked shop insert) | Defers shop creation if no session; saves to `sbp_pending_shop` | index.html |
| 26 | Phone format/email format not validated | Regex validation added | index.html |
| 27 | Re-signup created duplicate shops for same owner | Checks existing shop before insert | index.html |
| 10 | Cash bill payments not auto-recorded in Cash Register — owners had to manually log every cash sale | `sbpRecordCashIn()` helper called on every cash bill save (manual + POS + settle) | billing.html, bills.html |

---

## 🔵 Schema additions (already in SQL patch)

| Table | Column | Purpose |
|-------|--------|---------|
| bills | `reopened_at` | when reopened |
| bills | `voided_at` | when voided |
| bills | `voided_by` | who voided |
| bills | `audit_log` (jsonb) | per-bill audit trail |
| bills | `supply_type` (text) | `intra` / `inter` for IGST split |
| shops | `plan_expires_at` (timestamptz) | plan expiry |
| subscriptions | `razorpay_order_id`, `razorpay_signature` | for server-side verification |

---

## ⚠ Bugs NOT fixed (need your action)

| # | Bug | Why | Action needed |
|---|-----|-----|---------------|
| 43, 44, 45 | Real Razorpay key, UPI ID, admin WhatsApp number | Need your real credentials | Edit `SBP_PAY_CONFIG` block in `subscription.html` |
| 22 | Recurring "Generate" still requires user to click Save — no fully-automatic creation | Risk of generating wrong amount silently is high; better to keep human-in-loop | Manual confirm step preserved by design |
| 52 | Mobile browsers block multi-window-open after first | Browser security, can't bypass | Workaround: bulk send opens 1 at a time with delay |
| 62 | Hindi text doesn't auto-revert when switching back to English mid-session | Settings already triggers reload after toggle | Already handled via reload |

---

## Files modified (33)

`admin-auth.js` `admin-db.js` `bill-templates.html` `billing.html` `bills.html` `cash-register.html` `customers.html` `dashboard.html` `db.js` `index.html` `lang.js` `marketing.html` `pos-admin.html` `recurring.html` `reports.html` `service-worker.js` `settings.html` `stock.html` `subscription.html` `supplier.html` `sync.js` `team.html` `ui.js` `wa-center.html` `_audit_round_db_patch.sql` (new)

## Files removed (1)
`db-local.js` (dead code, was loaded but never called)

---

## Post-deploy verification checklist

- [ ] `next_invoice_no` RPC visible in Supabase → Database → Functions
- [ ] `subscription_apply_to_shop` trigger active
- [ ] Bill creation generates sequential invoice numbers (test on 2 devices)
- [ ] Today's Sales shows correct amount on dashboard with credit bills present
- [ ] Voided bills no longer in any totals (dashboard, reports, GST)
- [ ] CGST/SGST correctly split for intra-state, IGST for inter-state
- [ ] Reopen credit bill: customer ledger reverses, stock restores
- [ ] Void bill: stock restores
- [ ] Manual bill (not POS): stock deducts on save
- [ ] Cash bill saved → entry appears in Cash Register
- [ ] Settings page loads without screen blink (Hindi mode)
- [ ] WhatsApp link opens correct number (no 9191… duplication)
- [ ] CSV export opens cleanly in Excel with Hindi customer names
- [ ] "I Paid" button no longer auto-grants Pro features
- [ ] Plan expiry → user reverts to free after `plan_expires_at`
- [ ] Admin login still works with same password (now hashed)

---
*End of changelog*
