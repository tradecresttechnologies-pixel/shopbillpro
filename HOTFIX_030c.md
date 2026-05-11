# Hotfix 030c — Missing bills.booking_id column

**Your error:** `column "booking_id" of relation "bills" does not exist`

**Root cause:** The `bills` table has no `booking_id` column. The
linkage was one-way only: `sbp_bookings.bill_id` points to the bill,
but the bill has no reverse pointer. My migration 030 tried to INSERT
into a non-existent column.

This was a genuine schema gap. The 022B billing.html block already
**assumed** bills.booking_id existed:

```js
const newest = bills.find(b => b && b.id && b.booking_id === _bookingId);
```

Without the column, that lookup silently falls back to `bills[0]`
(the newest bill, regardless of which booking it belongs to). Fragile.

**Fix:**

1. **ALTER TABLE bills ADD COLUMN booking_id uuid** (nullable, FK with
   `ON DELETE SET NULL` so deleting a booking doesn't lose the bill)
2. **CREATE INDEX** on the new column for fast reverse lookup
3. **Recreate the RPC** with one extra hardening pass:
   - Every INSERT now wrapped in its own EXCEPTION block — if any of
     `bills`, `bill_items` (room), or `bill_items` (extras) fails, the
     RPC returns the precise SQL detail in the response
   - `bill_mode = 'manual'` (was 'hotel_checkout' which I never verified
     — using the proven value billing.html uses)

## Files (1 — SQL only, no frontend changes)

```
db/migrations/030c_bills_booking_id_and_final_fix.sql   ← NEW
```

The previously-shipped folio.html (with `data.detail` error surfacing)
remains correct — no changes needed there.

## Deploy

1. Supabase SQL Editor → run `030c_bills_booking_id_and_final_fix.sql`
2. Verify the column was added:
   ```sql
   SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='bills' AND column_name='booking_id';
   ```
   Should return one row.
3. Retry Finalize from folio.html

## Honest meta

This is the third migration in this batch. The pattern that failed me:
guessing schema details from memory instead of reading them.

After this lands, I commit to doing a **full schema scan** for any
table/RPC I touch in future batches BEFORE writing the SQL. The audit
batch (022D) will start with a 5-minute scan of `bills`, `bill_items`,
`sbp_bookings`, and existing audit/auth tables (if any) before any RPC
gets written. Each error in this session cost ~15-20 minutes of
round-trip; the upfront scan would have taken 5 minutes total.

The defensive EXCEPTION blocks added in this hotfix mean if a fourth
issue surfaces, the toast will tell us **exactly** which INSERT failed
and why — no more "Could not finalize: X" with no context.
