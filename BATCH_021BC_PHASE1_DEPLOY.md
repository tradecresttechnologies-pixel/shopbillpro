# 021B-C Phase 1 — Hotel Reports (KPIs + Daily Ops + DMR)

**Scope:** Extends `compliance.html` (titled "Hotel Reports") with three new
tabs alongside the existing Form B / Form C. Backed by 3 new RPCs in migration 036.

| Tab | Purpose |
|---|---|
| 📊 **Performance** | Occupancy %, ADR, RevPAR for any date range — the 3 KPIs hotels live by |
| 📅 **Daily Ops** | Arrivals + Departures + In-house guests (3 sub-tabs) |
| 📋 **Daily Manager Report** | Single-page A4-printable exec summary for one specific date |
| 📒 Form B | (unchanged) Guest Register |
| 🛂 Form C | (unchanged) FRRO foreign guests |

Phase 2 (folios/outstanding, room status, no-shows/cancellations) and
Phase 3 (Hotel GST by tariff slab, booking source, repeat guests) remain
queued for later batches.

---

## Files

```
db/migrations/036_hotel_reports_phase1.sql   ← 3 new RPCs (353 lines)
compliance.html                              ← +521 lines (888 → 1409)
```

No other files touched.

---

## ⚠️ DEPLOY ORDER (critical)

**1. Run SQL migration FIRST.** The RPCs must exist before the new tabs
   try to call them. Open Supabase SQL Editor → paste contents of
   `db/migrations/036_hotel_reports_phase1.sql` → Run.

   Verify in pg catalog:
   ```sql
   SELECT proname FROM pg_proc
   WHERE proname LIKE 'sbp_hotel_%' OR proname = '_sbp_check_shop_owner';
   ```
   Should include: `_sbp_check_shop_owner`, `sbp_hotel_kpis`,
   `sbp_hotel_arrivals_departures`, `sbp_hotel_in_house`
   (plus pre-existing `sbp_hotel_form_b_register`, `sbp_hotel_form_c_data`,
   `sbp_hotel_room_gst_for_rate`, etc.)

**2. Push HTML.** `compliance.html` → GitHub Desktop commit + push.

**3. Bump SW.** `v1.5.32 → v1.5.33` (so PWA clients pick up the new HTML).

**4. Hard-refresh** browser.

---

## What the user sees after deploy

Visiting "Hotel Reports" from the sidebar now lands on the **Performance**
tab by default (instead of Form B as before). Form B and Form C are still
accessible — just two tabs to the right.

### Performance tab
3 large cards across the top:
- **Occupancy %** — room-nights sold / available, with raw counts below
- **ADR** — average daily rate (₹)
- **RevPAR** — revenue per available room (₹)

Below: a 4×2 grid of supporting numbers (room revenue, nights sold, available
nights, total rooms, arrivals, departures, cancellations, no-shows).

Uses the existing toolbar (From/To dates + Today/7d/30d/90d/This month presets).

### Daily Ops tab
3 sub-tabs (Arrivals / Departures / In-house) with row counts in pills.

- **Arrivals:** all check-ins in the date range (pending/confirmed/checked_in/checked_out)
- **Departures:** all check-outs in the date range (checked_in/checked_out only)
- **In-house:** currently checked-in guests *as of today* (regardless of date range)

Each shows guest name, phone, room, pax, nights, status, amount.

### Daily Manager Report tab
Composed from all three RPCs called with `from = to = the 'To' date`.

The on-screen view is styled like an A4 sheet. Sections:
1. Header (shop name + address + date + printed-on timestamp)
2. **Performance** — 3 KPIs for that single day
3. **Revenue Summary** — room revenue, departure collections, in-house folios, rooms occupied
4. **Movement** — Arrivals + Departures side-by-side (top 12 each)
5. **Exceptions** — cancellations, no-shows, total bookings, available rooms
6. Signature lines for Manager / Auditor / Reviewer

Print button on the DMR produces a clean single-page A4 portrait via
`@media print` CSS.

---

## Smoke tests

### A. Migration smoke
After running SQL, in Supabase SQL Editor:
```sql
-- Use Glitz & Glam shop id for testing
SELECT sbp_hotel_kpis(
  '73aa8ede-6352-4549-8617-cccacdd5c821'::uuid,
  CURRENT_DATE - 30,
  CURRENT_DATE
);
SELECT sbp_hotel_arrivals_departures(
  '73aa8ede-6352-4549-8617-cccacdd5c821'::uuid,
  CURRENT_DATE - 7,
  CURRENT_DATE + 7
);
SELECT sbp_hotel_in_house('73aa8ede-6352-4549-8617-cccacdd5c821'::uuid);
```
All three should return `{"ok": true, ...}` with sensible shape (not errors).

