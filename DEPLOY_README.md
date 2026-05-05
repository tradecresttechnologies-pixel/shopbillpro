# ShopBill Pro — Customer Loyalty / Rewards Module

**Date:** May 5, 2026
**Migration:** `009_loyalty.sql`
**Files in this batch (5):**

```
db/migrations/009_loyalty.sql    [NEW]  ─── 621 lines, schema + 8 RPCs + RLS
lib/loyalty.js                   [NEW]  ─── client wrapper, plan-gated
settings.html                    [PATCH] ─── adds Loyalty section + config modal (~250 lines added)
customers.html                   [PATCH] ─── adds points balance + transactions in customer detail (~115 lines added)
billing.html                     [PATCH] ─── points banner + redeem flow + earn-on-save hooks (~205 lines net)
```

---

## Spec (locked May 5, 2026)

- **Earn:** ₹100 of taxable_total = 1 point (configurable per shop)
- **Redeem:** 100 points = ₹10 discount (configurable per shop)
- **Earn base:** taxable_total (subtotal − discount), pre-GST
- **Redemption:** applied as POST-GST final discount (price adjustment, not GST-affecting). Same model as Croma / FabIndia. GSTR-1 stays accurate.
- **Plan gating:** Free = disabled. Pro / Business = enabled.
- **Bill void:** auto-reverses earn AND restores redeemed points (`sbp_loyalty_reverse_bill` RPC, ready — needs wiring in `bills.html` v2).

---

## Deploy Order

### 1. SQL — run in Supabase SQL Editor (in order)

The pre-existing migrations must already be deployed. The new migration goes last:

```
audit_round_db_patch.sql       [already deployed]
admin_panel_full.sql           [already deployed]
db/migrations/003_business_categories.sql  [already deployed]
db/migrations/004_seo_admin.sql            [already deployed]
db/migrations/005_beta_logic.sql           [already deployed]
db/migrations/008_public_shop_page.sql     [already deployed]
db/migrations/009_loyalty.sql              ★ NEW — run this
```

The migration is **idempotent** (uses `IF NOT EXISTS` / `CREATE OR REPLACE` / `ON CONFLICT DO NOTHING`). Safe to re-run.

### 2. Files — push to GitHub repo

Replace these in the PWA repo root:
- `lib/loyalty.js` (new file — drop in)
- `settings.html` (replace existing)
- `customers.html` (replace existing)
- `billing.html` (replace existing)

Vercel will auto-deploy on push (~30 seconds). No build step needed.

### 3. Optional — schedule daily expiry job

Run once in Supabase SQL editor (only if pg_cron is available):

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('loyalty-expire-daily', '30 1 * * *',
  $$ SELECT public.sbp_loyalty_expire_due(); $$);
```

This expires points monthly on schedule. If skipped, points still expire correctly (the `sbp_loyalty_balance` RPC honors `expires_at`), but the audit ledger doesn't get the explicit "expire" rows until someone calls `sbp_loyalty_expire_due()`.

---

## Post-deploy verification (Supabase SQL Editor)

```sql
-- 1. Tables exist with correct columns
\d sbp_loyalty_config
\d sbp_customer_loyalty
\d sbp_loyalty_transactions

-- 2. RLS enabled
SELECT tablename, rowsecurity FROM pg_tables
WHERE tablename LIKE 'sbp_loyalty%';

-- 3. Functions exist + permissions correct
SELECT proname, prosecdef FROM pg_proc
WHERE proname LIKE 'sbp_loyalty%';

-- 4. Smoke test for a real shop (replace UUID)
SELECT sbp_loyalty_balance(
  'YOUR-SHOP-UUID-HERE',
  'YOUR-CUSTOMER-UUID-HERE'
);
-- Expected: {"ok": true, "balance": 0, "earned": 0, ...}

-- 5. Confirm bills table has new columns
SELECT column_name FROM information_schema.columns
WHERE table_name = 'bills'
  AND column_name LIKE 'loyalty%';
