# Batch 022B — Unified Payment Architecture

**Date:** 9 May 2026
**Closes:** the architectural gap you flagged where folio payments
silently vanished from bill settlement, and the settle modal
prefilled with the advance amount instead of balance due.

---

## The bug being fixed

Two parallel payment systems lived side by side:

| System | Where | What it tracked |
|---|---|---|
| **A** (legacy) | `bookings.advance_amount` + `advance_payment_mode` | A single number + a single mode |
| **B** (added in 028) | `sbp_folio_payments` ledger | Multi-row, mode-tagged, with refs + audit |

When checkout fired and a bill was generated, the bill flow only knew
about **A**. Consequences:

1. Any mid-stay payments recorded via folio.html "Record Payment" were
   silently lost — they never appeared on the bill.
2. The settle modal showed `paid_amount = advance_amount` which often
   left the operator confused: "I already collected ₹500 mid-stay, why
   does the bill say only ₹300 paid?"
3. The mode split was destroyed at settlement: ₹300 cash advance +
   ₹1,215 card final → bill recorded "₹1,515 in Card." The cash trace
   was lost.

This batch unifies them. The legacy `advance_amount` is now just
**one row** in `sbp_folio_payments` (auto-backfilled by the migration).
The bill settlement flow reads from the ledger, writes to the ledger.
One source of truth.

---

## What ships

### 1. `db/migrations/029_unified_payment_architecture.sql`

Three things:

**(a) Backfill** — for every booking with `advance_amount > 0` that has
no existing `is_advance=true` row in `sbp_folio_payments`, inserts one
preserving mode, reference, and timestamp. Idempotent — re-runs are safe.

**(b) New RPC `sbp_folio_payment_summary(shop_id, booking_id)`** — returns
```
{
  ok: true,
  total_paid: numeric,
  by_mode: [{ mode, amount, count }],
  rows:    [ ... full payment rows ... ]
}
```
billing.html calls this when `?booking_id=` is in URL to render the
"Already Received" panel.

**(c) New RPC `sbp_bill_settle_with_history(shop_id, bill_id, booking_id, amount, mode, ref?, note?)`** — atomically:
- Inserts the closing payment to `sbp_folio_payments` (mode-tagged)
- Recomputes the bill's `paid_amount` = SUM of all non-voided payments
- Computes `balance_due` and `status` (Paid / Partial / Credit)
- Updates `bills` row
- Sets `bookings.bill_id` if missing
- Returns the new bill totals

### 2. `billing.html` — additive 022B block

Pure additive — appended right before `</body>`. Only fires when the URL
has `?booking_id=` (hotel checkout flow). Existing non-hotel flow is
**100% untouched**.

What it does:

