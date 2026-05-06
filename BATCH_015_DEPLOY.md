# ShopBill Pro — Batch 015: Hospitality Phase 1

**Date:** 6 May 2026
**Scope:** Full Hospitality vertical to 100% complete for beta launch
**Risk:** Medium — large additive batch (4 new tables, 18 RPCs, 2 new pages, 1 patched)
**Estimated deploy time:** ~5 min SQL + push

---

## What this delivers

The Hospitality vertical was scaffolded in `003_business_categories.sql` (3 sub-types, profile mapped, rooms/bookings/folio modules marked SOON) but never built. This batch builds it.

After deploy, **any hotel, lodge, homestay, guest house, hostel, dharamshala, resort, service apartment, day-room lounge, boutique hotel, or camping operator** can run their full daily workflow on ShopBill Pro:

```
Add room types  →  Add rooms  →  Take bookings  →  Check guests in
              →  Add folio extras (food/laundry/minibar)
              →  Check guests out  →  Auto-generate final bill
              →  Bill links back to booking for audit trail
```

---

## Files (8 total)

| Path | Action | What it does |
|------|--------|--------------|
| `db/migrations/015_hospitality.sql` | NEW | 4 tables, 18 RPCs, RLS, 8 indexes, 8 new sub-types, profile flips |
| `lib/hospitality.js` | NEW | `SBPHotel` client wrapper (summary, roomTypes, rooms, bookings, extras) |
| `lib/sidebar-engine.js` | MODIFIED | Adds hrefs for rooms/bookings/folio modules |
| `rooms.html` | NEW | Room inventory + room types CRUD (~570 lines) |
| `bookings.html` | NEW | Booking lifecycle + folio + check-in/out (~720 lines) |
| `billing.html` | MODIFIED | New `?booking_id` param branch + post-save linkBill hook |
| `BATCH_015_DEPLOY.md` | NEW | This file |

Carryover from earlier hotfix (already in this zip — push these too if not yet deployed):

| Path | From |
|------|------|
| `customer-history.html` | Batch 013 hotfix (joined_at fix + cache fallback) |
| `loyalty.html` | Batch 013 hotfix (admin overview page) |
| `db/migrations/014_loyalty_overview.sql` | Batch 013 hotfix (loyalty stats RPC) |

If you've already deployed the hotfix, those 3 files don't need re-pushing.

---

## Sub-types added (8 new under Hospitality macro)

```
🏖️  Resort
🛏️  Guest House
🏘️  Service Apartment
🎒  Hostel / Backpacker
🛕  Dharamshala / Pilgrim Lodge
💼  Day Room / Transit Lounge
💎  Boutique Hotel
🏕️  Camping / Glamping
```

Plus the 3 already there: Hotel/Lodge, Homestay/B&B, Banquet Hall = 11 total.

---

## Architecture

### Tables

```
sbp_room_types        — room categories (Single AC, Suite, etc.)
                        with capacity + pricing
sbp_rooms             — individual rooms with status (available/
                        occupied/cleaning/maintenance/blocked)
sbp_bookings          — full booking lifecycle from pending →
                        checked_out, with ID proof, source tracking
sbp_booking_extras    — folio line items (food, laundry, minibar,
                        service, telephone, transport, other)
```

All 4 have RLS via `shops.owner_id = auth.uid()`. Hospitality is **Pro/Business only** — server-enforced via `sbp_check_hospitality_owner(p_shop_id)` helper RPC called by every other RPC.

### RPC list (18 total)

