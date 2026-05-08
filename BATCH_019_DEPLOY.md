# BATCH 019 — Universal Item Picker

**Date:** 8 May 2026
**Migration #:** 020_universal_item_picker.sql
**Status:** Ready to deploy
**Scope:** One picker for products + services + rooms · mixed-type bills · stock-deduction skipped for non-products · kind badges in bill view

---

## What this batch ships

**The change:** A single bill can now contain any mix of products, services, and room nights. The picker is shop-type-aware — kirana shops see only products, salons see services + products, hotels see rooms + services + products.

**Files:**
```
batch019/
├── BATCH_019_DEPLOY.md
├── db/migrations/
│   └── 020_universal_item_picker.sql      ← run FIRST in Supabase SQL Editor
├── lib/
│   └── item-picker.js                     ← NEW lib (no replacement)
├── billing.html                           ← patched (Browse Catalogue button + persistence)
└── bills.html                             ← patched (kind badges in item rows)
```

---

## What it does

1. **`bill_items` table extended** with: `kind` (product/service/room), `service_id`, `room_type_id`, `room_id`, `booking_id`, `unit`, `qty_unit_label`. Existing rows backfilled to `kind='product'`. **No data loss.**

2. **New RPC `sbp_picker_search(shop_id, query, kinds, limit)`** — unified search across `products` + `sbp_services` + `sbp_room_types`. Auto-detects allowed kinds based on `shops.shop_type` if `kinds` is null.

3. **Helper RPC `sbp_picker_kinds_for_shop_type(shop_type)`** — returns the array of allowed kinds for a given shop type. The mapping:
   - `general_retail`, `kirana`, `grocery`, `wholesale`, `online_brand`, `pharmacy`, `restaurant`, `cafe` → product only
   - `salon`, `spa`, `salon_wellness` → service + product
   - `services`, `plumber`, `photographer`, `tailor` → service only
   - `healthcare`, `clinic` → service + product
   - `education`, `coaching` → service only
   - `hotel`, `resort`, `guesthouse`, `service_apartment`, `boutique_hotel` → room + service + product
   - `hostel`, `dharamshala`, `day_room` → room only
   - `camping` → room + service

4. **`lib/item-picker.js`** — modal UI with search bar, tabs per kind, scrollable card grid. Caches results in sessionStorage for 60 seconds. Auto-creates Supabase client if global isn't present.

5. **`billing.html` Manual mode** — new "📚 Browse Catalogue" button next to "+ Add Item / Service". Clicking opens the picker. On select, prefills a row with `data-kind` + `data-*-id` attributes. For rooms, prompts "Number of nights?" up front.

6. **Persistence** — all 4 `bill_items.insert` call sites updated to pass `kind`, `product_id`, `service_id`, `room_type_id`, `unit`, `qty_unit_label` into the DB.

7. **Stock deduction skips non-products** — `if((it.kind || 'product') !== 'product') continue;` so services and rooms don't accidentally try to deduct from `products.stock_qty`.

8. **`bills.html`** — bill detail view shows kind badges (✂️ Service, 🛏️ Room) next to the item name. Quantity rendered with unit-aware label ("3 nights" instead of "Qty: 3").

---

## Deploy steps

### Step 1 — Database migration

Open Supabase SQL Editor → New Query → paste contents of `db/migrations/020_universal_item_picker.sql` → Run.

**Verification queries:**

```sql
-- 1. New columns exist on bill_items
SELECT column_name FROM information_schema.columns
WHERE table_name = 'bill_items'
  AND column_name IN ('kind','service_id','room_type_id','room_id','booking_id','unit','qty_unit_label');
-- Expected: 7 rows.

-- 2. Existing bills backfilled
SELECT kind, COUNT(*) FROM bill_items GROUP BY kind;
-- Expected: only 'product' (since no service/room bills yet).

-- 3. Kind mapping works
SELECT public.sbp_picker_kinds_for_shop_type('hotel');     -- should return {room,service,product}
SELECT public.sbp_picker_kinds_for_shop_type('kirana');    -- should return {product}
SELECT public.sbp_picker_kinds_for_shop_type('salon');     -- should return {service,product}

-- 4. Picker search RPC works (replace SHOP_UUID)
SELECT public.sbp_picker_search(
  (SELECT id FROM shops LIMIT 1)::uuid,
  '',
  NULL,
  20
);
-- Expected: { ok:true, kinds:[...], count:N, items:[...] }
```

If any verification fails, share the error — likely a missing prereq (010 service catalog or 015 hospitality not deployed).

### Step 2 — Deploy code

