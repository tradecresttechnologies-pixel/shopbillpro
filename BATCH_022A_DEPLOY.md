# Batch 022A — Dedicated Folio Page

**Date:** 9 May 2026
**Scope:** New page, new schema, new RPCs, small change to bookings.html.
**Closes:** the "folio-in-cramped-modal" UX problem you flagged.

---

## What this batch ships

### 1. `folio.html` — the centerpiece

A dedicated full-page folio management screen replacing the modal-inside-bookings approach. Two-column on desktop, vertical stack on mobile.

**Left column — the folio document itself:**
- **Guest header card** — colored avatar, name with foreign badge, contact + ID + passport pills, 5-cell stay grid (Room · Check-in · Check-out · Nights · Guests)
- **Line items table** — Description / Qty / Rate / Amount columns. Room nights row (with GST sub-row if applicable, gold-tinted background to distinguish from extras). Each extra row gets a category color tag (food=amber, laundry=blue, minibar=purple, service=green, etc.) and a `✕` delete button on hover.
- **Totals block** — Room subtotal / GST (with rate) / Extras subtotal / **Grand Total** (large amber) / − Paid / **Balance Due** (large rose if owed, green ✓ Clear if settled)

**Right column — the action workbench:**
- **Action toolbar** — Print Folio / WhatsApp (deep-link to wa.me/91...) / Check Out & Generate Bill (only when in-house+no bill yet, hands off to existing bookings.html flow) / View Bill (when settled)
- **Quick Add Extras** — 9 categorized tabs (All / Food / Laundry / Minibar / Service / Transport / Telephone / Spa / Other). Each catalog item is a tile with description + price; tap to add at default qty/rate. Hover to reveal ✎ edit button which opens a modal pre-filled with that catalog item, lets the operator override qty/rate before adding (for e.g. "Lunch but add 2 kids").
- **Custom extra** button — opens the same modal with blank fields, for one-off charges not in catalog.
- **Payments ledger** — every payment with mode icon (💵 Cash / 📱 UPI / 💳 Card / 🏦 Bank / 📝 Cheque / 📦 Other), amount in green, advance tag, voided tag, void button per row, timestamp + reference + note. Shows the legacy `advance_amount` from the booking row as a synthetic entry if no real payment row exists yet (backwards compatibility).
- **Record Payment** button — opens a modal with: amount field + 3 quick-fill buttons (= Balance Due / ½ Half / Full Total), payment mode picker (visual 6-tile grid), reference field, note field.

**Print mode:** A4 portrait. Hides all UI chrome (sidebar, topbar, action bar, quick-add panel, void buttons, sticky bar) and renders a clean register-style document with shop letterhead, guest section, line items table with black borders, totals block, signature footer (Guest / Cashier / Date+Stamp).

### 2. `db/migrations/028_folio_management.sql`

Two new tables, six new RPCs, one module profile flip, one seed block.

**Tables:**
- **`sbp_folio_extras_catalog`** — per-shop preset extras (category, description, default_qty, default_unit_price, display_order, active). Replaces "operator types every extra by hand" with one-tap quick-add.
- **`sbp_folio_payments`** — multi-payment ledger (amount, mode, reference, note, is_advance, is_voided, voided_at, voided_reason, recorded_at, recorded_by). Today the schema only tracks `advance_amount` as a single number on the booking row. Real hotels record multiple payments per stay (advance, partial mid-stay, final settle).

Both tables: full RLS policies (owner-scoped), proper indexes, foreign keys with ON DELETE CASCADE, CHECK constraints on enums.

**RPCs:**
- **`sbp_folio_get_full(shop_id, booking_id)`** → one round-trip jsonb envelope: `{ ok, booking, room, extras[], payments[], totals: { room_subtotal, gst_rate, gst_amount, extras_subtotal, grand_total, payments_total, balance_due, status } }`. Computes the folio status (open / open_inhouse / settled / settled_balance_due / voided) and the GST slab (₹0–1000 = 0%, ≤7500 = 5%, >7500 = 18%, post Sep-2025 reform).
- **`sbp_folio_payment_add(shop_id, booking_id, jsonb)`** → records a payment.
- **`sbp_folio_payment_void(shop_id, payment_id, reason)`** → soft-deletes via `is_voided=true`.
- **`sbp_folio_extras_catalog_list/_add/_remove`** → manage the catalog.

All RPCs check ownership via `sbp_check_hospitality_owner`. SECURITY DEFINER. Stable error codes.

**Catalog seed:** auto-populates a sensible 21-item starter catalog for every existing hospitality shop on migration run (Breakfast/Lunch/Dinner, Tea/Coffee, Water bottle 1L, Soft drink, Snack pack, 3 laundry items, Late check-out, Early check-in, Extra bed, Extra towel, Airport pickup/drop, Local sightseeing, STD/ISD calls, Body massage, Damage replacement). Only seeds if shop has zero rows — never overwrites customizations.

**Module profile:** adds `folio` to hospitality profile with `NEW` badge so it appears in the sidebar.

### 3. `lib/sidebar-engine.js` — catalog entry

Adds `folio` (📋) at order 165, between Rooms (160) and Bookings (170). This file is a superset of 021B-A + 021B-B (it already contains front_desk, walk_in, compliance) — push it as-is.

### 4. `bookings.html` — small mod

One-line addition: a prominent **"📋 Open Full Folio →"** button at the top of the existing action stack inside the booking detail modal. Doesn't remove anything; just gives operators a fast path to the new page. The existing modal stays functional for now (rip-out can come in a later batch once the new page is proven).

