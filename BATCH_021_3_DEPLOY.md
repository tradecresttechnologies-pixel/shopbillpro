# BATCH 021.3 — Data Integrity Hotfix

**Date:** 8 May 2026
**Type:** Migration + 1 file patch
**Severity:** **CRITICAL** — fixes silent data loss on hotel bill saves

---

## What was wrong (3 connected bugs)

### Bug A — Hotel bill items vanished on save (CRITICAL)
- Bill GG-0076 saved as PAID with totals (₹3,700 subtotal, ₹4,461 grand) but **zero line items** in `bill_items` table
- Same bill in DRAFT preview showed all 3 items correctly (Room, dinner, wine)
- **Root cause:** Migration `020_universal_item_picker.sql` (Batch 019) was never deployed to your DB. My billing.html INSERT references columns `kind`, `product_id`, `service_id`, `room_type_id`, `unit`, `qty_unit_label` — if those columns don't exist in `bill_items`, the INSERT fails. The master `bills` row saves first; the `bill_items` insert errors silently because the code didn't catch errors.

### Bug B — Hotel guests not appearing in customer list
- New walk-in guests (Suraj, KARAN, viraj) checked out from bookings but never appeared in Customer Book
- **Root cause:** `sbp_bookings_create` stored `customer_name` on the booking row but never INSERTed into the `customers` table. The customer list reads from `customers`.

### Bug C — Customer history page empty
- Jyoti's customer-history page showed "No activity yet" / "Showing basic info — activity history unavailable"
- **Root cause:** Likely cascades from Bug A. The `sbp_get_customer_timeline` RPC probably joins `bills` with `bill_items`. With items missing, hotel bills filter out.

---

## What this batch does — 4 fixes, all idempotent

### Fix 1 — Add missing `bill_items` columns
Migration ensures all 7 columns from Batch 019 exist (`kind`, `product_id`, `service_id`, `room_type_id`, `booking_id`, `unit`, `qty_unit_label`). If they exist, no-op. If not, adds them with safe defaults.

### Fix 2 — Customer auto-create on booking
- New helper RPC `sbp_resolve_customer_for_booking()` looks up customer by phone (or name fallback), or creates new
- `sbp_bookings_create` rewritten to call this — every new booking now resolves or creates a `customers` row and links `customer_id`
- Backfill loop runs once: walks all existing bookings with NULL `customer_id` and links them to existing/new customer records

### Fix 3 — Salvage orphan hotel bills (one-shot)
- New RPC `sbp_salvage_orphan_hotel_bills(shop_id)` scans every checked-out booking with `bill_id`
- For any whose linked bill has zero items, reconstructs them from `sbp_bookings.room_total` + `sbp_booking_extras` using the same GST math from migration 022
- After salvage: GG-0076 will have 3 rows (Room, dinner, wine), totals match
- **Fully idempotent** — only acts on bills with zero items, can run multiple times safely

### Fix 4 — Defensive billing.html (prevents future silent failures)
- Bill_items insert now wrapped in try-catch
- If a column-missing error occurs → automatic fallback to legacy schema (just item_name/qty/rate/etc) → bill items still save
- Visible toast message if anything goes wrong → no more silent data loss
- Console warnings tell you exactly what to fix

---

## Files

```
batch021_3/
├── BATCH_021_3_DEPLOY.md
├── db/migrations/
│   └── 023_hotel_v2_data_integrity.sql      ← run FIRST
└── billing.html                              ← patched (try-catch + fallback)
```

---

## Deploy steps (in order)

### Step 1 — Run migration 023 in Supabase SQL Editor

Paste `db/migrations/023_hotel_v2_data_integrity.sql` → Run.

You'll see `RAISE NOTICE` messages telling you what was added/backfilled:
```
NOTICE: Added column bill_items.kind
NOTICE: Added column bill_items.product_id
NOTICE: ... (or no notices if columns already exist)
NOTICE: Backfilled customer_id for 6 bookings
NOTICE: Backfilled customer_id for 2 bills
```

### Step 2 — Verify migration

```sql
-- Confirm bill_items has all needed columns
SELECT column_name FROM information_schema.columns
WHERE table_name = 'bill_items'
  AND column_name IN ('kind','product_id','service_id','room_type_id','booking_id','unit','qty_unit_label');
-- Expected: 7 rows
```

### Step 3 — Run salvage for existing broken hotel bills

```sql
SELECT public.sbp_salvage_orphan_hotel_bills(
  (SELECT id FROM shops WHERE shop_type IN ('hotel','resort','guesthouse','service_apartment','boutique_hotel','hostel','day_room') LIMIT 1)::uuid
);
```

Expected output:
```json
{
  "ok": true,
  "total_checked_out_bookings": 6,
  "bills_salvaged": 6,
  "items_inserted": 9
}
```

(Numbers depend on your data — `bills_salvaged` = bills with zero items that just got fixed; `items_inserted` = total room+extra rows created.)

### Step 4 — Push billing.html

Push `billing.html` to repo. Vercel auto-deploys.

---

## Smoke tests

### Test 1 — verify GG-0076 now has items

```sql
SELECT item_name, qty, rate, gst_rate, line_total, gst_amount
FROM bill_items
WHERE bill_id = (SELECT id FROM bills WHERE invoice_no = 'GG-0076' LIMIT 1)
ORDER BY id;
```
Expected: 3 rows — Room (₹450 @ 0%), dinner (₹619.05 @ 5%), wine (₹2,031.25 @ 28%).

### Test 2 — open GG-0076 in the app
- Reload bills.html → tap GG-0076 → "Items not available" should now show all 3 lines
- Customer-history page for Jyoti might also start working (if RPC just needed bill_items present)

### Test 3 — new walk-in booking auto-creates customer
- Create a new booking with name "TestGuest" + phone "9999999999"
- Open Customer Book → "TestGuest" should appear immediately
- Existing customers (Suraj, KARAN, viraj) should ALSO have appeared after the backfill — check Customer Book

### Test 4 — defensive billing.html
- Generate a bill from any folio/booking
- Save → if anything goes wrong, you'll see a visible toast (no more silent failures)
- Check DevTools console for `[bill_items]` log lines

---

## What happens to existing bills

| Bill type | Before | After |
|---|---|---|
| GG-0076 (Jyoti hotel) | 0 items | 3 items (Room + dinner + wine), totals same |
| Pre-hotel bills (GG-0072, GG-0075, etc.) | OK | Untouched |
| Future hotel checkouts | Would fail silently | Now save correctly |
| Customers (Suraj, KARAN, viraj) | Not in list | Auto-created via backfill |

---

## What's NOT in this batch (deferred to next)

- **`sbp_get_customer_timeline` RPC fix** — the customer-history.html page might still show "No activity yet" even after this batch (depends on the RPC's logic). If it does, send me a screenshot and I'll diagnose the RPC separately.
- **Form C generator + walk-in fast-path + 4-column dashboard + hotel reports** — Batch 021B as planned, after this stabilizes.

---

## Acceptance criteria

✅ Migration runs without error
✅ `bill_items` table has all 7 new columns
✅ `sbp_salvage_orphan_hotel_bills` returns `ok: true` and salvages broken hotel bills
✅ GG-0076 now shows 3 items when opened
✅ New walk-in bookings create customer records
✅ Existing booking customers (Suraj, KARAN, viraj) appear in Customer Book after backfill
✅ Future bill_items insert failures show visible error (no more silent loss)

---

**Built by Claude · Batch 021.3 hotfix · 8 May 2026 · 3 critical bugs in one shot**
