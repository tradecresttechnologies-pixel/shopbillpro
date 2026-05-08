# BATCH 021.4 — Customer Deduplication + Phone Normalization Fix

**Date:** 8 May 2026
**Type:** SQL-only hotfix
**Files:** 1 — `024_customer_dedup.sql`

---

## What was wrong

After Batch 021.3 backfill, you saw duplicate customers:
- `vinay` (lowercase) AND `Vinay` (capital) — same phone `7800766561`
- Two `Jyoti` records — phones `7052887646` and `7052887146` (one digit different — separate typos)

**Root cause:** My `sbp_resolve_customer_for_booking` normalized phones with this regex:

```
regexp_replace(phone, '[^0-9+]', '', 'g')
```

This kept the `+` symbol but didn't strip country code. So:
- Existing `Vinay` had phone stored as `+917800766561`
- New booking's customer_phone was `7800766561`
- Normalized: `+917800766561` ≠ `7800766561` → no match → duplicate created

The Jyoti case is different — those are genuinely different phones (typo error during data entry). The dedup leaves those alone since name-only matching is risky.

---

## What this batch does

### 1. New `sbp_normalize_phone()` function
Strips ALL non-digits (including `+`), then strips Indian country code `91` if number is exactly 12 digits starting with `91`. So:
- `+917800766561` → `7800766561`
- `7800766561` → `7800766561`
- `+91 7800-766561` → `7800766561`

Now they all match.

### 2. Rewritten `sbp_resolve_customer_for_booking()`
Uses the new normalization on BOTH sides of comparison — existing customers' stored phones get normalized at lookup time, so legacy "+91" prefixed phones now match modern "no-prefix" entries.

### 3. New `sbp_dedup_customers(shop_id)` RPC
- Groups customers by case-insensitive name + normalized phone
- For each group with >1 row, keeps the OLDEST as canonical
- Moves all `bills.customer_id` and `sbp_bookings.customer_id` references to canonical
- Deletes the duplicates
- Idempotent (re-running is safe, returns zero counts)

### 4. Auto-runs dedup on migration
Loops through all hospitality + commerce shops in your DB and runs dedup. RAISE NOTICE tells you what got merged.

---

## Files

```
batch021_4/
├── BATCH_021_4_DEPLOY.md
└── db/migrations/
    └── 024_customer_dedup.sql
```

---

## Deploy

Single SQL file. No code push needed.

Paste `024_customer_dedup.sql` in Supabase SQL Editor → Run.

Expected output:
```
NOTICE: Shop "Glitz & Glam" (day_room) — merged 1 duplicate customers
```

(Number depends on your data. Vinay duplicate gets merged. Both Jyotis stay separate because they have different phones.)

After this:
- Customer Book should show 5 customers (was 6) — vinay merged into Vinay
- All 52 bills now consolidated under canonical Vinay
- Old "vinay" record deleted

---

## ⚠️ Status check — three open items from earlier batches

You haven't confirmed these. Please verify:

### (a) Did you run the salvage RPC after re-running migration 023?
```sql
SELECT public.sbp_salvage_orphan_hotel_bills(
  (SELECT id FROM shops WHERE business_name ILIKE '%glitz%' LIMIT 1)::uuid
);
```
This is what fixes GG-0076 → 3 line items. **Without this RPC call, the bill stays empty.**

### (b) Did you push the new `billing.html` from Batch 021.3?
The defensive try-catch + legacy fallback is in there. Without it, future bills could still fail silently.

### (c) Customer history page (separate bug — deferred)
The "No activity yet" page needs a separate look at the `sbp_get_customer_timeline` RPC. After this batch + the salvage RPC, it might fix itself (since the bills will have proper customer_id + items). If still broken after, send screenshot and I'll diagnose the RPC.

---

## Verification

```sql
-- (1) Confirm no duplicate (name + phone) remain
SELECT lower(trim(name)) AS n, public.sbp_normalize_phone(phone) AS p, COUNT(*)
FROM customers
WHERE shop_id = (SELECT id FROM shops WHERE business_name ILIKE '%glitz%' LIMIT 1)
GROUP BY 1, 2 HAVING COUNT(*) > 1;
-- Expected: 0 rows.

-- (2) Confirm Vinay's bills are all under one customer record now
SELECT c.name, c.phone, COUNT(b.id) AS bill_count, SUM(b.grand_total) AS total
FROM customers c
LEFT JOIN bills b ON b.customer_id = c.id
WHERE c.shop_id = (SELECT id FROM shops WHERE business_name ILIKE '%glitz%' LIMIT 1)
  AND lower(trim(c.name)) = 'vinay'
GROUP BY c.id, c.name, c.phone;
-- Expected: 1 row with bill_count = 52
```

---

**Built by Claude · Batch 021.4 · 8 May 2026 · Customer dedup fix**
