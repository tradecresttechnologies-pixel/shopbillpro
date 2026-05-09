# Batch 021B-A — Front Desk + Walk-in Fast-path

**Date:** 9 May 2026
**Scope:** 2 new pages + 1 SQL migration + 1 sidebar update. Closes the first 2 of 5 Hotel Phase 2 deliverables.

---

## What this batch ships

### 1. `front-desk.html` — operational dashboard

A real-time front-desk view for hotel staff. Replaces "scroll the bookings list and infer state" with a glanceable 4-tile board.

**Layout:**
- **Mobile:** 2×2 grid (Arrivals · Departures · In-House · Vacant)
- **Desktop ≥1024px:** 1×4 row, full-width tiles
- Hero header with today's date, day name, and an animated occupancy ring (CSS-only, gradient stroke)
- Each tile: large count, top-3 entries with avatar + name + room number, "tap to view all" link to filtered bookings
- 4 quick-action buttons below tiles: Walk-in (primary CTA), Bookings, Rooms, Reports

**Behavior:**
- Auto-refresh every 30s while tab visible (silent — no toast on success)
- Manual refresh button in topbar (spinning icon during fetch)
- Count flash animation when a number changes between refreshes (subtle scale pulse)
- Online/offline pill in topbar; offline kills auto-refresh
- Honors dark + light theme (CSS vars)
- Bilingual EN/HI throughout via existing `lang.js` mechanism
- Free-plan gate: shows upgrade banner instead of dashboard

