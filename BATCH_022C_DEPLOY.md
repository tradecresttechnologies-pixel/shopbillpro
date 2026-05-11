# Batch 022C — Silent Bill Generation

**Date:** 11 May 2026
**Closes:** the awkward "Check Out & Generate Bill" two-screen flow.
The folio is now the source of truth + the only UI surface; bills are
created silently in the background.

---

## The shift

| Before | After |
|---|---|
| Folio settled → operator clicks **Check Out & Generate Bill** → redirect to billing.html → bill form pre-populated → click **Preview & Save** → bill saved. **Two screens, two confirmations.** | Folio settled → operator clicks **Check Out & Finalize** → server-side RPC creates the bill atomically → folio refreshes with invoice number badge + locked line items + **View Invoice** button. **One screen, one click.** |

The bills + bill_items rows still get created so Reports / GST Report
/ customer history / GSTR-1 exports keep working identically. Only the
UX path changes.

---

## What ships

### 1. `db/migrations/030_folio_finalize_to_bill.sql`

One new RPC: **`sbp_folio_finalize_to_bill(shop_id, booking_id)`** that
does everything atomically in a single transaction:

1. **Idempotent check** — if `booking.bill_id` is already set, returns
   the existing bill info. Operator can re-click safely without duplicates.
2. **Computes room line + GST slab** (post Sep 2025 reform: ≤₹1,000=0%,
   ≤₹7,500=5%, >₹7,500=18%)
3. **Sums extras** with per-line GST from `sbp_booking_extras`
4. **Reserves invoice number** via existing `next_invoice_no` RPC
5. **Inserts `bills` row** with booking_id link, customer linkage,
   `bill_mode='hotel_checkout'`, payment_mode = most-recent payment mode
   (pretty-printed: Cash/UPI/Card/Bank/OTA), `paid_amount` = SUM of
   non-voided `sbp_folio_payments`, `balance_due` + `status` computed
6. **Inserts `bill_items` rows** — room line + GST split + each extra
   with proper `kind` (room/service/product)
7. **Updates booking** — `status='checked_out'`, `checked_out_at=now()`,
   `bill_id=<new id>`