```
HELPER:
  sbp_check_hospitality_owner(shop_id)

ROOM TYPES:
  sbp_room_types_list(shop_id)
  sbp_room_types_upsert(shop_id, data)
  sbp_room_types_delete(shop_id, room_type_id)

ROOMS:
  sbp_rooms_list(shop_id)
  sbp_rooms_upsert(shop_id, data)
  sbp_rooms_delete(shop_id, room_id)
  sbp_rooms_check_availability(shop_id, check_in, check_out, room_type_id?, exclude_booking_id?)

BOOKINGS:
  sbp_bookings_list(shop_id, filter, status_filter)
  sbp_bookings_create(shop_id, data)              -- conflict-checked
  sbp_bookings_check_in(shop_id, booking_id)      -- sets room.status='occupied'
  sbp_bookings_check_out(shop_id, booking_id)     -- returns folio for bill creation
  sbp_bookings_cancel(shop_id, booking_id, reason)
  sbp_bookings_link_bill(shop_id, booking_id, bill_id)

FOLIO EXTRAS:
  sbp_booking_extras_list(shop_id, booking_id)
  sbp_booking_extras_add(shop_id, booking_id, data)
  sbp_booking_extras_remove(shop_id, extra_id)

SUMMARY:
  sbp_hospitality_summary(shop_id)                -- occupancy %, arrivals,
                                                     departures, in-house,
                                                     upcoming
```

### Booking → Bill flow

```
1. User clicks "Check Out & Generate Bill" in bookings.html detail modal
2. Client calls sbp_bookings_check_out(shop_id, booking_id)
3. Server: marks booking checked_out, frees room (status='cleaning'),
   computes final grand_total, returns folio summary
4. Client redirects to billing.html?booking_id=X&cust=Y&wa=Z&auto=1
5. billing.html sees booking_id param:
   a. Fetches booking + extras via SBPHotel client wrapper
   b. Pre-fills customer name/phone/WhatsApp
   c. Adds line items: room (qty=nights × rate) + each extra
   d. Shows "🏨 Hotel checkout" banner
   e. Stashes booking_id in window._currentBookingId
6. Shopkeeper reviews bill, taps Save
7. Post-save hook (polling localStorage every 1.5s) detects new bill,
   calls SBPHotel.bookings.linkBill to bind bill_id back to booking
```

Bills retain their normal schema — no hospitality-specific columns added to bills/bill_items. Clean separation.

---

## Deploy steps

### Step 1 — SQL in Supabase SQL Editor (in order)

```sql
-- If not yet deployed:
-- \i db/migrations/014_loyalty_overview.sql

-- THIS BATCH:
\i db/migrations/015_hospitality.sql
```

Or paste the migration files into the SQL Editor. Both are idempotent. Total runtime ~5 sec.

### Step 2 — Verify SQL deployed correctly

```sql
-- (1) Tables created
SELECT tablename FROM pg_tables WHERE tablename LIKE 'sbp_%booking%' OR tablename LIKE 'sbp_room%';
-- Expected: 4 rows (sbp_room_types, sbp_rooms, sbp_bookings, sbp_booking_extras)

-- (2) RPCs registered
SELECT proname FROM pg_proc
WHERE proname IN (
  'sbp_check_hospitality_owner','sbp_hospitality_summary',
  'sbp_room_types_list','sbp_room_types_upsert','sbp_room_types_delete',
  'sbp_rooms_list','sbp_rooms_upsert','sbp_rooms_delete','sbp_rooms_check_availability',
  'sbp_bookings_list','sbp_bookings_create','sbp_bookings_check_in',
  'sbp_bookings_check_out','sbp_bookings_cancel','sbp_bookings_link_bill',
  'sbp_booking_extras_list','sbp_booking_extras_add','sbp_booking_extras_remove'
)
ORDER BY proname;
-- Expected: 18 rows

-- (3) Sub-types expanded
SELECT code, name_en FROM sbp_business_categories
WHERE macro_code = 'hospitality' ORDER BY display_order;
-- Expected: 11 rows total (3 existing + 8 new)

-- (4) Profile flips applied
SELECT module_code, status, badge FROM sbp_module_profiles
WHERE profile = 'hospitality' AND module_code IN ('rooms','bookings','folio');
-- Expected: all 3 rows show status='active', badge='NEW'
```

### Step 3 — Push to GitHub PWA repo

```
db/migrations/015_hospitality.sql       (new)
lib/sidebar-engine.js                    (modified)
lib/hospitality.js                       (new)
rooms.html                               (new)
bookings.html                            (new)
billing.html                             (modified)
```