Push these files to repo (overwrite where applicable):

| From zip | To repo |
|---|---|
| `lib/item-picker.js` | `/lib/item-picker.js` (new) |
| `billing.html` | `/billing.html` (overwrites) |
| `bills.html` | `/bills.html` (overwrites) |

Commit message:
```
Batch 019: universal item picker — products + services + rooms in one
picker, mixed-kind bills, stock deduction skipped for non-products,
kind badges in bill view
```

Vercel auto-deploys.

### Step 3 — Smoke tests

Run through these in order on production:

#### Test A — Picker UI loads on a kirana shop
1. Log in as a `general_retail` / `kirana` shop (or any product-only shop)
2. Go to Billing → Manual mode
3. Click **"📚 Browse Catalogue"**
4. Picker opens with **only "Products" tab visible** (no Services/Rooms tabs)
5. Tap any product → row prefilled with name/rate/GST
6. Save bill → check Bills page → item shows without any kind badge (since kind='product' is default, no badge)

#### Test B — Mixed bill on a hotel shop
1. Log in as a `hotel` / `resort` shop
2. Pre-req: ensure you've added at least one room type (via `/rooms.html`) and one service (via `/services.html`)
3. Go to Billing → Manual mode
4. Click **"📚 Browse Catalogue"** → see 4 tabs (✨ All / 📦 Products / ✂️ Services / 🛏️ Rooms)
5. Pick a room → prompt asks "Number of nights?" → enter 3 → row added with rate × 3
6. Click Browse again → pick a service → row added
7. (Optional) Click Browse again → pick a product → row added
8. Save bill → check Bills page
9. Bill detail view should show: room with 🛏️ Room badge + "3 nights" label, service with ✂️ Service badge, product with no badge

#### Test C — Stock deduction skipped for services
1. On a salon shop, create a bill with one service + one product
2. Save → verify product stock decreased by 1, but the service did not affect any stock counter

#### Test D — Picker search works
1. Open picker → type a search term that matches a product name → results filter
2. Switch tabs → results re-filter to that kind
3. Empty search → all items show

---

## Rollback plan

If anything goes wrong:

1. **Database:** the migration only ADDS columns and RPCs — safe to keep. To roll back fully:
   ```sql
   DROP FUNCTION IF EXISTS sbp_picker_search(uuid, text, text[], int);
   DROP FUNCTION IF EXISTS sbp_picker_kinds_for_shop_type(text);
   ALTER TABLE bill_items DROP COLUMN IF EXISTS kind;
   ALTER TABLE bill_items DROP COLUMN IF EXISTS service_id;
   ALTER TABLE bill_items DROP COLUMN IF EXISTS room_type_id;
   ALTER TABLE bill_items DROP COLUMN IF EXISTS room_id;
   ALTER TABLE bill_items DROP COLUMN IF EXISTS booking_id;
   ALTER TABLE bill_items DROP COLUMN IF EXISTS unit;
   ALTER TABLE bill_items DROP COLUMN IF EXISTS qty_unit_label;
   ```
2. **Code:** `git revert` the deploy commit. Existing bills are unaffected (backfill is idempotent).

---

## Known carryover items (not in scope)

- **POS mode** still uses its own product-only catalogue (the existing `_posItems` flow). The picker is currently wired into Manual mode only. POS-mode integration is reasonable to defer because POS already has a fast typeahead. We can add a "Browse" button to POS in a follow-up if you want services/rooms there too.
- **Room booking → folio link.** When a hotel creates a booking, it already lands the room as a bill line via the `booking_id` URL flow (Batch 015). Picker doesn't break that flow; you can still add extras from the picker to a booking-prefilled bill. Cleaner integration (auto-link booking_id on each room line) can come in Batch 021 (Hotel polish).
- **Bill print template** doesn't yet show the kind badges visually (only the bill detail view in app does). Print template polish can come with Batch 020 (Reports Engine) or 021.
- **Loyalty earnings on services/rooms** — current loyalty rules treat the bill grand_total uniformly. No change needed; works as-is.

---

## Acceptance criteria

✅ Migration runs without error
✅ Test A passes (kirana sees products only)
✅ Test B passes (hotel can mix room + service + product)
✅ Test C passes (stock not deducted for services)
✅ Test D passes (search filters correctly)
✅ Existing bills (those created before this batch) still display correctly without kind badges

If any fail → share DevTools console screenshot, and I'll hotfix.

---

**Built by Claude · Batch 019 · 8 May 2026 · ShopBill Pro · TradeCrest Technologies Pvt. Ltd.**
