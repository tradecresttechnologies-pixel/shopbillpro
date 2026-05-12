# 037 Hotfix — `row_to_jsonb` → `to_jsonb` + KPI data sanity check

## Issue 1 — Daily Ops + DMR broken (CRITICAL, must fix)

**Symptom:**
- Daily Ops tab: red toast `Arrivals/Departures error: function row_to_jsonb(record) does not exist`
- DMR tab: red toast `A/D fail: function row_to_jsonb(record) does not exist`

**Root cause:** Migration 036 used `row_to_jsonb(alias)` to convert subquery rows
into JSON. This Supabase setup doesn't expose that function. The codebase
standardized on `to_jsonb()` long ago (22 call sites in other migrations,
0 of `row_to_jsonb`). My oversight — should have grepped first.

**Fix:** Migration 037 replaces both broken RPCs (`sbp_hotel_arrivals_departures`
and `sbp_hotel_in_house`) with `to_jsonb()` versions. Logic is identical
otherwise. `sbp_hotel_kpis` is untouched (it didn't use `row_to_jsonb`,
which is why the Performance tab works).

**Deploy:** Just run migration 037 in Supabase SQL Editor. No HTML changes.

(I've also patched 036 in place — if you re-run it from scratch in future,
it'll be correct. But running 037 against an already-deployed 036 is what
fixes the live database now.)

---

## Issue 2 — Occupancy 150% (NOT a code bug — data sanity issue)

**What you see:** Performance tab with "Today" preset:
- Occupancy: 150.0% (with "3 of 2 room-nights" subtitle)
- Total rooms: 1
- Available room-nights: 2 (1 room × 2 days = correct)
- Room-nights sold: 3 (← impossible with 1 room over 2 days)

**Math is correct, data has overlap.** With only 1 room, you cannot
legitimately sell 3 room-nights in 2 days. The query is summing nights
from multiple bookings that have overlapping `[check_in, check_out)` ranges
for the **same physical room** (or unassigned rooms).

This is normal in a test shop where you've created multiple test bookings
without strict availability gating. In production, the booking workflow
prevents this (you can't check a second guest into the same occupied room).

### Diagnostic query

Run this in Supabase SQL Editor to find overlapping bookings:

```sql
-- Find bookings with overlapping [check_in, check_out) windows
-- in Glitz & Glam (replace shop_id for other shops)
WITH b AS (
  SELECT id, customer_name, room_id, room_number_snapshot,
         check_in_date, check_out_date, status, rate_per_night
    FROM sbp_bookings
   WHERE shop_id = '73aa8ede-6352-4549-8617-cccacdd5c821'
     AND status IN ('checked_in', 'checked_out')
)
SELECT
  b1.id            AS booking_1,
  b1.customer_name AS guest_1,
  b1.check_in_date AS in_1, b1.check_out_date AS out_1,
  b1.room_id       AS room_1,
  b2.id            AS booking_2,
  b2.customer_name AS guest_2,
  b2.check_in_date AS in_2, b2.check_out_date AS out_2,
  b2.room_id       AS room_2
FROM b b1
JOIN b b2
  ON b1.id < b2.id
 AND b1.check_in_date  < b2.check_out_date
 AND b1.check_out_date > b2.check_in_date
ORDER BY b1.check_in_date;
```

If this returns rows, those are the bookings overlapping. To fix the test
data, you can:
- Cancel one of the overlapping bookings: `UPDATE sbp_bookings SET status='cancelled', cancelled_at=now() WHERE id='<booking_id>';`
- Or change check-in/check-out dates so they don't overlap

### Should I cap occupancy at 100%?

**No.** Capping it would hide data integrity issues. If a real hotel ever
sees >100% occupancy, that's a bug they need to know about (double-booking,
status not updated, etc.). Showing 150% with raw counts is the right
behavior — the formula is correct, the data is wrong.

---

## Recommended deploy order

1. **Run migration 037** in Supabase SQL Editor. Verify with:
   ```sql
   SELECT proname FROM pg_proc
   WHERE proname IN ('sbp_hotel_arrivals_departures', 'sbp_hotel_in_house');
   ```
   Both should appear.

2. **Hard-refresh** the app — Daily Ops + DMR should now load instead of
   showing the error toast.

3. **(Optional)** Run the overlap diagnostic above. Clean up test data if
   you want the Performance tab to show realistic numbers.

4. **Smoke test:**
   - Daily Ops → Arrivals: should show ~3 rows
   - Daily Ops → Departures: should show ~4 rows
   - Daily Ops → In-house: should show currently checked-in guests
   - DMR: A4 sheet renders with all sections; Print produces clean output

---

## Lesson learned (for next time)

Before writing any new SQL with composite-type conversions, grep the
existing migrations for established patterns:

```bash
grep -rh "to_jsonb\|row_to_jsonb" db/migrations/*.sql | sort | uniq -c
```

If `to_jsonb` has 22 hits and `row_to_jsonb` has 0, that's a clear
codebase convention. I missed that signal — won't happen again.

This is the same pattern the codebase already caught in Batch 012 BugFix
(per project memory). Should have re-checked before writing 036.
