# Hotfix 029a — Payment mode enum mismatch

**Your error:**
```
ERROR 23514: new row for relation "sbp_folio_payments"
violates check constraint "sbp_folio_payments_payment_mode_check"
DETAIL: Failing row contains (... ota_prepaid, 234567890, Auto-migrated from booking advance ...)
```

**Root cause:** Two enum schemas disagreed.

| Schema | Allowed values |
|---|---|
| `sbp_bookings.advance_payment_mode` (from mig 022) | cash, upi, card, bank_transfer, **ota_prepaid**, other |
| `sbp_folio_payments.payment_mode` (from mig 028, mine) | cash, upi, card, bank_transfer, **cheque**, other |

`ota_prepaid` (Online Travel Agency prepayment — Booking.com, MakeMyTrip,
Agoda) is a real, important mode for hotels. I should have included it in
the folio_payments enum from the start. When 029's backfill tried to copy
an `ota_prepaid` advance through unchanged, it hit the CHECK constraint.

**Fix:**

1. Expand `sbp_folio_payments.payment_mode` CHECK to also accept
   `ota_prepaid` — preserves the OTA distinction for reporting (you'll
   want to know "how much revenue came through OTAs vs walk-ins").
2. Re-run the backfill (idempotent — only inserts the rows missed before).
3. Update the `sbp_bill_settle_with_history` and `sbp_folio_payment_add`
   RPCs from 028/029 to accept and normalize `ota_prepaid`.
4. Update mode icon/label maps in `billing.html` and `folio.html` to
   render OTA payments correctly (🌐 OTA Prepaid).

## Files in this hotfix (3)

```
db/migrations/029a_payment_mode_enum_fix.sql   ← NEW
billing.html                                   ← drop-in replace
folio.html                                     ← drop-in replace
```

## Deploy

1. Supabase SQL Editor → run `029a_payment_mode_enum_fix.sql`.
   Idempotent. Drops + recreates the CHECK constraint with the
   expanded enum, re-runs the missing backfill, updates the 2 RPCs.

2. **Verify:**
   ```sql
   -- Should now equal the number of bookings with advance_amount > 0
   SELECT COUNT(*) FROM public.sbp_folio_payments
    WHERE note = 'Auto-migrated from booking advance';

   -- Should show ota_prepaid alongside other modes
   SELECT payment_mode, COUNT(*)
     FROM public.sbp_folio_payments
    WHERE note = 'Auto-migrated from booking advance'
    GROUP BY 1 ORDER BY 2 DESC;
   ```

3. GitHub Desktop → push the 2 HTML files + the SQL.

4. Hard-refresh PWA. End-to-end test continues from where 029 left off
   (see BATCH_022B_DEPLOY.md step 5).

## Why preserve `ota_prepaid` instead of mapping to `'other'`

Hotels need to know "how much of last quarter's revenue came via OTA
prepayments vs direct bookings." If we squash everything down to `other`,
the OTA channel commission analysis becomes impossible. Keeping
`ota_prepaid` as its own enum value means future hotel KPI reports
(021B-C) can break out OTA revenue cleanly.

If you ever want to drop the distinction, it's a one-line SQL update
later, but you can never recover lost distinctions retrospectively.
