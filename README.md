# ShopBill Pro — v7.1 Per-Split Confirm Flow

**Bundle:** `ShopBillPro_v7.1_per_split_confirm.zip`
**Date:** 2026-05-23
**Supersedes:** v7.0.1 (mig 103) — adds per-split metadata and Credit support.

---

## What this ships

After a cashier picks Equal / Custom / By-Item + N, they now step through
N **Sequential per-split confirm screens** (Split 1 of N → fill →
Next → … → Confirm All), each carrying its own:

- **Customer name** (optional)
- **Customer phone** (optional)
- **Payment mode** — Cash / UPI / Card / Credit

Split 1 prefills name/phone from the running order's attached customer
(if any). Subsequent splits default to Walk-in + Cash.

**Credit splits:** status = `'Credit'`, paid_amount = 0,
balance_due = grand_total. A Credit split **must** have a customer
name — the Next button is disabled until one is entered, and the
RPC also rejects on server-side validation (`credit_requires_customer`).

If phone + name match the running order's customer (via
`sbp_normalize_phone`), the bill is linked to that customer_id. If
Credit + phone + name are supplied but don't match the RO customer,
`sbp_resolve_customer_for_booking` is called (exception-safe, mirrors
mig 076 pattern) so the balance is trackable. Walk-in cash splits
stay with `customer_id = NULL`.

---

## DEPLOY PATHS

| Action  | Path                                              | Notes                                            |
|---------|---------------------------------------------------|--------------------------------------------------|
| NEW     | `db/migrations/104_split_per_split_metadata.sql`  | **Run in Supabase SQL Editor**                   |
| REPLACE | `db/migrations/100_bill_split_merge.sql`          | **GitHub only** — source-of-truth, do not re-run |
| REPLACE | `running-order.html`                              | GitHub → Vercel auto-deploy (wait 2–10 min CDN)  |

---

## Deploy order (live DB)

1. **Open Supabase SQL Editor** → paste contents of
   `db/migrations/104_split_per_split_metadata.sql` → Run.
   Expect: success messages for `_sbp_split_normalize_pay`,
   `sbp_ro_split_equal`, `sbp_ro_split_custom`, `sbp_ro_split_by_item`,
   then `NOTIFY pgrst, 'reload schema';`.

2. **GitHub Desktop:**
   - Replace `running-order.html` (root)
   - Replace `db/migrations/100_bill_split_merge.sql` (source hygiene only)
   - Add `db/migrations/104_split_per_split_metadata.sql`
   - Commit + push.

3. **Wait** ~2–5 min for Vercel build + edge cache refresh.

4. **Hard-refresh** `app.shopbillpro.in/running-order.html` (Ctrl+Shift+R)
   and open a test running order.

---

## What changed in the source files

### `db/migrations/104_split_per_split_metadata.sql` (NEW, ~890 lines)

- `_sbp_split_normalize_pay(text)` — internal helper. Normalises
  any input to `'Cash' | 'UPI' | 'Card' | 'Credit'`, returns NULL
  for unknown values.

- `sbp_ro_split_equal(p_order_id, p_n_ways, p_splits jsonb DEFAULT NULL,
  p_payment_mode text DEFAULT 'Cash')` — adds optional `p_splits`
  array of `{customer_name, customer_phone, payment_mode}`. Length must
  equal `p_n_ways` when provided. Falls back to old behaviour when NULL.

- `sbp_ro_split_custom(p_order_id, p_amounts jsonb, p_payment_mode)` —
  `p_amounts` elements can now be either bare numbers (legacy callers)
  or objects `{amount, customer_name, customer_phone, payment_mode}`.
  Shape is detected via `jsonb_typeof(p_amounts->0)`.

- `sbp_ro_split_by_item(p_order_id, p_groups jsonb, p_payment_mode)` —
  group objects already had `{label, item_ids}`; now also read optional
  `customer_name`, `customer_phone`, `payment_mode`.

- Per-split validation: Credit requires customer name; unknown
  payment modes rejected. All return structured error envelopes:
  `{ok:false, error:'credit_requires_customer', split_index:N}`.

### `db/migrations/100_bill_split_merge.sql` (REPLACED, source hygiene)

The three split RPC bodies are now the v7.1 versions (identical to
mig 104) so cold-deploys land directly on v7.1 baseline. Mig 100
in the live DB has already been overwritten by mig 101 → 102 → 103
→ 104; the repo version is purely for fresh-clone scenarios.

