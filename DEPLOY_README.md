# ShopBill Pro — Universal Service Catalog + Multi-Section Website

**Date:** May 5, 2026
**Migration:** `010_service_catalog.sql`
**Files in this batch (5):**

```
db/migrations/010_service_catalog.sql   [NEW]   ─── 1 table, 8 RPCs (7 admin + 1 public), RLS
lib/services.js                          [NEW]   ─── window.SBPServices client wrapper
services.html                            [NEW]   ─── admin CRUD page (mirrors stock.html style)
s.html                                   [PATCH] ─── PSP extended: about + services + gallery sections
settings.html                            [PATCH] ─── Service Catalog menu link + Website Content modal
```

---

## What this batch does

Closes ~30 verticals to 80%+ in one drop:

- **Beauty & Wellness** (9 types) — salon, spa, gym, yoga, tattoo, etc.
- **Healthcare** (7) — clinic, dentist, optician, vet, lab, physio, counselling
- **Education** (4) — tuition, music, driving school, coaching
- **Services / skilled labour** (11) — plumber, photographer, mover, tailor, pet groomer + 6 more

These all need a **service catalog** (vs a product catalog). Now they have one.

Bonus: **first API-first public storefront RPC.** `sbp_get_shop_services_public(slug)` is anon-callable — it's the foundation for the future public API surface (Phase 5 websites, AI builders, partner integrations).

---

## Spec (locked May 5, 2026)

- **Plan gating:** Pro / Business only. Free shops see "🔒 Upgrade to Pro" banner on `services.html`.
- **Cloud sync:** automatic via Supabase. localStorage cache keeps recent list available offline.
- **Public RPC return shape:** `{ok, error?, services: [{id, name, description, category, price, duration_minutes, image_url, display_order}]}` — public-safe columns only (no GST rates, no HSN codes exposed publicly).
- **Validation:** server-side. Client cannot pass invalid prices, empty names, or out-of-bounds GST rates.
- **Idempotency:** create assigns auto-incremented `display_order`. Update is a partial JSONB patch.
- **PSP rendering:** services auto-load from public RPC on `/s/[slug]`. Legacy `content.services` (array of strings in JSON) still works as fallback.

---

## API-first compliance check

This batch follows the locked rule (May 5, 2026): RPCs first, UI second. Every operation is a server-side RPC; the UI just calls them.

| Pattern | Compliance |
|---|---|
| Business logic in PLpgSQL RPCs (not JS) | ✅ All 7 admin RPCs + 1 public RPC |
| Server-side validation | ✅ Name length, price ≥ 0, ownership check |
| `{ok, error, ...}` jsonb envelope | ✅ Every RPC |
| `auth.uid()` ownership check | ✅ All admin RPCs |
| Idempotency on writes | ✅ Auto-order on create; patch on update |
| No localStorage/DOM deps in logic | ✅ All logic in SQL; client just renders |
| Stable error code strings | ✅ `not_owner`, `not_found`, `name_required`, `invalid_price`, `not_published` |

---

## Deploy Order

### 1. SQL — run in Supabase SQL Editor

```
audit_round_db_patch.sql       [already deployed]
admin_panel_full.sql           [already deployed]
003_business_categories.sql    [already deployed]
004_seo_admin.sql              [already deployed]
005_beta_logic.sql             [already deployed]
008_public_shop_page.sql       [already deployed]
009_loyalty.sql                [already deployed]
010_service_catalog.sql        ★ NEW — run this
```

Idempotent. Safe to re-run.

### 2. Files — push to GitHub repo

Replace / add at repo root:
- `db/migrations/010_service_catalog.sql` (new)
- `lib/services.js` (new)
- `services.html` (new)
- `s.html` (replace existing)
- `settings.html` (replace existing — has loyalty menu from previous batch + new Services + Website Content menu items)

Vercel auto-deploys on push (~30 sec). Both projects (marketing + app) update from the same `main` branch.

---

## Post-deploy verification (Supabase SQL Editor)

```sql
-- 1. Table + RLS
SELECT tablename, rowsecurity FROM pg_tables WHERE tablename = 'sbp_services';

-- 2. Functions exist
SELECT proname, prosecdef FROM pg_proc
WHERE proname LIKE 'sbp_services%' OR proname = 'sbp_get_shop_services_public';
-- Expected: 8 rows, all prosecdef=true

-- 3. Public RPC anon-callable (replace 'glitz-glam' with real slug)
SELECT sbp_get_shop_services_public('glitz-glam');
-- Expected: {"ok":true, "services":[]} initially

-- 4. Smoke create — replace UUID
SELECT sbp_services_create(
  'YOUR-SHOP-UUID',
  '{"name":"Hair Cut","price":300,"duration_minutes":30,"gst_rate":18,"category":"Hair"}'::jsonb
);
-- Expected: {"ok":true,"id":"<new-uuid>"}

-- 5. Verify it shows up publicly
SELECT sbp_get_shop_services_public('glitz-glam');
-- Expected: services array with the new service
```

---

## Testing the live UI

### A. Service catalog admin (Pro shop)
1. Login to a Pro/Business shop
2. Settings → "Service Catalog" menu (between Inventory & POS Admin)
3. Tap → opens services.html (CRUD page)
4. Tap "+" FAB → Add modal opens
5. Fill: Name "Hair Cut", Price 300, Duration 30, Category "Hair", GST 18%, Active checked
6. Save → service appears in list
7. Tap service → Edit modal opens with values pre-filled
8. Toggle the active switch → reflects immediately
9. Edit → modify price → Save → list updates