-- Expected: loyalty_redemption_amount, loyalty_points_redeemed, loyalty_points_earned
```

---

## Testing the live UI

### A. Enable loyalty for a Pro shop
1. Log in to a shop with Pro / Business plan
2. Settings → see new **🎁 Customer Loyalty** section between Auto-Send and Plan
3. Tap the row → opens the config modal
4. Toggle "Enable Loyalty Program" → set rates → Save
5. Verify the menu shows "ON" badge in green

### B. Earn flow (saved customer)
1. Billing page → Pick a saved customer (the orange loyalty banner appears under Customer Info)
2. Add items → save bill
3. Toast: `🎁 [Name] earned X points! Total: Y`
4. Re-open same customer → the banner shows updated balance
5. Customers → tap that customer → loyalty section shows the earn transaction

### C. Redeem flow
1. Pick a customer with ≥ 100 points (default minimum)
2. The "Redeem" button appears in the banner
3. Tap → prompt asks for points (multiples of 100)
4. Enter (e.g. 200) → "₹20 loyalty discount applied" toast
5. Save bill → toast confirms `💸 Redeemed 200 pts (₹20 off)` + earn toast for the new bill

### D. Free plan check
1. Switch to a Free-plan shop
2. Settings → Loyalty section shows "🔒 Available on Pro & Business"
3. Toggle is disabled
4. Open config modal → shows the locked notice + Save button disabled

---

## Known v2 follow-ups (not shipped tonight)

- [ ] **Bill void hook** — `bills.html` should call `SBPLoyalty.reverseBill(billId)` when status flips to `'voided'` or `voided_at` is set. The RPC is built and ready; just needs the call site.
- [ ] **Void-from-billing edit flow** — if Vinay reopens and re-saves a bill from the billing page, current code does NOT auto-reverse loyalty for the original save before re-applying. v2: detect bill_id reuse in `_loyaltyHookAfterBillSave` and skip if already earned.
- [ ] **POS mode loyalty banner placement** — banner exists in Manual section's Customer Info. POS mode customer state lives in a separate field set; banner doesn't render in POS layout. Works for the cashflow (saving a POS bill calls earn correctly) but the visual indicator is Manual-only in v1.
- [ ] **Birthday bonus / welcome bonus** — schema columns exist (`birthday_bonus_points`, `welcome_bonus_points` on config; `dob` on customers), but no triggers / UI yet. Future enhancement.
- [ ] **WhatsApp message integration** — bill template should append `🎁 You earned X points! Total: Y. Show this message at your next visit for ₹Z off.` Future enhancement.
- [ ] **Reports tab** — loyalty stats (total points outstanding, top-earning customers, redemption rate). Future enhancement.

---

## Schema summary (for reference)

### Tables added

```
sbp_loyalty_config           -- one row per shop (config: rates, expiry, etc.)
sbp_customer_loyalty         -- one row per (shop, customer) — denorm balance
sbp_loyalty_transactions     -- audit ledger of every earn/redeem/expire/manual
```

### Columns added to existing tables

```
bills.loyalty_redemption_amount   numeric  DEFAULT 0
bills.loyalty_points_redeemed     int      DEFAULT 0
bills.loyalty_points_earned       int      DEFAULT 0
customers.dob                     date     NULL    (for future birthday bonus)
```

### RPCs

| Function | Purpose | Called from |
|---|---|---|
| `sbp_loyalty_balance` | Read current balance | customers.html, billing.html |
| `sbp_loyalty_earn_on_bill` | Award points after bill save | billing.html (via `_loyaltyHookAfterBillSave`) |
| `sbp_loyalty_redeem` | Apply redemption to a bill | billing.html (via hook) |
| `sbp_loyalty_reverse_bill` | Reverse on void | NOT WIRED YET — for bills.html v2 |
| `sbp_loyalty_adjust` | Manual admin adjustment | customers.html (Adjust button) |
| `sbp_loyalty_recent_txns` | List transactions | customers.html (detail panel) |
| `sbp_loyalty_expire_due` | Daily expiry job | pg_cron (optional) |

All RPCs are `SECURITY DEFINER` with `auth.uid()` ownership checks. RLS is enabled on all 3 new tables.

---

## File-by-file changeset summary

### `db/migrations/009_loyalty.sql` (NEW)
Tables, indexes, RLS policies, triggers, 8 RPCs.

### `lib/loyalty.js` (NEW)
`window.SBPLoyalty` with: `getConfig`, `saveConfig`, `balance` (60s cache), `recentTxns`, `earnOnBill`, `redeem`, `reverseBill`, `adjust`, `previewEarn`, `maxRedeemable`, `formatMessage`, `clearBalanceCache`, `isPro`, `isBiz`. Plan-gated client + server.

### `settings.html`
- New `<script src="lib/loyalty.js">` tag.
- New `<div class="menu-sec" id="loyalty-section">` between Auto-Send and Plan sections.
- New modal `<div id="loyalty-config-modal">` after lang-modal.
- New JS: `loadLoyaltyStatus`, `toggleLoyaltyEnabled`, `openLoyaltyConfigModal`, `saveLoyaltyConfig`. `loadLoyaltyStatus()` hooked into `init()` after `loadPlanInfo()`.

### `customers.html`
- New `<script src="lib/loyalty.js">` tag.
- New `<div id="cust-loyalty-section">` placeholder inside `cust-detail-modal` innerHTML, before Contact Details.
- `viewCust()` now calls `loadCustomerLoyalty(c.id)` after `openModal`.
- New JS: `loadCustomerLoyalty`, `loadCustomerLoyaltyTxns`, `openLoyaltyAdjust`. Auto-hides if not Pro / loyalty disabled.

### `billing.html`
- New `<script src="lib/loyalty.js">` tag.
- New `<div id="bill-loyalty-banner">` inside Customer Info section, below "Save as Customer" row.
- `pickCustomer(id, name, ...)` now stores `window._loyaltyCustId` + calls `refreshLoyaltyBanner()`.
- 3 hook call sites for `_loyaltyHookAfterBillSave(savedBill)`: Manual save, POS online new bill, POS offline new bill.
- New JS block (160 lines): `refreshLoyaltyBanner`, `openLoyaltyRedeem`, `clearLoyaltyRedemption`, `_loyaltyHookAfterBillSave`, `resetLoyaltyState`, plus state vars (`_loyaltyCustId`, `_loyaltyCustName`, `_loyaltyConfig`, `_loyaltyAppliedPoints`, `_loyaltyAppliedAmount`).

---

## Rollback (if anything breaks)

The HTML files are pure replacements — restore from `git checkout` on `main`.

For SQL, the migration is idempotent and only ADDS objects. To fully undo:

```sql
-- Drop functions (in dependency order)
DROP FUNCTION IF EXISTS sbp_loyalty_recent_txns(uuid, uuid, int);
DROP FUNCTION IF EXISTS sbp_loyalty_expire_due();
DROP FUNCTION IF EXISTS sbp_loyalty_adjust(uuid, uuid, int, text);
DROP FUNCTION IF EXISTS sbp_loyalty_reverse_bill(uuid);
DROP FUNCTION IF EXISTS sbp_loyalty_redeem(uuid, uuid, uuid, int);
DROP FUNCTION IF EXISTS sbp_loyalty_earn_on_bill(uuid);
DROP FUNCTION IF EXISTS sbp_loyalty_balance(uuid, uuid);
DROP FUNCTION IF EXISTS sbp_loyalty_config_set_updated_at();

-- Drop tables (cascades drop policies + indexes)
DROP TABLE IF EXISTS sbp_loyalty_transactions;
DROP TABLE IF EXISTS sbp_customer_loyalty;
DROP TABLE IF EXISTS sbp_loyalty_config;

-- Drop columns
ALTER TABLE bills      DROP COLUMN IF EXISTS loyalty_redemption_amount;
ALTER TABLE bills      DROP COLUMN IF EXISTS loyalty_points_redeemed;
ALTER TABLE bills      DROP COLUMN IF EXISTS loyalty_points_earned;
ALTER TABLE customers  DROP COLUMN IF EXISTS dob;
```

If a daily cron was scheduled:
```sql
SELECT cron.unschedule('loyalty-expire-daily');
```