**Touch points:**
- Tap a tile → navigates to `bookings.html?filter=<scope>`
- Tap a guest item → `bookings.html?id=<booking-id>` (opens that booking's detail)
- Tap a vacant room item → `walk-in.html?room=<room-id>` (pre-selects the room)
- Walk-in CTA → `walk-in.html`

### 2. `walk-in.html` — single-screen check-in

Drop-in guest goes from arrival to checked-in in **one screen, no modals**.

**Three numbered sections, all on one scroll:**

1. **Pick a room** — visual grid of vacant rooms (3-col mobile, 5-col desktop). Tap to select. Each tile shows room number, type, base price. Selected tile gets amber ring + checkmark badge.
2. **Length of stay** — chip row (1 night / 2 / 3 / 1 week / Custom). Check-in date is locked to today (IST), check-out auto-derived. Custom unfolds a number input.
3. **Guest details** — minimal form: name, phone (10-digit live validator with `inputmode="numeric"` for mobile keypads), WhatsApp (auto-fills from phone), ID type + number, adults/children steppers, advance amount. Foreign-guest toggle reveals country + passport + visa fields (FRRO-ready for 021B-B).

**Sticky bottom bar** (always visible while scrolling):
- Live grand total — `₹X,XXX` updates as you change room/nights/advance
- Subtitle shows the math: `₹600 × 2n · GST 5% · Advance ₹500 → Bal ₹770`
- Primary CTA `⚡ Check In Now` — disabled until room + name + 10-digit phone all valid
- (For foreign guests, additionally requires passport number)

**Atomic submission** via new `sbp_walkin_check_in` RPC (migration 026):
- Creates the booking with `status='confirmed', source='walk_in'`
- Immediately checks in (flips status to `checked_in`, room status to `occupied`)
- If check-in fails after booking creation, rolls back the booking automatically (no orphans)
- Returns folio summary so the success screen renders without a second round-trip

**Success modal:**
- Animated checkmark + guest name + room
- Folio summary (room, stay, rate, grand total, advance, balance due)
- Two actions: "New walk-in" (resets form, refreshes vacant rooms) or "View booking" (opens detail in bookings.html)

### 3. `db/migrations/026_hotel_phase2_frontdesk.sql`

Two new RPCs + one module profile update:
- **`sbp_front_desk_dashboard(p_shop_id)`** — single-roundtrip JSON envelope: counts, arrivals, departures, in-house, vacant rooms (each capped at 50). All times IST.
- **`sbp_walkin_check_in(p_shop_id, p_data)`** — atomic create + check-in. Wraps `sbp_bookings_create` + `sbp_bookings_check_in`. Forces check-in date = today IST. Rollback on partial failure.
- **Module profile flip** — adds `front_desk` + `walk_in` to hospitality profile with `NEW` badge so they appear in the sidebar for hotel/resort/guesthouse/etc shops.

### 4. `lib/sidebar-engine.js` — catalog entries

Adds `front_desk` (🛎️) and `walk_in` (⚡) to the module catalog. Combined with the SQL profile flip, both appear in the sidebar for hospitality shops automatically.

---

## Files in this batch (4)

```
db/migrations/026_hotel_phase2_frontdesk.sql   ← NEW
front-desk.html                                ← NEW
walk-in.html                                   ← NEW
lib/sidebar-engine.js                          ← edited (1 catalog block)
```

---

## Deploy order

### 1. SQL — Supabase SQL Editor
Run `026_hotel_phase2_frontdesk.sql`. Idempotent. Drops and recreates the two RPCs; upserts module profile rows.

### 2. Verify the dashboard RPC works
```sql
SELECT public.sbp_front_desk_dashboard(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
);
```
Expected: jsonb with `ok: true`, `counts`, `arrivals[]`, `departures[]`, `in_house[]`, `vacant_rooms[]`.

### 3. Frontend deploy
GitHub Desktop → commit `front-desk.html`, `walk-in.html`, `lib/sidebar-engine.js`, `db/migrations/026_hotel_phase2_frontdesk.sql` → push → Vercel auto-deploys.

### 4. Bump service worker
Update SW cache version (e.g. v1.5.13 → v1.5.14) so the PWA picks up the two new pages on hard refresh. Or just hard-refresh the PWA on the test device.

### 5. End-to-end test on Glitz & Glam
1. Open Front Desk via sidebar (or `app.shopbillpro.in/front-desk.html`). Verify hero shows today's date + occupancy ring, four tiles populate with current state.
2. Tap each tile — should navigate to bookings.html with the correct filter.
3. Tap a vacant room tile → walk-in.html opens with that room pre-selected.
4. Run a full walk-in flow: pick a room, set 2 nights, fill name "Test Guest" + phone "9876543210", set advance ₹500, click **Check In Now**. Success modal should appear within 1-2s. Folio summary should show room, stay, total, advance, balance due.
5. Click **View booking** → opens bookings.html with that booking's detail.
6. Go back to Front Desk → vacant count decreased by 1, in-house count increased by 1, count animation flashes.

### 6. (Optional) Test the rollback path
Manually corrupt the room state (e.g., temp set room status to 'maintenance' via SQL) and try a walk-in. The check-in should fail; `sbp_walkin_check_in` rolls back the booking creation; you should NOT see an orphan 'confirmed' booking in `sbp_bookings`.

---

## Design notes (the "really professional" bar)

- Typography stack matches the rest of the app (Outfit display + Noto Sans body). Added **JetBrains Mono** for numeric/uppercase labels — gives the data-dense areas a refined operational feel without competing with body text.
- Color discipline: tile palettes use status-driven hues (amber/blue/green/slate) at low opacity for backgrounds, full saturation for counts. No decorative purple gradients.
- Motion is purposeful: only the count flash (data changed) and occupancy ring fill (initial reveal) animate. No idle bouncing/floating.
- Skeleton loaders on first paint (no jarring spinner takeover).
- All interactive elements are ≥38×38px touch targets. Sticky bottom bar accounts for safe-area-inset-bottom on iOS.
- Live phone validator gives instant `4/10 digits` → `✓ valid` feedback as you type, vs. the typical "wait until submit, then yell at user" pattern.

---

## Known gaps (deferred to 021B-B / 021B-C)

- **Form B printable register** + **Form C generator** — 021B-B (next sub-batch). All foreign-guest fields the walk-in form collects today are already wired into `sbp_bookings` via existing 022/023 schema; the report SQL just needs to select them.
- **Hotel reports (occupancy %, ADR, RevPAR)** — 021B-C.
- **Front-desk on dashboard.html** — adding a "Today's snapshot" widget on the home dashboard for hospitality shops would bring the front-desk numbers directly to the home screen. Defer; the sidebar entry + bottom-nav link are sufficient surface area for now.
- **Real-time push** instead of 30s polling — would require Supabase Realtime subscriptions. Defer to post-beta.

---

## Rollback

- **SQL:** the two new RPCs are `CREATE OR REPLACE` style; to remove them entirely, run `DROP FUNCTION public.sbp_front_desk_dashboard(uuid);` and `DROP FUNCTION public.sbp_walkin_check_in(uuid, jsonb);`. Module profile rows can be deleted with `DELETE FROM sbp_module_profiles WHERE profile='hospitality' AND module_code IN ('front_desk','walk_in');`
- **Frontend:** GitHub Desktop → revert the commit → push.

— TradeCrest Technologies Pvt. Ltd. · CIN U62099UP2026PTC247501
