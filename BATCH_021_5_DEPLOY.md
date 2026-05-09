# Batch 021.5 — Bills + Customer Linkage Integrity

**Date:** 9 May 2026
**Scope:** 3 frontend files + 1 SQL migration. 6 root causes closed.

---

## What this batch fixes

### Bug 1 — Customer→Bill view shows ₹0 + missing kind badges
**Root cause (file:line):**
- `customers.html:1734` selected only `bill_items(item_name)`, stripping `qty`, `rate`, `gst_rate`, `line_total`, `gst_amount`, `kind`, `product_id`, `service_id`, `room_type_id`, `booking_id`, `unit`, `qty_unit_label`. Result was overwritten back into `localStorage.sbp_bills` — cache poisoned.
- `bills.html:1458` had partial column list (rate/qty present but `kind` absent), so even after refresh the kind badges never rendered.

**Fix:** both queries now use `bill_items(*)`.

### Bug 2 — Invoice number collisions (e.g. GG-0076 assigned twice)
**Root cause confirmed via DevTools:**
- `next_invoice_no` RPC returned **HTTP 400** with PG error code **42702 (ambiguous_column)**, message `column reference "invoice_..."`.
- The OUT-param names `invoice_prefix` / `invoice_counter` declared in `RETURNS TABLE(...)` collided with column names of `shops` table inside the function body.
- Client at `billing.html:2961-2969` silent-caught the error → fell back to stale `_shop.invoice_counter` from localStorage → every save reused the same stale number.

**Fix (in order of authority):**
1. **Migration 025 fixes the RPC** — rewrites function body to use only local variables; projects them via `RETURN QUERY SELECT`. Preserves API contract; no client change.
2. **billing.html now logs RPC errors** explicitly via `console.error` — no more silent failures.
3. **At-save reservation guard** — if the form-open RPC didn't reserve a number (e.g. failed transiently), confirmSettle retries the RPC. If still failing **AND online**, save is blocked with a toast. Offline mode keeps the device-tagged fallback (safe by design).
4. Dropped the redundant `_sb.from('shops').select('*')` re-fetch at billing.html:3006-3010 that overwrote the reserved number.

### Bug 3 — Guest history shows 0 bills / ₹0 spent
**Root cause (file:line):**
- `billing.html:1575-1586` `billData` payload omitted `customer_id`. Every bill ever inserted had `customer_id = NULL`.
- `sbp_get_customer_timeline` filtered strictly via `b.customer_id = p_customer_id` → zero matches forever. (Migration 017/018 added partial fallbacks but missed name normalization edge cases.)

**Fix (3 layers):**
1. **billing.html resolves customer_id at save** — calls existing `sbp_resolve_customer_for_booking` RPC (from migration 024), includes resolved id in `billData`. Same fix applied to POS-mode save in `confirmPOSCheckout`. Best-effort, non-fatal.
2. **Migration 025 adds backfill RPC** `sbp_backfill_bills_customer_id(shop_id)` — walks all bills with NULL customer_id and resolves via name + normalized phone. Runs automatically for all shops at end of migration.
3. **Migration 025 patches sbp_get_customer_timeline** with a robust 3-way fallback: `customer_id` OR lower(trim(name)) OR normalized phone (via `sbp_normalize_phone` from 024). Defensive net so any future bill insertion missing customer_id still surfaces in the timeline.

### Bug 4 — Booking → Bill back-link missing
**Root cause:**
- The polling-based linkBill at `billing.html:4180-4214` is fragile: relies on 1.5s setInterval, kills if user closes tab, and clears `_currentBookingId` after first detected bill (could link wrong bill).

**Fix:**
- `billing.html` now calls `SBPHotel.bookings.linkBill` **directly from the save-success block** with the just-inserted bill id and the URL `booking_id`. Synchronous, deterministic, idempotent. The polling stays as a fallback for edge cases but `_currentBookingId` is cleared on direct success so polling won't double-link.