### `running-order.html` (REPLACED)

- **v7a fix preserved**: `isBiz()`, `isBusiness()`, `isFree()` helpers
  inline in `<head>` (prevents `ReferenceError: isBiz is not defined`).
- **Stage-1 modal**: "Split Bill" button renamed to "Next →" and
  rewired to `goToConfirmStage()`.
- **Stage-2 modal** (NEW, `#split-confirm-modal`): progress dots,
  amount summary, per-split items preview (by-item mode only),
  name/phone inputs, 4-button payment picker (Cash/UPI/Card/Credit),
  inline Credit warning, Back/Next navigation.
- **JS state machine** (replaces old `doSplit()`):
  - `_splitFlow = { mode, n, splits[], idx }`
  - `goToConfirmStage()` — build splits[], compute per-split amounts,
    open Stage 2
  - `closeConfirmStage()` — cancel + clear state
  - `renderConfirmStage()` — paint current split
  - `setConfirmPay(mode)` — toggle pay button + live-validate
  - `onConfirmInputChange()` — live Credit-needs-name check
  - `navConfirm(direction)` — save inputs, move idx, commit on last
  - `commitSplit()` — build per-RPC payload, call RPC, handle errors
    (including `split_index` in error messages)

---

## Test plan (recommended)

### Test 1 — Equal split with mixed payment (cash + credit)
1. Open a running order with ₹1,142 total (or any).
2. Tap **Split** → Equal → 2 → **Next →**.
3. Split 1: name "Vinay", phone "9876543210", payment **Credit**.
4. Tap Next → Split 2: leave name blank, payment **Cash**.
5. Tap **✓ Confirm All**.

Expect:
- Bill 1: status `Credit`, customer_name `Vinay`, paid 0, balance ₹571.
- Bill 2: status `Paid`, customer_name NULL/Walk-in, paid ₹571, balance 0.
- Sum of grand_total = ₹1,142 (paise-exact).

### Test 2 — Credit guard
1. Same as above, but on Split 1 pick Credit + leave name blank.
2. Next button should be **disabled** with red Credit-needs-name warning.

### Test 3 — Custom split with UPI
1. Bill ₹500 → Custom → 2 people → ₹200 + ₹300 → **Next →**.
2. Split 1: payment **UPI**, name "Customer A".
3. Split 2: payment **Cash**, walk-in.
4. Confirm All.

Expect: Bill 1 payment_mode `UPI`, Bill 2 `Cash`. Both Paid.

### Test 4 — By-Item split (mixed)
1. Order with 4 items → By Item → 2 people.
2. Assign 2 items each → **Next →**.
3. Stage 2 shows items preview per split.
4. Confirm with different payment modes.

Expect: Per-item bill_items rows preserved on each bill. No
`bill_items.kind = 'split_share'` (that's only for equal/custom).

### Test 5 — Back navigation
1. Mid-flow, tap **← Back** on Split 2.
2. Edits in Split 2 should be preserved when re-visited.
3. Tap **Cancel** — flow closes, no bills created, RO still open.

### Test 6 — Customer reuse (RO customer)
1. Attach customer "Vinay / 9876543210" to RO via the existing
   "Add Customer" flow.
2. Start Split → Equal → 2 → Next.
3. Split 1 should auto-fill name + phone.
4. Confirm. Bill 1 should have `customer_id = <Vinay's id>`.

---

## Backward compatibility

- Old callers passing only `p_payment_mode` (no per-split metadata)
  still work — they fall back to walk-in defaults + the shared payment
  mode (same behaviour as v7.0.1).
- The Custom RPC accepts both bare-number arrays (legacy) and
  object-array (v7.1) shapes.

---

## Rollback

If something explodes, re-run mig 103 (v7.0.1 hotfix) to restore the
pre-v7.1 functions. Loses Credit + per-split payment, split itself
stays functional with walk-in + cash defaults. Re-deploy the
v7.0.1-era `running-order.html` if needed.

---

## Known follow-ups (v7.2+)

- Per-split discount support (currently all splits share 0 discount).
- "Skip" button on per-split screen for fast walk-in confirmation.
- Per-split print/WhatsApp from the success screen (currently
  redirects to tables.html).
- Customer lookup-autocomplete on Stage 2 name input (search existing
  customers by phone).
- Consolidate migrations 101/102/103/104 → fold all fixes into mig 100
  source-of-truth and delete the patch files.
