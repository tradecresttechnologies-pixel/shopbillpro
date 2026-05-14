# Batch v4.7 — Public Booking Form + Auto-Create

**Delivered:** May 14, 2026

## What this batch does

When a customer visits your AI-generated website (`/s/glitz-glam`) and clicks **"Book Now"** on any room card (or "Reserve", "Enquire", etc.), a clean booking form modal appears inside the iframe. They fill name + phone + dates → click Send → a real `sbp_bookings` row is created server-side with `source='public_form'`. You see it immediately in your `/bookings.html` admin with the 🌐 Online tag.

## DEPLOY PATHS

```
NEW      db/migrations/053_public_booking.sql
REPLACE  lib/live-site.js
```

**2 files.** No s.html change. No edge function change. No website-builder.html change.

---

## Deploy in 3 steps (~3 min)

### Step 1 — Run SQL migration

Supabase Dashboard → SQL Editor → paste contents of `053_public_booking.sql` → Run.

**Verify with these 3 queries:**

```sql
-- A. The form config RPC should resolve glitz-glam as hospitality
SELECT sbp_get_public_booking_form_config('glitz-glam');
-- Expected: {ok:true, form_mode:"hospitality", shop_name:"Glitz &Glam", ...}

-- B. Room types lookup (returns empty array if you haven't added room types)
SELECT sbp_get_public_room_types('glitz-glam');
-- Expected: {ok:true, room_types:[]}

-- C. Test creating a booking
SELECT sbp_create_booking_public('glitz-glam', jsonb_build_object(
  'customer_name', 'Test Customer',
  'customer_phone', '9876543210',
  'check_in_date', (CURRENT_DATE + 1)::text,
  'check_out_date', (CURRENT_DATE + 3)::text,
  'num_adults', 2,
  'room_type_name', 'Deluxe Room',
  'rate_per_night', 2500
), 'test-ip-hash');
-- Expected: {ok:true, booking_id:"...", confirmation_code:"ABC12345", ...}

-- D. Confirm it landed in sbp_bookings
SELECT id, customer_name, source, status, check_in_date, room_type_snapshot
FROM sbp_bookings
WHERE shop_id = '73aa8ede-6352-4549-8617-cccacdd5c821'
  AND source = 'public_form'
ORDER BY created_at DESC LIMIT 3;
```

If all 4 succeed, the backend is ready.

### Step 2 — Deploy `lib/live-site.js`

1. Extract zip
2. Copy `lib/live-site.js` → repo's `/lib/` folder (overwrite)
3. GitHub Desktop → commit: `v4.7: Public booking form + auto-create`
4. Push origin → wait ~30 sec for Vercel

### Step 3 — End-to-end test

1. Open `/s/glitz-glam` in **incognito** (test as anonymous customer)
2. Scroll to "Our Accommodations" → click **Book Now** on any room card
3. **Expected:** Modal opens with title "Book a Room" + form fields:
   - Your name *
   - Phone * + Email
   - Check-in date * + Check-out date *
   - Adults * + Children
   - Room type (prefilled with the clicked card's title, e.g. "Deluxe Rooms")
   - Notes
4. Fill in test data, click **Send request**
5. **Expected:** Success screen with green ✅, confirmation code (e.g. `7B9F3D2A`), summary, and **💬 Follow up on WhatsApp** button
6. Click WhatsApp button → opens `wa.me/91...` with prefilled message including the code
7. Switch to shop owner view → open `/bookings.html`
8. **Expected:** The new booking appears with `🌐 Online` tag and `pending` status

---

## How the form adapts to business type

The `form_mode` field in `sbp_get_public_booking_form_config` returns one of three modes based on the shop's `shop_type`:

| Form mode | Triggered by shop_type | Form fields |
|---|---|---|
| `hospitality` | hotel, day_room, pg_hostel, resort, motel, guest_house, dharamshala, homestay, serviced_apartment | Name, Phone, Email, **Check-in date, Check-out date, Adults, Children, Room type**, Notes |
| `service` | salon, spa, clinic, physio, lab, consultancy, repair_service, tutoring, training | Name, Phone, Email, **Preferred date, Time, Service interested in**, Notes |
| `generic` | Everything else (retail, restaurant, online_brand) | Name, Phone, Email, **Preferred date, What are you interested in**, Notes |

Glitz & Glam has `shop_type='day_room'` → form_mode='hospitality' → full hotel form.

---

## Security & rate limiting

- **Rate limit:** Max 5 booking attempts per shop per IP (hashed) per hour. After that, returns `error: 'rate_limited'`.
- **IP hash:** Stored in customer's `sessionStorage` (we don't actually see the IP — just a session token, sufficient for casual abuse prevention).
- **Server-side validation:**
  - Name required, max 100 chars
  - Phone required, 10-15 digits after stripping non-numeric
  - Email optional but validated if provided
  - Check-in cannot be in the past
  - Check-out must be after check-in
  - Stay cannot exceed 90 days