8. **Frees the room** — `sbp_rooms.status` from `occupied` → `vacant`
   (best-effort, won't fail finalize)

Returns: `{ ok, already_done, bill_id, invoice_no, grand_total, paid_amount, balance_due, status, line_count, room_freed }`

Errors: `not_owner`, `booking_not_found`, `no_line_items`, `invoice_no_failed`

### 2. `folio.html` — updated flow

**Renamed CTA:** "✓ Check Out & Generate Bill" → "✓ Check Out & Finalize"

**New `checkOutAndBill()` function** — calls the RPC instead of
redirecting. Shows balance-due confirmation dialog if any balance remains.
On success, refreshes the folio in-place.

**After finalize (booking.bill_id is set):**
- Topbar eyebrow shows invoice number (e.g. `FOLIO · #GG-0079`) instead
  of the booking short id
- Line items table delete buttons (`✕`) disappear
- Quick-add panel replaces tile grid with "🔒 Folio finalized — line
  items are locked. Record refund payments below if needed."
- Custom extra button + category tabs hidden
- "Check Out & Finalize" CTA hidden
- New **🧾 View Invoice** CTA appears (desktop + mobile sticky bar)
- Print + WhatsApp + Record Payment buttons stay active (refunds,
  corrections, communication still need to work post-finalize)

**Helper added:** `_isLocked()` returns `true` when `booking.bill_id`
is set. Used as a single gate across `renderLineItems`, `renderQuickAdd`,
and the new `applyLockedState()` step.

### 3. `bookings.html` — UNCHANGED

The legacy `?id=&action=checkout` deep-link path I added in 022A v2 is
still functional (admin can still use bookings.html's modal to edit a
booking and trigger the old billing.html flow if a manual correction is
needed). But it's no longer the primary route.

---

## Files in this batch (2)

```
db/migrations/030_folio_finalize_to_bill.sql   ← NEW
folio.html                                     ← drop-in replace
```

Net change: smaller surface area, less code paths. The whole hotel
checkout flow is now ~50 lines of folio.html JS calling one RPC.

---

## Deploy order

### 1. SQL — Supabase SQL Editor

Run `030_folio_finalize_to_bill.sql`. Idempotent. Just adds the new RPC.

### 2. Verify

```sql
-- Pick a recent in-house booking (must have status='checked_in' and bill_id IS NULL)
SELECT id, customer_name, status, bill_id
  FROM public.sbp_bookings
 WHERE shop_id = (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
   AND status = 'checked_in'
   AND bill_id IS NULL
 ORDER BY created_at DESC LIMIT 3;

-- Then call the RPC manually to confirm it works server-side:
SELECT public.sbp_folio_finalize_to_bill(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
  '<paste-booking-id-from-above>'::uuid
);
-- Expected: { ok: true, already_done: false, bill_id: '...', invoice_no: 'GG-0079', ... }

-- Call it AGAIN with the same booking id:
-- Expected: { ok: true, already_done: true, bill_id: '...', invoice_no: 'GG-0079', ... }
-- (Same bill_id, same invoice_no — idempotent.)

-- Verify the bill + items landed:
SELECT b.invoice_no, b.grand_total, b.paid_amount, b.balance_due, b.status,
       (SELECT COUNT(*) FROM bill_items WHERE bill_id = b.id) AS lines
  FROM public.bills b
 WHERE b.booking_id = '<booking-id>';

-- Verify room freed:
SELECT r.room_number, r.status FROM public.sbp_rooms r
  JOIN public.sbp_bookings b ON b.room_id = r.id WHERE b.id = '<booking-id>';
-- Expected: status = 'vacant'
```

If any of those don't behave correctly — STOP and roll back before
deploying the frontend. The frontend will work fine without the SQL
(graceful error toast), but you don't want operators clicking
Finalize and seeing errors.

### 3. Frontend deploy

GitHub Desktop → push `folio.html` + the SQL.

### 4. Bump SW (e.g. v1.5.17 → v1.5.18)

### 5. End-to-end test

1. Folio → pick an in-house guest with no bill yet
2. Note the CTA reads **"✓ Check Out & Finalize"** (not "Generate Bill")
3. Click it → toast "✓ Invoice GG-NNNN generated" → folio refreshes
4. Verify the new state:
   - Topbar eyebrow shows `FOLIO · #GG-NNNN` (the invoice number)
   - Status pill: SETTLED or SETTLED_BALANCE_DUE
   - Line items table: no `✕` delete buttons
   - Quick Add panel: "🔒 Folio finalized — line items are locked"
   - Custom extra button + category tabs hidden
   - Right column action bar: 🖨️ Print · 📱 WhatsApp · 🧾 **View Invoice**
   - Mobile sticky bar: 🖨️ · ＋ Pay · 🧾 Invoice →
   - + Record Payment still active at bottom of payments card
5. Click **🧾 View Invoice** → opens bills.html with the new invoice
6. Verify in bills.html that the invoice has the correct items + totals
7. Open Folio again for that guest → confirm idempotence: status stays
   the same, no duplicate bill, View Invoice still points to the same
   invoice
8. (Edge case) Try to click Finalize again — should show toast
   "✓ Already finalized · Invoice GG-NNNN" (no duplicate inserted)

---

## Design rationale

**Why a server RPC instead of client-side bill creation?**

Atomicity. The old flow was a client-orchestrated sequence: bookings.html
fetches folio → stashes in sessionStorage → redirects to billing.html →
billing.html reads the stash → builds form → operator clicks save →
inserts bill + items → links booking back. **Five separate transactions**
that could fail at any point and leave inconsistent state. The new flow
is one PL/pgSQL transaction — bill + items + booking update + room free
all commit together or all roll back. No orphan bills, no half-checked-out
bookings.

**Why keep the bookings.html modal alive?**

Risk reduction. Operators are trained on it. The Finalize path is opt-in
via folio.html. If any vertical needs the old flow (manual corrections,
edit-bill, retail-style POS checkout from a booking), the modal still
works. Future batches can retire it once Finalize has shipped to
production users and we've seen real-world usage.

**Why "Finalize" not "Generate Bill"?**

"Generate Bill" implies a separate document being created — a heavyweight
operation. The reality is the folio already has every number the bill
needs. "Finalize" matches what's actually happening: locking the folio
in its current state and assigning an invoice number.

---

## Known limits (deferred)

- **Editing a finalized folio** — currently no in-UI path. To correct a
  charge after finalization, admin would void the bill (separate batch),
  unlink it from the booking, edit folio, re-finalize. Real-world
  workaround: post-finalize edits via Reports → Bills → Edit.
- **Bill voiding doesn't unlink the booking** — voiding a bill doesn't
  reset `booking.bill_id` or set the folio back to editable. Defer to
  a future batch.
- **Offline finalize** — the RPC needs network. If offline when finalize
  is clicked, the error toast fires gracefully and operator can retry
  once online.

---

## Rollback

```sql
DROP FUNCTION public.sbp_folio_finalize_to_bill(uuid, uuid);
```

Frontend: revert `folio.html` via GitHub Desktop. The old CTA was a
redirect to bookings.html — if that's restored, the legacy flow works
again since I didn't touch bookings.html or billing.html in this batch.

— TradeCrest Technologies Pvt. Ltd. · CIN U62099UP2026PTC247501
