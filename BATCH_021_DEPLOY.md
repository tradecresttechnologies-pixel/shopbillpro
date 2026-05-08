# BATCH 021 — Hotel Module Rebuild Phase 1

**Date:** 8 May 2026
**Migration #:** 022_hotel_v2_phase1.sql
**Status:** Ready to deploy
**Grounded in:** HOTEL_BUSINESS_MODEL.md v1.0
**Companion fix to:** the GST screenshot bug

---

## What this batch ships

The Phase 1 of the hotel rebuild — addresses the most-urgent gaps from the domain audit:

1. **GST per folio line — the bug Vinay flagged.** Bills generated from hotel folios now have correct GST per line. Room rate is auto-mapped to the statutory slab (₹1k=0%, ₹7.5k=5%, >₹7.5k=18%). Each folio extra carries its own GST rate + HSN code.

2. **Advance payment tracking.** Bookings now capture `advance_amount`, payment mode, reference. Shows on folio. Subtracted from grand_total to compute balance_due at check-out.

3. **Foreign-guest minimum fields.** `is_foreign` flag + passport / visa / country / Form C readiness fields. Full Form C generator UI lands in next batch (021B).

4. **Filter chips Vinay specifically asked for:** Today / **In-House** / **Arrivals** / **Departures** / **Checked-out** / Upcoming / **Foreign** / Past / All.

5. **Folio display rewrite** — shows GST clearly per line + total CGST + SGST breakdown + advance + balance due.

---

## Files

```
batch021/
├── BATCH_021_DEPLOY.md
├── db/migrations/
│   └── 022_hotel_v2_phase1.sql      ← run FIRST in Supabase SQL Editor
├── lib/
│   └── hospitality.js               ← patched (GST helper exports)
├── bookings.html                    ← patched (filter chips + GST + advance + foreign fields)
└── billing.html                     ← patched (folio→bill applies correct GST per line)
```

---

## What's intentionally NOT in this batch (deferred to 021B)

- **Per-night `folio_room_lines` table** — cleaner architecture, ships in Phase 2 with safe migration of existing bookings
- **Form C generator page** (printable PDF for FRRO upload)
- **Form B printable register**
- **Walk-in fast-path screen** (single-screen check-in)
- **4-column dashboard rebuild**
- **Hotel reports** (occupancy %, ADR, RevPAR — added to reports-engine)
- Group/corporate bookings, day-use rooms, refund flow

---

## Deploy steps

### Step 1 — Run the migration

Supabase SQL Editor → New Query → paste `db/migrations/022_hotel_v2_phase1.sql` → Run.

The migration is **fully additive** and idempotent. Existing bookings/extras unaffected (existing extras get `gst_rate=0` by default — they were created before this rule, no retroactive tax).

**Verification queries (run all four):**

```sql
-- 1. New columns on extras
SELECT column_name FROM information_schema.columns
WHERE table_name = 'sbp_booking_extras'
  AND column_name IN ('gst_rate','hsn_sac_code','gst_inclusive','cgst_amount','sgst_amount','taxable_amount','total_with_gst');
-- Expected: 7 rows

-- 2. New columns on bookings (advance + foreign)
SELECT column_name FROM information_schema.columns
WHERE table_name = 'sbp_bookings'
  AND column_name IN ('advance_amount','advance_payment_mode','is_foreign','passport_number','guest_country','visa_number','arrival_in_india_date');
-- Expected: 7 rows

-- 3. Test GST helpers
SELECT
  public.sbp_hotel_room_gst_for_rate(900)    AS rate_900,    -- 0
  public.sbp_hotel_room_gst_for_rate(2500)   AS rate_2500,   -- 5
  public.sbp_hotel_room_gst_for_rate(8000)   AS rate_8000,   -- 18
  public.sbp_hotel_extra_gst_for_category('food')    AS food_gst,    -- 5
  public.sbp_hotel_extra_gst_for_category('service') AS service_gst; -- 18

-- 4. Test new filter values
SELECT public.sbp_bookings_list(
  (SELECT id FROM shops WHERE shop_type IN ('hotel','resort','guesthouse','service_apartment','boutique_hotel','hostel') LIMIT 1)::uuid,
  'in_house',
  NULL
);
-- Expected: { ok: true, bookings: [...] } — with bookings whose status='checked_in'
```