### B. Free shop (locked)
1. Login to Free shop
2. Settings → "Service Catalog" → opens services.html
3. Sees "🔒 Service Catalog is a Pro feature" banner with upgrade CTA
4. No Add button visible

### C. Website integration
1. On a Pro shop, add 3-4 services via services.html
2. Settings → "Website Content"
3. Fill About text + paste 3 image URLs in Gallery field
4. Save Content
5. Tap "Preview Live Page" → opens `/s/[slug]` in new tab
6. Should see: Hero (existing) → Quick Actions → About text → Services with prices/durations → Gallery grid → Business info → Powered-by footer

### D. Public RPC (manual test, no login needed)
1. Open browser, visit `https://app.shopbillpro.in/s/[your-slug]`
2. Wait ~1 second after page renders
3. The services section should populate from the public RPC call
4. Open DevTools → Network → filter "rpc" → confirm `sbp_get_shop_services_public` call returned 200

---

## Architecture notes

### Why `sbp_services` is separate from `products`
Products and services are different conceptually:
- **Products** have stock_qty, batch tracking, cost price (for COGS), barcode, photo per shop
- **Services** have duration_minutes, no stock, often no cost price

Same shop can have both (e.g., salon sells products AND services). When billing.html eventually integrates services into the cart (future batch), it'll pull from both `sbp_services` and `products` tables.

### Why the public RPC vs direct table access
PostgREST exposes every table as a REST endpoint by default. We could just enable anon SELECT on `sbp_services`. But:
- RPC lets us include only **public-safe columns** (no GST, no HSN, no internal IDs)
- RPC enforces the **published flag** at the view layer (private/draft websites don't leak services)
- RPC returns a stable shape — we can change underlying schema without breaking external callers
- Sets precedent for future public RPCs (orders, appointments, contact form)

This is the **first piece of API-first public surface**. When the public API gets formalized in Year 2, `sbp_get_shop_services_public` will be one of the documented endpoints.

---

## Known v2 follow-ups (deferred)

- [ ] **Billing integration** — billing.html doesn't yet let you add a service line directly from `sbp_services`. POS picker needs an item-source toggle: Products | Services | Both. ~2-3 hours.
- [ ] **Image upload** — currently URL-only field. Need Supabase Storage bucket + upload UI for shopkeeper-friendly photo handling.
- [ ] **Drag-drop reordering** — RPC is built (`sbp_services_reorder`), UI not yet. Currently uses display_order from creation time.
- [ ] **Loyalty bill-void hook** — still queued from previous batch.
- [ ] **Universal Appointments module** — schema for `sbp_appointments` + `sbp_appointment_slots` is the natural next batch. Will close salon/clinic/coaching to ~95%.
- [ ] **AI content generation** — Phase 5a (Month 5) will let shopkeepers click "Generate About text" from their service list.

---

## Schema reference

### Table: `sbp_services`

| Column | Type | Notes |
|---|---|---|
| id | uuid PK | gen_random_uuid() |
| shop_id | uuid FK | → shops(id) ON DELETE CASCADE |
| name | text NOT NULL | length > 0 |
| description | text | nullable |
| category | text | nullable, used for filtering |
| price | numeric | ≥ 0, default 0 |
| duration_minutes | int | nullable, ≥ 0 |
| gst_rate | numeric | 0-100, default 0 |
| hsn_sac_code | text | nullable |
| image_url | text | nullable |
| display_order | int | default 0, auto-incremented on create |
| active | boolean | default true |
| created_at, updated_at | timestamptz | auto-managed |

**Indexes:**
- `(shop_id, active, display_order) WHERE active = true` — primary public-read pattern
- `(shop_id, display_order)` — admin list
- `(shop_id, category)` — filter chips

**RLS:** owner-only (via `shops.owner_id = auth.uid()`). Public access ONLY through `sbp_get_shop_services_public(slug)` RPC.

### Public RPC: `sbp_get_shop_services_public(p_slug text) → jsonb`

**Inputs:** slug (text)
**Returns:**
```json
{
  "ok": true,
  "services": [
    {
      "id": "uuid",
      "name": "Hair Cut",
      "description": "30-minute haircut",
      "category": "Hair",
      "price": 300,
      "duration_minutes": 30,
      "image_url": "https://...",
      "display_order": 0
    }
  ]
}
```
**Errors:** `no_slug`, `not_found`, `not_published`

**Auth:** anon allowed (this is the API-first public endpoint).
**Behavior:** only returns active services for shops with `published = true`.

---

## Rollback (if needed)

The HTML files are pure replacements — restore from `git checkout`.

For SQL:

```sql
-- Drop functions (in dependency order)
DROP FUNCTION IF EXISTS sbp_get_shop_services_public(text);
DROP FUNCTION IF EXISTS sbp_services_list_admin(uuid);
DROP FUNCTION IF EXISTS sbp_services_reorder(uuid, uuid[]);
DROP FUNCTION IF EXISTS sbp_services_toggle_active(uuid);
DROP FUNCTION IF EXISTS sbp_services_delete(uuid);
DROP FUNCTION IF EXISTS sbp_services_update(uuid, jsonb);
DROP FUNCTION IF EXISTS sbp_services_create(uuid, jsonb);
DROP FUNCTION IF EXISTS sbp_services_set_updated_at();

-- Drop table (cascades indexes + RLS policies)
DROP TABLE IF EXISTS sbp_services;
```