1. **Fetches payment summary** for the booking on page load
2. **Wraps `previewAndSave`** so when the bill-preview modal opens:
   - Injects an "**✓ Already Received ₹X**" panel at the top of the
     Settlement section showing per-mode chips:
     `💵 Cash ₹300 · 📱 UPI ₹500 · 💳 Card ₹200`
     Plus a collapsible `<details>` with row-by-row breakdown
     (advance/voided badges, timestamps, references)
   - Auto-switches to **Partial** mode (since there's prior history)
   - Pre-fills `partial-amt` with **balance due** (Total − Already Paid),
     not zero, not advance
   - Replaces the settle-note with a clean 3-line summary:
     ```
     Total bill           ₹1,515
     − Already paid       −₹300
     Balance due now      ₹1,215     (red if owed, green ✓ Clear if not)
     ```
3. **Wraps `confirmSettle`** to chain the new RPC AFTER the existing
   save logic completes. The original bill flow still creates the bill
   row; we just call `sbp_bill_settle_with_history` afterward to write
   the closing payment to the ledger and recompute totals from the
   unified ledger.

If `_sb` or `previewAndSave` aren't ready when the page boots, the block
polls for 5s then aborts gracefully (no error, just no enhancement).
This means if anything goes wrong, the existing flow still works —
graceful degradation.

---

## Files in this batch (2)

```
db/migrations/029_unified_payment_architecture.sql   ← NEW
billing.html                                         ← additive 022B block appended
```

No other files touched. No SQL schemas changed (only INSERTs + new RPCs).

---

## Deploy order

### 1. SQL — Supabase SQL Editor
Run `029_unified_payment_architecture.sql`. Idempotent. Backfills legacy
advances, creates 2 RPCs.

### 2. Verify backfill
```sql
-- How many advance rows got migrated?
SELECT COUNT(*) FROM public.sbp_folio_payments
 WHERE note = 'Auto-migrated from booking advance';

-- For Glitz & Glam, see the unified ledger for the most recent booking:
SELECT public.sbp_folio_payment_summary(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
  (SELECT id FROM public.sbp_bookings ORDER BY created_at DESC LIMIT 1)
);
```

### 3. Frontend deploy
GitHub Desktop → push `billing.html` + `db/migrations/029_*.sql`.

### 4. Bump SW (e.g. v1.5.16 → v1.5.17)

### 5. End-to-end test
1. Open Folio → pick an in-house guest with an advance already paid
2. (Optional) Record an additional partial payment in folio.html — say ₹500 via UPI
3. Click "✓ Check Out & Generate Bill" → lands on bookings.html → checkout fires → redirects to billing.html?booking_id=...
4. Click "Preview & Save" → modal opens
5. **You should see**:
   - "✓ Already Received ₹800" panel at top of Settlement
   - Per-mode chips: `💵 Cash ₹300 · 📱 UPI ₹500`
   - Partial pre-selected, amount field showing balance (e.g., ₹715 if grand is ₹1,515)
   - Settle note shows `Total ₹1,515 / − Paid ₹800 / Balance ₹715`
6. Pick a mode (e.g., Card) → click Confirm & Save
7. Open Folio for that guest again → Payments tab should show **3 rows**:
   advance (₹300 cash), partial (₹500 UPI), settlement (₹715 card). Each with timestamps + modes preserved.

---

## Why this approach (additive wrapping vs. rewriting confirmSettle)

I wrapped instead of rewrote because billing.html's existing
`confirmSettle` is touched by many flows (POS, manual bill, edit-mode,
voucher discounts). Rewriting it would risk breaking those. The 022B
block runs AFTER the original, calling the new RPC as a post-hook.
If the new RPC fails for any reason, the bill still saves via the
existing flow — just without the unified ledger update. Graceful.

A future batch (when there's appetite) can fold the RPC call into
confirmSettle directly and retire the wrapping pattern.

---

## Known limits

- **Settled offline:** When operator is offline, `confirmSettle` writes
  the bill to localStorage and queues for sync. The 022B post-hook
  needs network — when offline, the unified ledger update is skipped
  for that bill. On reconnect, the existing bill sync runs; we don't
  retry the ledger hook. Mitigation: the `sbp_folio_payments.is_advance=false` rows
  for offline-created bills will need manual entry, OR (in a future
  batch) a sync-time hook in `conversion.js` that retroactively writes
  them.
- **Bill voiding** isn't yet wired to void the matching folio payment
  rows. If a bill is voided, the closing payment in the ledger stays.
  Defer to 022C.

---

## Rollback

```sql
-- Remove backfilled advance rows
DELETE FROM public.sbp_folio_payments
 WHERE note = 'Auto-migrated from booking advance';

-- Drop the new RPCs
DROP FUNCTION public.sbp_folio_payment_summary(uuid, uuid);
DROP FUNCTION public.sbp_bill_settle_with_history(uuid, uuid, uuid, numeric, text, text, text);
```

Frontend: revert billing.html via GitHub Desktop.

— TradeCrest Technologies Pvt. Ltd. · CIN U62099UP2026PTC247501