### Step 2 — Push the 3 code files

| From zip | To repo |
|---|---|
| `lib/hospitality.js` | `/lib/hospitality.js` (overwrites) |
| `bookings.html` | `/bookings.html` (overwrites — supersedes 019.1) |
| `billing.html` | `/billing.html` (overwrites — supersedes 019.1) |

Commit message:
```
Batch 021: Hotel module rebuild Phase 1 — GST per folio line,
advance payment tracking, foreign-guest fields, expanded filter
chips (in-house, arrivals, departures, checked-out, foreign),
GST-aware folio display + bill generation
```

Vercel auto-deploys.

### Step 3 — Smoke tests (in order)

#### Test A — re-do Vinay's broken case
Same scenario from the screenshot:
- Booking: vinay, Room 101 Deluxe, 1 night × ₹600 = ₹600
- Add Extras: hair saloon ₹350 (service category) + dinner ₹900 (food category)
- Click **Check Out & Generate Bill**
- **Expected on billing.html:**
  - 3 rows populated
  - Room row: ₹600, GST 0% (since ≤ ₹1,000)
  - Hair saloon row: ₹350, GST 18% (service category)
  - Dinner row: ₹900, GST 5% (food category, non-specified premises)
  - Total = ₹600 + (₹350 + ₹63 GST) + (₹900 + ₹45 GST) = **₹1,958**

If the room rate had been ₹2,500 instead of ₹600:
  - Room: ₹2,500 + 5% = ₹2,625
  - + extras as above
  - Grand total ≈ ₹3,958

#### Test B — new filter chips
1. Go to bookings.html
2. Click each new tab in turn: In-House, Arrivals, Departures, Checked-out, Foreign
3. Each should fire a different RPC filter and show different bookings (or empty state with appropriate message)
4. **In-House** = anyone currently `status='checked_in'`
5. **Arrivals** = check_in_date is today AND status pending/confirmed
6. **Departures** = check_out_date is today AND status checked_in
7. **Checked-out** = checked out today
8. **Foreign** = any booking with `is_foreign=true`

#### Test C — Add Extra modal with GST
1. Open any in-house booking
2. Click **+ Add Extra Charge**
3. Pick category "Food" → GST auto-suggests 5%, HSN auto-fills "996331"
4. Pick "Service" → GST auto-suggests 18%, HSN "999722"
5. Pick "Laundry" → GST 18%, HSN "999719"
6. Toggle "Price includes GST" → total recalculates back-out style
7. Untoggle → total recalculates add-on style
8. Save → folio shows the line with GST chip badge

#### Test D — Foreign-guest booking
1. Click + New Booking
2. Tick "This is a foreign guest" → 4 fields appear (country, passport, visa, visa type)
3. ID type auto-switches to Passport
4. Try to save without passport → blocked with error
5. Add passport → saves. Detail modal shows guest with 🌐 FOREIGN badge + country + passport
6. Click "Foreign" filter chip → guest visible there

#### Test E — Advance payment
1. Create new booking with advance ₹500 via UPI
2. Detail modal shows advance row with payment mode
3. After check-in, fold shows: Grand Total ₹X, − Advance paid ₹500, Balance Due (X − 500)
4. Check out → bill should reflect this (note: in this batch the bill itself doesn't auto-credit the advance, that's part of Phase 2; the folio shows it correctly)

#### Test F — Folio GST display
1. Open detail modal of any in-house booking with a few extras
2. Folio section should show:
   - Room line with rate × nights
   - Below it: dim "  Room GST 5% (CGST + SGST) +₹X" line (only if rate > ₹1k)
   - Each extra with GST chip badge if non-zero
   - Below extras: dim "  Extras GST (CGST + SGST) +₹X"
   - Border separator
   - "Total Tax (CGST ₹X + SGST ₹X)" row
   - Grand Total
   - − Advance paid (if any)
   - Balance Due (if advance > 0)

---

## Rollback

If anything goes wrong:

