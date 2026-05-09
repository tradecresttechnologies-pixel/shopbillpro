# Batch 021B-B — Form B (Hotel Register) + Form C (FRRO)

**Date:** 9 May 2026
**Scope:** 1 new page + 1 SQL migration + 1 sidebar update. Closes Hotel Phase 2 deliverables 3 & 4 of 5.

---

## What this batch ships

### 1. `compliance.html` — single page, two tabs

A unified compliance hub for the regulatory paperwork every Indian hotel has to produce. Clean tabular layout, A4-landscape print stylesheet, CSV export with Excel-compatible UTF-8 BOM.

**Tab 1 · Guest Register · Form B**
- Hotel Register required under the Police Act / state Hotel Rules.
- Captures **every arrival** in the date range (Indian + foreign, all statuses except cancelled).
- 14 columns matching the standard Indian register: Sl, Arrival, Guest Name, Father/Husband, Address, Nationality, Occupation, Coming From, Going To, Departure, Room, ID Proof, Phone, Status.
- Fields not stored digitally (Father's name, Address, Occupation, Coming From, Going To) render as `—` placeholder — the printed register has handwriting space for the operator to fill at the desk.

**Tab 2 · Foreign Guests · Form C · FRRO**
- Filters to foreign guests only (`is_foreign=true`).
- 24 columns including all FRRO Form C fields: passport details, visa details, dates, addresses abroad/in-India, purpose of visit, contact info.
- Fields we don't store (Sex, DOB, passport place/date of issue, visa place/date of issue, port of arrival in India) render as `—` — operator can fill in handwriting on print, or supplement the CSV before FRRO portal upload at indianfrro.gov.in.

**Common controls:**
- Date range picker with quick presets: Today / 7d / 30d (default) / 90d / This month
- **Print** button — A4 landscape with full print stylesheet:
  - Print-only header with shop name, address, GSTIN, period, total records, generation timestamp
  - Boxed table with Police-form-style black borders
  - Print-only signature block at bottom (Manager / Owner / Date+Stamp)
  - Browser headers/footers/UI all hidden via `@media print`
- **CSV** export — UTF-8 BOM (Excel opens cleanly), per-tab column mapping, filename pattern `<shop>_<formb|formc>_<from>_<to>.csv`. Foreign-guest CSV is structured for FRRO portal bulk-upload after manual supplementation.

**Other niceties:**
- Loading skeleton rows while RPC is in flight
- Row count + period chip in status bar
- "FOREIGN" badge on foreign-guest rows in Form B
- Status pills color-coded (checked-in green, confirmed blue, etc.)
- Free-plan upgrade gate
- Bilingual EN/HI throughout (now with the correct CSS toggle rules)
- Dark + light theme honored

### 2. `db/migrations/027_hotel_compliance.sql`

Two new STABLE SECURITY DEFINER RPCs + one module profile flip:

- **`sbp_hotel_form_b_register(p_shop_id uuid, p_from date, p_to date)`** — Indian Hotel Register data. Filters `check_in_date BETWEEN p_from AND p_to AND status <> 'cancelled'`. Returns shop header + period + total + 1-indexed serial-numbered rows.

- **`sbp_hotel_form_c_data(p_shop_id uuid, p_from date, p_to date)`** — FRRO Form C data. Same filter PLUS `is_foreign=true`. Returns shop header + period + total + foreign-guest rows with passport/visa/address-abroad fields.

Both RPCs check ownership via `sbp_check_hospitality_owner` (refuses if requester isn't the shop owner). Date validation: rejects null/inverted ranges with stable error codes.

- **Module profile flip** — `INSERT … ON CONFLICT DO UPDATE` adds `compliance` to hospitality profile with `NEW` badge so it appears in the sidebar for hotel/resort/etc shop types.

### 3. `lib/sidebar-engine.js` — catalog entry

Adds `compliance` (📋) to the module catalog. Combined with the SQL profile flip, surfaces in the sidebar automatically. **This file already contains the front_desk + walk_in entries from 021B-A** — push this version (it's a superset).

---

## Files in this batch (4)

```
db/migrations/027_hotel_compliance.sql   ← NEW
compliance.html                          ← NEW
lib/sidebar-engine.js                    ← edited (adds compliance, supersedes 021B-A version)
BATCH_021B_B_DEPLOY.md                   ← this doc
```

---

## Deploy order

### 1. SQL — Supabase SQL Editor
Run `027_hotel_compliance.sql`. Idempotent. Creates/replaces 2 RPCs and upserts the compliance module profile row.

### 2. Verify the RPCs
```sql
-- Form B (last 30 days)
SELECT public.sbp_hotel_form_b_register(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
  CURRENT_DATE - INTERVAL '30 days',
  CURRENT_DATE
);

-- Form C (last 90 days, foreign-only)
SELECT public.sbp_hotel_form_c_data(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
  CURRENT_DATE - INTERVAL '90 days',
  CURRENT_DATE
);
```
Expected: jsonb with `ok:true`, `shop`, `period`, `total`, `rows[]`. Empty array is fine for a fresh shop.

### 3. Frontend deploy
GitHub Desktop → push `compliance.html`, `lib/sidebar-engine.js`, `db/migrations/027_hotel_compliance.sql` → Vercel auto-deploys.

### 4. Bump SW
Update SW cache version (e.g. v1.5.14 → v1.5.15) so the PWA caches the new page on hard refresh.

### 5. End-to-end test on Glitz & Glam
1. Sidebar should now show **Compliance** with NEW badge under hospitality menu.
2. Open Compliance → defaults to Form B / Last 30d. Should populate (or show "No arrivals in this date range" cleanly).
3. Run a quick walk-in (from front-desk or walk-in.html) for a non-foreign guest, then refresh Compliance → row appears in Form B. Click **Print** → browser print dialog opens with A4 landscape preview, black-boxed table, shop letterhead, signature block at bottom.
4. Run another walk-in with the **🌍 Foreign guest** toggle on (fill country + passport). Switch to Form C tab. The foreign guest should appear with passport, visa fields populated, the rest as `—`.
5. Click **CSV** → downloads `glitz_glam_formc_*.csv`. Open in Excel → all columns properly aligned, UTF-8 special characters render correctly.

---

## Design notes

- **Aesthetic shift from 021B-A**: Front-desk is an *operations console* (high motion, status colors). Compliance is a *registry* — calm, dense, government-document feel. JetBrains Mono on column headers reinforces the records/data character. Status pills use thin outlines (1px border) instead of saturated fills — they read as data tags, not buttons.
- **Print-first, not print-as-afterthought**: the table renders in dark mode by default, but `@media print` switches to white background, black text, full borders, A4 landscape. The print-only `<div class="print-hd">` is hidden on screen and only fills with shop letterhead at the moment Print is clicked.
- **Excel compatibility**: CSV starts with `\uFEFF` (UTF-8 BOM) so Excel correctly detects encoding. Names with commas/quotes/newlines are properly escaped per RFC 4180.

---

## Known gaps (deferred)

- **Sex / DOB / passport place+date of issue / visa place+date of issue / port of arrival** — fields not in current `sbp_bookings` schema. Two paths to close this in a future micro-batch:
  - (a) Add the columns to `sbp_bookings` (migration 028) + extend walk-in.html foreign section UI.
  - (b) Treat them as Form-C-only operator inputs collected at the moment of FRRO submission.
  - Recommend (a) — single source of truth, no double entry.
- **Per-guest individual Form C printout** (1 page per foreign guest, mimicking the official paper form layout) — current implementation prints all foreign guests in a single tabular sheet. Some FRROs accept tabular, some prefer per-guest. Defer until a real test guest is checked in and we ask the operator what their local FRRO accepts.
- **Direct FRRO portal API integration** — Bureau of Immigration runs the indianfrro.gov.in portal but does not publish a public API. Current path: CSV export → manual upload through their bulk-upload form. Would require business approval + login to attempt automation; likely never worth the effort for hotels under 50 rooms.
- **State-specific Form B variants** — register format differs slightly state to state (Maharashtra vs UP vs Kerala etc.). Current page renders the most common 14-column format which covers all major states. If a state demands a different specific layout, add a state selector + a per-state print stylesheet.
- **Hotel Reports (occupancy, ADR, RevPAR)** — these belong in `reports.html`, not compliance. Queued as **021B-C**.

---

## Rollback

- **SQL**: `DROP FUNCTION public.sbp_hotel_form_b_register(uuid, date, date);` and `DROP FUNCTION public.sbp_hotel_form_c_data(uuid, date, date);`. Then `DELETE FROM sbp_module_profiles WHERE profile='hospitality' AND module_code='compliance';`
- **Frontend**: revert the commit via GitHub Desktop.

— TradeCrest Technologies Pvt. Ltd. · CIN U62099UP2026PTC247501