---

## Files in this batch (4)

```
db/migrations/028_folio_management.sql   ← NEW
folio.html                               ← NEW
lib/sidebar-engine.js                    ← edited (adds folio entry; superset of 021B-* versions)
bookings.html                            ← edited (1 button added at top of actions)
```

---

## Deploy order

### 1. SQL — Supabase SQL Editor
Run `028_folio_management.sql`. Idempotent. Creates 2 tables, 6 RPCs, seeds catalog, flips module profile.

### 2. Verify
```sql
-- Catalog seeded?
SELECT category, COUNT(*) FROM public.sbp_folio_extras_catalog
 WHERE shop_id = (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
 GROUP BY category ORDER BY 1;

-- Get a folio (use any recent booking id):
SELECT public.sbp_folio_get_full(
  (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
  (SELECT id FROM public.sbp_bookings ORDER BY created_at DESC LIMIT 1)
);
```

### 3. Frontend deploy
GitHub Desktop → push `folio.html`, `bookings.html`, `lib/sidebar-engine.js`, `db/migrations/028_folio_management.sql` → Vercel auto-deploys.

### 4. Bump SW
e.g. v1.5.15 → v1.5.16 so the new page caches on hard refresh.

### 5. End-to-end test
1. Sidebar should show **Folio** (📋) with NEW badge under hospitality menu, between Rooms and Bookings.
2. Open Bookings → tap any in-house booking → modal shows **📋 Open Full Folio →** as the first button (amber gradient).
3. Tap it → folio.html loads with that booking. Verify:
   - Topbar shows "FOLIO · #ABC12345" + status pill (In-House, amber)
   - Guest header card renders correctly
   - Line items shows the room night row with GST if applicable
   - Right column shows the seeded catalog (tap a tab — Food, Laundry, etc.)
   - Tap any catalog item → toast "✓ Added: …", folio refreshes, line item appears in the table, totals update
   - Tap ✎ on a catalog item → modal opens prefilled, change qty/rate → 💾 → added
   - Tap "Custom extra" → modal opens blank → enter "Bottle of wine" / Service / Qty 1 / Rate 800 → 💾 → added
   - Click "Record Payment" → modal opens with "= Balance Due" filled in if you tap that quick button → pick Cash → 💾 → toast "✓ Payment recorded · ₹X", payments ledger updates, balance due drops
   - Click ✕ on a payment row → confirms void → row strikes through, balance increases again
   - Click 🖨️ Print → A4 portrait print preview, no UI chrome, clean letterhead + guest header + line items table + totals block + signature footer
4. Click "✓ Check Out & Generate Bill" → hands off to bookings.html with the existing flow, generates the invoice
5. After bill generated: button changes to "🧾 View Bill" → goes to bills.html

---

## Design rationale

- **Why split desktop into 60/40?** The folio is the source of truth — it gets the larger column. Actions (add charges, record payments) are frequent but always in service of the folio, so they sit right alongside but don't dominate.
- **Why category colors on extras?** A glance-readable folio is critical when guests dispute charges. "That blue tag — laundry, ₹150" parses faster than reading every line.
- **Why advance shown as synthetic payment row?** Backwards-compat with 100+ existing bookings that have `advance_amount` set but no payments table row. They still display correctly without a data migration.
- **Why catalog rather than free-form?** Operators add the same 5–10 things 90% of the time. One-tap saves real seconds across hundreds of charges per week.
- **Why keep the bookings.html modal alive?** Risk reduction. Operators are trained on it. New folio page is opt-in via the prominent CTA. Once usage shifts, retire the modal in a separate small batch.

---

## Known gaps (deferred)

- **Audit log panel** — every charge add/remove and every payment add/void is timestamped + tagged with `recorded_by` in the schema, but the UI only surfaces this per-row right now (no consolidated audit log view). Add a "Audit log" expandable card on the right column in a follow-up.
- **Edit existing line items** — can only delete + re-add today. Edit in place is a v2 feature.
- **Per-night line items** — room shown as single row "X nights × ₹Y". The original 021C plan was to split into per-night `folio_room_lines`. Defer until operators actually ask for it (they likely won't for typical Indian hotel use).
- **PDF export** — Print works; native PDF download requires a server-side renderer. Browser "Save as PDF" via print dialog is the workaround for now.
- **WhatsApp folio sharing** — current button just opens wa.me/91... chat. Sending the actual folio PDF as a WA media message requires the WhatsApp Business API which is gated on Meta approval (already on roadmap, not blocking).
- **Discounts** — no discount line yet; can be added as a negative-amount custom extra for now.

---

## Rollback

- **SQL:** `DROP FUNCTION public.sbp_folio_get_full(uuid, uuid); DROP FUNCTION public.sbp_folio_payment_add(uuid, uuid, jsonb); DROP FUNCTION public.sbp_folio_payment_void(uuid, uuid, text); DROP FUNCTION public.sbp_folio_extras_catalog_list(uuid); DROP FUNCTION public.sbp_folio_extras_catalog_add(uuid, jsonb); DROP FUNCTION public.sbp_folio_extras_catalog_remove(uuid, uuid); DROP TABLE public.sbp_folio_payments; DROP TABLE public.sbp_folio_extras_catalog; DELETE FROM sbp_module_profiles WHERE module_code='folio';`
- **Frontend:** revert the commit via GitHub Desktop.

— TradeCrest Technologies Pvt. Ltd. · CIN U62099UP2026PTC247501
