# Hotfix 030e — One number across folio, bill, and picker

**Your complaint (verbatim):** "same bill, same folio, same guest with
same stay but too much contradiction .. all each pages showing different
different outstanding"

Three views, three numbers in your screenshot:
- **Folio:** ₹1,649 grand total, ✓ Clear balance (correct — what guest actually paid)
- **Bill:** ₹1,667 grand total, ₹518 balance due (₹18 phantom GST drift + missed ₹500 advance)
- **Picker:** ₹100 balance (used room rate minus legacy advance, ignored everything else)

## Root cause

**Operator-entered amount semantics were inconsistent across the stack.**

When operator types "Lunch (per person) ₹250" via folio quick-add:
- The folio **displays** ₹250 (treats as gross, what guest pays)
- The trigger **stores** it with `gst_inclusive=FALSE` (treats as pre-GST)
- My old finalize **read** taxable_amount=₹250 and **added** GST on top → ₹262.50 on bill
- The picker **computed** balance using `booking.grand_total` (room only at booking time) minus `advance_amount` (legacy single value) — knew nothing about extras or later payments

Result: every view used a different definition of "the total."

## Fix — one canonical truth

**Rule from now on:** `e.amount` (the operator-entered amount) is the
gross/inclusive figure. Everything else back-computes from there.

| Place | Before | After |
|---|---|---|
| Folio extras subtotal | SUM(e.amount) as gross | SAME (was already right) |
| Bill grand_total | recomputed with GST on top → drifted ₹18 higher | back-computed taxable, totals **exactly** match folio |
| Bill paid_amount | only counted real folio_payments rows → missed ₹500 legacy advance | now also backfills legacy advance into folio_payments at finalize time |
| Picker / bookings modal | booking.grand_total − advance_amount | uses new `live_grand_total` / `live_balance_due` from the RPC, which mirror folio+bill |

## What ships

**1. Migration `030e_unify_totals_across_views.sql`**
- Replaces `sbp_folio_finalize_to_bill` — back-computes taxable + GST from gross
- Replaces `sbp_bookings_list` — adds three new fields per row:
  - `live_grand_total`
  - `live_paid_amount`
  - `live_balance_due`
- These pull from the bill (when finalized) or live-compute from extras+folio_payments (when not yet billed), so the picker number always matches the folio number.

**2. `folio.html`** — picker reads `b.live_balance_due` (with legacy fallback for older RPCs)

**3. `bookings.html`** — booking detail modal reads `b.live_grand_total` / `b.live_balance_due` (with legacy fallback)

## Deploy

1. Supabase SQL Editor → run `030e_unify_totals_across_views.sql`
2. Push folio.html + bookings.html
3. Hard-refresh PWA

## End-to-end verification

After deploy, the booking in your screenshot (Vinay · Room 101) should show:

| View | Grand | Paid | Balance |
|---|---|---|---|
| Folio | ₹1,649 | ₹1,649 | ✓ Clear |
| Bill | ₹1,649 | ₹1,649 | ₹0 |
| Picker | ₹1,649 | — | ✓ Clear |

(For NEW bills going forward. Existing finalized bills won't auto-recompute
— the bill snapshot is what it was at finalize time. If you want to fix the
already-generated buggy bill from your screenshot, you'd need to delete that
bill and re-finalize the folio. Tell me if you want a one-time corrective
SQL for that specific case.)

## Honest meta

This is the 5th iteration. The pattern: I was guessing at semantics,
not just column names. Three real schema issues (gst_amount column,
next_invoice_no return shape, bills.booking_id) were fixable. This one
required understanding the **data model intent**, which required reading
the trigger that computes GST + tracing through how each surface
interprets `e.amount`. That investigation took 10 minutes and would have
prevented hotfixes 030a through 030d entirely. Lesson permanently
absorbed.