If hotfix not yet deployed, also push:
```
db/migrations/014_loyalty_overview.sql   (new)
loyalty.html                             (new)
customer-history.html                    (modified)
```

Vercel auto-deploys ~30 sec.

---

## Smoke test checklist

For testing, you'll need a Pro/Business shop set to a hospitality sub-type. Easiest setup:
1. In `sbp_shops`, set the test shop's `business_subtype = 'hotel'` (or any other hospitality sub-type)
2. Confirm `plan` is `pro` or `business` and not expired
3. Hard-refresh the PWA

### A. Sidebar wiring

- [ ] Hard-refresh dashboard
- [ ] Sidebar shows **Rooms**, **Bookings**, **Folio** items with **NEW** badge
- [ ] Click **Rooms** → navigates to `rooms.html` (NOT settings or 404)
- [ ] Click **Bookings** → navigates to `bookings.html`
- [ ] Click **Folio** → also navigates to `bookings.html` (folio is accessed per-booking)

### B. Rooms page (`rooms.html`)

- [ ] Page loads with empty-state "No rooms yet"
- [ ] Tabs: **Rooms** / **Room Types**
- [ ] Tap **+** FAB on Room Types tab → modal opens
- [ ] Add a room type: name="Standard AC", adults=2, base_price=1500
- [ ] Save → toast "✅ Saved", room type card shows in list
- [ ] Switch to **Rooms** tab → empty state still
- [ ] Tap **+** FAB → modal opens with room type dropdown showing the type you just added
- [ ] Add a room: number="101", floor="Ground", type=Standard AC, status=Available
- [ ] Save → room appears in list with type badge + price
- [ ] Summary grid at top updates: Total=1, Available=1, Occupied=0
- [ ] Tap room card → edit modal opens with fields pre-filled
- [ ] Try to add another room with same number "101" → error "Room number already exists"
- [ ] Add room "102" → succeeds

### C. Bookings page (`bookings.html`)

- [ ] Click sidebar **Bookings** with rooms set up → page loads
- [ ] Click sidebar **Bookings** with NO rooms → "No rooms set up yet" banner with link to Rooms
- [ ] Tabs: Today / Upcoming / Past / All
- [ ] Tap **+** FAB → New Booking modal opens
- [ ] Fill: name="Test Guest", phone="9876543210", check-in=today, check-out=tomorrow
- [ ] After picking dates: room dropdown auto-populates with available rooms
- [ ] Pick room → rate auto-fills from room type
- [ ] Total at bottom shows: "1 × ₹1,500"
- [ ] Save → toast "✅ Booking created", booking card appears in **Today** tab
- [ ] Tap booking card → detail modal opens with guest details + stay + folio sections
- [ ] Status tag shows "Confirmed"

### D. Folio extras

- [ ] Tap **Check In Now** → status changes to "In-house", confirm
- [ ] Detail modal updates: "Add Extra Charge" + "Check Out & Generate Bill" buttons appear
- [ ] Tap **Add Extra Charge**
- [ ] Add: category=Food, description="Lunch (room service)", qty=2, unit_price=250
- [ ] Live total at bottom shows ₹500
- [ ] Save → toast "✅ Added to folio", extra appears in folio list
- [ ] Folio total updates: room (₹1500) + extras (₹500) = ₹2,000
- [ ] Tap × on extra → confirms, removes, total recalculates
- [ ] Add extra back

### E. Check-out & bill generation

- [ ] Tap **Check Out & Generate Bill** → confirms
- [ ] Toast "✅ Checked out — generating bill…"
- [ ] Auto-redirects to `billing.html?booking_id=...&cust=...&wa=...&auto=1`
- [ ] Banner appears: "🏨 Hotel checkout — folio loaded as bill items"
- [ ] Customer name + WhatsApp pre-filled
- [ ] Item rows: 1) "Room 101 · Standard AC (date → date)" qty=1 rate=₹1500
                2) "Lunch (room service) (food)" qty=2 rate=₹250