### Bug 5 — Salvage RPC can't recover bookings missing bill_id
**Root cause:**
- `sbp_salvage_orphan_hotel_bills` (in migration 023) iterated only `WHERE bookings.bill_id IS NOT NULL`. Bookings without the link were skipped entirely — items couldn't be reconstructed.

**Fix in migration 025:**
- New `sbp_link_orphan_hotel_bills(shop_id)` runs a fuzzy-link first pass: for checked-out bookings with `bill_id IS NULL`, matches against bills by `customer_name + grand_total ± ₹1 + check_out_date ± 1 day`. If exactly one bill matches → writes `bill_id` back to the booking. Ambiguous (multi-match) and no-match cases are logged and skipped.
- Patched `sbp_salvage_orphan_hotel_bills` calls the link pass first, then runs existing salvage logic. Auto-runs at end of migration for all hospitality shops.

### Bug 6 — Advance payment never adjusted in checkout
**Root cause (file:line):**
- `billing.html:3206-3287` `_sbpPopulateFolio` reads room + extras from the folio but completely ignored `b.advance_amount`. Booking RPC returns it correctly (`022_hotel_v2_phase1.sql:577`), but billing.html dropped it.
- Result: guest paid advance at booking → checkout bill shows full grand_total → settle modal asks for full amount → advance lost in accounting.

**Fix:**
- `_sbpPopulateFolio` now reads `b.advance_amount`, stashes on `window._currentBookingAdvance` with mode/date, and renders a green banner under the checkout banner: *"💰 Advance ₹X already received via {mode} on {date}"*.
- `previewBill` (settle modal opener) reads the stashed advance: switches `_settleType='partial'`, pre-fills `partial-amt` with the advance value, and updates the settle note: *"Advance ₹500 already received (Cash). Balance ₹1070 due. Bump amount up if collecting balance now."*
- Bill grand_total stays full (correct for GST tax invoice). `paid_amount` reflects what's actually been collected at this point. If user is also collecting the balance now, they bump partial-amt up to grand_total before saving.

---

## Files in this batch (4)

```
db/migrations/025_bills_integrity.sql   ← NEW
billing.html                            ← edited (~7 blocks)
bills.html                              ← edited (1 line)
customers.html                          ← edited (1 line)
```

---

## Deploy order

### 1. SQL — Supabase SQL Editor
Run `025_bills_integrity.sql`. Idempotent. The `DO $$ ... $$` block at the end auto-runs:
- `sbp_backfill_bills_customer_id` for **every shop** (resolves NULL customer_ids).
- `sbp_link_orphan_hotel_bills` + `sbp_salvage_orphan_hotel_bills` for hospitality shops only.

Watch the `RAISE NOTICE` output to see how many bills got resolved / linked / salvaged for Glitz & Glam.

### 2. Verify the RPC is fixed
```sql
SELECT * FROM public.next_invoice_no(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
);
```
Expected: one row with the next invoice number (e.g. `('GG', 77)`). No 42702 error.