- **Slug gating:** Only resolves slugs that are `published=true` OR `ai_published=true` with AI HTML present.
- **Public access:** RPCs granted to `anon` role — no login required for customers.

---

## How "Book Now" detection works in `live-site.js`

The click interceptor uses two signals (either is sufficient):

1. **Text match:** Button/link text contains any of: `book`, `reserve`, `enquire`, `inquire`, `order`, `schedule`, `appointment`, `contact us`.
2. **Class match:** Element has class `btn-primary`, `btn-secondary`, `sbp-book`, `book-btn`, or `book-now` AND is NOT inside `<header>` / `<nav>`.

**Excluded:**
- Links with `href="tel:..."`, `href="mailto:..."`, `href="https://wa.me/..."` (already direct contact)
- Anything inside `[data-sbp="cta"]` (that's the existing WhatsApp CTA component)
- Nav header links (so "Contact" in the nav still scrolls, doesn't open form)

The `findContextLabel()` helper walks up to find the nearest card heading. So clicking "Book Now" inside a `.room-card` with `<h3>Deluxe Rooms</h3>` prefills "Deluxe Rooms" in the room type field.

---

## What's deferred to future batches

| Feature | When |
|---|---|
| WhatsApp/email/SMS notification to shop owner on new booking | v4.10 (needs MSG91 setup or email service) |
| Room type dropdown using actual `sbp_room_types` (not just clicked card label) | When you add real room types via admin |
| Time-slot availability check (no double-booking) | v4.11 — needs Room Calendar |
| Razorpay deposit payment at booking time | When Razorpay batch ships |
| Customer auto-receives confirmation SMS/email | v4.10 |

---

## Files in this batch

```
Batch_Website_Booking_v4_7/
├── db/
│   └── migrations/
│       └── 053_public_booking.sql   (10.4 KB)
└── lib/
    └── live-site.js                  (36.2 KB, 844 lines)
```

Total: 2 files. SQL migration first, then deploy the JS.

---

## Rollback plan

If something breaks:

1. **Revert `lib/live-site.js`** to v4.4 (the previous CSS-fix version) via git revert
2. **SQL migration is safe to leave deployed** — only adds RPCs + 1 rate-limit table, doesn't change existing tables
3. If you need to remove the migration entirely:
   ```sql
   DROP FUNCTION IF EXISTS sbp_create_booking_public(text, jsonb, text);
   DROP FUNCTION IF EXISTS sbp_get_public_booking_form_config(text);
   DROP FUNCTION IF EXISTS sbp_get_public_room_types(text);
   DROP FUNCTION IF EXISTS sbp_get_public_services_for_booking(text);
   DROP TABLE IF EXISTS sbp_public_booking_attempts;
   ```

No customer bookings are lost — they're in the regular `sbp_bookings` table.