- [ ] Total computes correctly
- [ ] Save bill normally
- [ ] Wait ~2 sec, navigate back to bookings.html, find this booking
- [ ] Booking now shows tag "🧾 Bill" — bill_id linkage worked

### F. Cancellation flow

- [ ] Create another booking
- [ ] Tap booking → tap **Cancel Booking** → enters reason → confirms
- [ ] Status updates to "Cancelled"
- [ ] If was checked_in, room status reverts to "Available"

### G. Conflict prevention

- [ ] Create booking for room 101: check-in May 10, check-out May 12
- [ ] Try to create another booking for same room: check-in May 11, check-out May 13
- [ ] Should fail with toast "Room already booked for these dates"
- [ ] Try room 101 with check-in May 15 (no overlap) → succeeds

### H. Plan gating

- [ ] Demote a test shop to Free plan
- [ ] Visit rooms.html or bookings.html
- [ ] Should show "🔒 Hospitality is a Pro feature" upgrade banner
- [ ] Sidebar items still appear (BIZ badge — purely informational)

### I. Mobile / desktop sanity

- [ ] Open rooms.html on phone (<1024px) — sidebar hidden, bottom nav visible
- [ ] Open on laptop (≥1024px) — desktop sidebar visible, bottom nav hidden
- [ ] Sidebar scroll position holds across navigations (Batch 013 hotfix lives on)
- [ ] Theme toggle (sun/moon icon) works on both pages

---

## Rollback plan

If anything breaks badly:

| Layer | Rollback |
|-------|----------|
| RPCs | `DROP FUNCTION sbp_check_hospitality_owner, sbp_hospitality_summary, ... CASCADE;` (all 18) |
| Tables | `DROP TABLE sbp_booking_extras, sbp_bookings, sbp_rooms, sbp_room_types CASCADE;` (in this order) |
| Sub-types | Sub-types stay (harmless if hospitality build rolled back) |
| Profile flips | `UPDATE sbp_module_profiles SET status='soon', badge='SOON' WHERE profile='hospitality' AND module_code IN ('rooms','bookings','folio');` |
| HTML files | `git revert <commit>` for billing.html + lib/sidebar-engine.js; delete rooms.html, bookings.html, lib/hospitality.js |

The booking_id branch in billing.html is **non-blocking** — it only fires when `?booking_id` is in the URL. Existing billing flows are untouched. Low risk.

---

## What's NOT in this batch (Phase 2 / future)

```
□ Visual occupancy calendar (month grid view)        → Phase 2
□ Multi-room family bookings                         → Phase 2
□ Public-facing /s/<slug> booking page               → Phase 2
□ Channel manager (Booking.com, MMT, Agoda)          → Year 2
□ Dynamic pricing rules                              → Year 2
□ Housekeeping workflow + room cleaning queues       → Phase 2
□ Property report (RevPAR, ADR, occupancy charts)    → Phase 2
□ Guest preferences / repeat-stay tracking           → uses customer-history
□ Payment-on-arrival vs payment-on-checkout flag     → Phase 2
□ Room photos                                        → blocked on assets
```

Phase 1 alone is enough for a small-to-medium hotel (5-50 rooms) to run their daily workflow. Phase 2 adds polish and visual richness.

---

## Vertical readiness after this ships

```
TIER 1 (100% complete):
  ✅ Skilled services
  ✅ Tea stall / minimal
  ✅ Kirana / retail
  ✅ Food / FMCG
  ✅ Healthcare
  ✅ Education
  ✅ Salon (95% — Stylists deferred per your call)
  ✅ Hospitality (NEW — this batch closes it)

TIER 2 (still depth-pending — post-launch):
  Garments, Mobile, Auto, Jewellery, Wholesale,
  Pharmacy, Restaurant, Subscription, D2C
```

Hospitality is now your 7th-or-8th 100% vertical. After deploy, market it.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Batch 015 (6 May 2026)*