### 3. Verify backfill ran
```sql
SELECT COUNT(*) AS still_null
  FROM public.bills
 WHERE shop_id = (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
   AND customer_id IS NULL;
```
Expected: 0 (or only bills with empty `customer_name`, which can't be resolved).

### 4. Verify Jyoti's timeline now populated
```sql
SELECT public.sbp_get_customer_timeline(
  (SELECT id FROM public.customers
    WHERE lower(trim(name))='jyoti'
      AND shop_id=(SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
    LIMIT 1)
);
```
Expected: `stats.total_bills > 0`, `stats.total_spent > 0`.

### 5. Frontend deploy
GitHub Desktop → commit `billing.html`, `bills.html`, `customers.html` → push → Vercel auto-deploys.

### 6. Hard-refresh the PWA on the test device
Service-worker may cache the old `billing.html`. Force refresh (or bump SW version if needed) to pick up the new file.

### 7. End-to-end test
1. Create a fresh hotel booking for Jyoti with an advance (e.g. ₹500).
2. Check her in.
3. Add a folio extra (e.g. dinner ₹500).
4. Click **Check Out** in `bookings.html`.
5. Verify in `billing.html`:
   - Green advance banner appears under checkout banner.
   - DevTools console shows `[next_invoice_no] reserved GG-NNNN at form-open` (next number after current max — should be **GG-0077** if last was GG-0076).
   - Click **Preview & Save Bill**: settle modal opens in **Partial** mode, partial-amt pre-filled with `500`, settle note shows balance due.
6. Bump partial-amt up to grand total and click **Confirm & Save**.
7. DevTools console shows: `[customer_id] resolved <uuid> for Jyoti` and `[BookingCheckout] direct-linked bill <bill-id> → booking <booking-id>`.
8. Open Jyoti's **Customer History** page: stats card now shows total_bills ≥ 1, total_spent > 0, last visit timestamp. **No more "No activity yet."**
9. Open the bill from **Customers → Jyoti → tap GG-0077**: rates, amounts, kind badges all render correctly (no ₹0).
10. Open the same bill from **Bills & Settlement → tap GG-0077**: same render — kind badges show.

### 8. (Optional) Re-run the salvage if there are still orphan hotel bills
```sql
SELECT public.sbp_salvage_orphan_hotel_bills(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
);
```
Expected on a clean repo: `bills_salvaged: 0` (everything already linked).

---

## Rollback

If anything blows up:
- **SQL:** all RPCs are `CREATE OR REPLACE` — re-run prior migration files (013, 015, 023) in order to restore the older RPC bodies. The new RPCs (`sbp_backfill_bills_customer_id`, `sbp_link_orphan_hotel_bills`) can be left in place; they're additive.
- **Frontend:** GitHub Desktop → revert the commit → push.
- **Data side-effects:** the auto-run only WROTE `bills.customer_id` (was NULL → resolved UUID) and `sbp_bookings.bill_id` (was NULL → resolved bill UUID). To undo:
  ```sql
  -- Roll back bills.customer_id backfill (only if you must)
  UPDATE public.bills SET customer_id = NULL
   WHERE shop_id = '<shop-uuid>' AND customer_id IS NOT NULL;
  -- Roll back booking link
  UPDATE public.sbp_bookings SET bill_id = NULL
   WHERE shop_id = '<shop-uuid>' AND status = 'checked_out';
  ```
  But you almost certainly don't want to do this — these are correct linkages.

---

## Known gaps deferred to 021.6 / later

- **WhatsApp message rendering** (the `�` emoji-mangling in your Image 8 share). Separate fix for `sendBillWA` message template encoding.
- **Bill PDF "Less: Advance" line** — currently advance is reflected in `paid_amount` but not visible as a deduction line on the printed bill. Refinement for buildBillHTML.
- **Architectural refactor of invoice numbering to at-save-only** (drops the form-open reservation entirely so cancellations don't waste numbers). Larger refactor; not blocking.
- **POS-mode invoice reservation guard** — only customer_id resolution was added to confirmPOSCheckout. The at-save invoice guard wasn't added because POS uses the form-open RPC value (already covered by migration 025 fix).

---

## What changed in code (summary)

| File | Lines changed | What |
|---|---|---|
| `db/migrations/025_bills_integrity.sql` | new file | 6 RPCs (3 new, 3 patched) + auto-run block |
| `billing.html` | ~7 edit blocks | RPC error logging, at-save reservation guard, customer_id resolution (×2), direct linkBill, advance banner + pre-fill, drop redundant re-fetch |
| `bills.html` | 1 line (1458) | `bill_items(*)` |
| `customers.html` | 1 line (1734) | `bill_items(*)` |

— TradeCrest Technologies Pvt. Ltd. · CIN U62099UP2026PTC247501