If `not_owner` returned, the calling user is not the shop owner — switch
to the owner account or test through the UI (which uses `auth.uid()`).

### B. Performance tab
1. Open compliance.html (sidebar → "Hotel Reports")
2. Default lands on Performance tab
3. KPI cards populate with numbers (Occupancy %, ADR, RevPAR)
4. Switch presets: Today / 7d / 30d → numbers update on each change
5. CSV export: downloads `hotel-performance-YYYY-MM-DD.csv` with single summary row
6. Print: prints the KPI grid

### C. Daily Ops tab
1. Click "Daily Ops" tab
2. Sub-tab "Arrivals" is active. Should show all expected arrivals in the date range
3. Click "Departures" sub-tab — should show only `checked_in`/`checked_out` departures
4. Click "In-house" — should show currently checked-in guests (as of today)
5. Pills show counts on each sub-tab
6. CSV export: exports the visible sub-tab (arrivals OR departures OR in-house)

### D. Daily Manager Report
1. Click "Daily Manager Report" tab
2. Sets the "To" date in the toolbar — DMR uses that single date
3. The A4-style sheet renders with all 5 sections
4. Print button → opens browser print dialog → preview should show a clean single-page A4 with the DMR only (no sidebar, no tabs, no toolbar visible). The dark theme should not bleed into the print (black text on white background).
5. CSV button shows toast "DMR is a printable summary — use Print" and skips export

### E. Form B / Form C (regression check)
1. Click "Form B" tab — should still work exactly as before
2. Click "Form C" tab — should still work exactly as before
3. CSV + Print buttons still work on these tabs

### F. Mobile
1. On a narrow viewport (DevTools Responsive Mode at 380px):
   - Tabs scroll horizontally (existing behavior)
   - KPI cards stack vertically (3 → 1 column)
   - Stat grid goes 4 → 2 columns
   - DMR KPI row goes 3 → 2 columns; movement list stacks vertically

---

## KPI formulas (for verifying numbers)

```
Occupancy % = (Room-nights sold / Available room-nights) × 100
ADR         = Room revenue / Room-nights sold
RevPAR      = Room revenue / Available room-nights
            = Occupancy % × ADR / 100  (by definition)

Available room-nights = active rooms × days in range
Room-nights sold      = sum of nights actually stayed
                        (status in 'checked_in' or 'checked_out')
Room revenue          = sum of rate_per_night × nights-in-range
                        (GST-exclusive, extras-exclusive)
```

Cancellations + no-shows are **excluded** from occupancy/ADR/RevPAR
(industry standard — STR, Cloudbeds, Hotelogix all do this).

For partial date ranges, a 3-night booking ₹3000 → ₹1000/night, so if only
2 of its nights fall in the queried range, ₹2000 contributes.

---

## Architecture notes

- **API-first respected:** All 3 RPCs follow the locked pattern — `jsonb {ok, error, ...}` envelope, shop ownership check via `_sbp_check_shop_owner()` helper, GRANT to authenticated. No business logic in JS.
- **DMR composed client-side:** Single source of truth in SQL — DMR re-uses the same 3 RPCs (KPIs + A/D + In-house) called with `from = to = single date`. No duplicate aggregation logic.
- **Print stylesheet additive:** New `@media print` rules added; existing Form B/C print CSS untouched.
- **Indian formatting:** `fmtMoney()` uses `toLocaleString('en-IN')` → `₹1,23,456` format.
- **Bilingual:** All new labels have `lang-en` + `lang-hi` spans.

---

## Pending after Phase 1 lands

Once Vinay verifies smoke tests pass:

**Phase 2 (~2-3h):**
- Folios tab: open folios + outstanding balances
- Rooms tab: room status snapshot
- No-show + cancellation detail reports

**Phase 3 (~2h):**
- Hotel GST by tariff slab (0/5/18% — proper Indian compliance angle)
- Booking source analysis (direct/walk-in/agent)
- Repeat guest analytics

---

## Roadmap context

- 028A app-wide print stylesheet audit (~2-3h)
- 022D-D server-side migration of remaining bills.html PIN-gated actions
- Vertical polishing (Salon, Restaurant, Pharmacy, Healthcare, Education, Retail)
- Pre-beta QA → **BETA LAUNCH** 🚀