1. **Database:** all new columns nullable or have defaults — no destructive change. To remove additions:
```sql
DROP FUNCTION IF EXISTS public.sbp_hotel_room_gst_for_rate(numeric);
DROP FUNCTION IF EXISTS public.sbp_hotel_extra_gst_for_category(text);
DROP FUNCTION IF EXISTS public.sbp_hotel_hsn_for_category(text);
DROP FUNCTION IF EXISTS public.sbp_booking_extras_compute_gst() CASCADE;
-- (Don't drop the new columns — bookings_create / list / check_out RPCs reference them)
```
   To restore the original RPCs, re-run migration 015_hospitality.sql (it has `CREATE OR REPLACE`).

2. **Code:** `git revert` the deploy commit. Existing bills are unaffected.

---

## What changed under the hood — in detail

### Schema additions to `sbp_booking_extras`
- `gst_rate numeric DEFAULT 0` — % rate for this line
- `hsn_sac_code text` — for tax invoice
- `gst_inclusive boolean DEFAULT false` — whether unit_price includes GST
- `cgst_amount`, `sgst_amount`, `taxable_amount`, `total_with_gst` — auto-computed by trigger

### Schema additions to `sbp_bookings`
- Advance: `advance_amount`, `advance_paid_at`, `advance_payment_mode`, `advance_reference`
- Foreign guest (full Form C field set): `is_foreign`, `guest_country`, `passport_number`, `passport_expiry`, `visa_number`, `visa_type`, `visa_expiry`, `arrival_in_india_date`, `intended_departure_date`, `address_abroad`, `next_address_in_india`, `purpose_of_visit`, `form_c_submitted_at`, `form_c_reference`

### New helper functions (pure, immutable)
- `sbp_hotel_room_gst_for_rate(rate)` → 0 / 5 / 18 based on slab
- `sbp_hotel_extra_gst_for_category(category)` → suggested rate per category
- `sbp_hotel_hsn_for_category(category)` → suggested HSN/SAC code

### Rewritten RPCs
- `sbp_booking_extras_add` — accepts gst_rate, auto-suggests HSN, calls trigger to compute amounts
- `sbp_booking_extras_list` — returns full GST breakdown
- `sbp_bookings_list` — supports new filter values: `in_house`, `arrivals`, `departures`, `checked_out_today`, `foreign`
- `sbp_bookings_create` — accepts and stores advance + foreign fields
- `sbp_bookings_check_out` — returns folio with per-line GST breakdown, room slab info, advance, balance_due

### New trigger
- `trg_booking_extras_compute_gst` — auto-computes cgst/sgst/taxable/total_with_gst on insert/update

### Client-side helpers (lib/hospitality.js)
- `SBPHotel.roomGstForRate(rate)` — mirror of SQL helper
- `SBPHotel.extraGstForCategory(cat)` — mirror
- `SBPHotel.hsnForCategory(cat)` — mirror

---

## Acceptance criteria

✅ Migration runs without error
✅ All 4 verification queries pass
✅ Vinay's broken case (Test A) now produces correct GST'd bill
✅ All 5 new filter chips work (Test B)
✅ Add Extra modal auto-suggests GST + HSN per category (Test C)
✅ Foreign-guest booking creates + filters correctly (Test D)
✅ Advance payment captures + displays correctly (Test E)
✅ Folio modal shows full GST breakdown (Test F)
✅ Existing pre-batch bookings continue to display without errors

If any fail → DevTools console screenshot + the failing query/click, I'll hotfix.

---

## What's next

After this deploys cleanly and you smoke-test it:

**Batch 021B:** Form C / Form B generator pages, walk-in fast path, 4-column dashboard, hotel-specific reports (occupancy/ADR/RevPAR added to reports-engine).

**Batch 021C:** Per-night folio_room_lines (the cleaner schema that handles peak-pricing nights, mid-stay rate changes, etc).

**After hotel:** Same domain-doc-then-rebuild template applied to Salon (022), Restaurant (023), Pharmacy (024), Healthcare (025), Education (026), Retail polish (027), Security hardening (028 — non-skippable), Pre-beta QA (029).

---

**Built by Claude · Batch 021 Phase 1 · 8 May 2026 · ShopBill Pro · TradeCrest Technologies Pvt. Ltd.**
