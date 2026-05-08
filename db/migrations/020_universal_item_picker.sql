-- ════════════════════════════════════════════════════════════════════
-- 020_universal_item_picker.sql
-- Batch 019 — Universal Item Picker (8 May 2026)
--
-- Extends bill_items with `kind` + foreign-key columns so a single bill
-- can carry mixed-type lines: products, services, rooms.
--
-- Adds RPC sbp_picker_search() — unified search across products + services
-- + room_types, returning a JSON array filtered by shop_type rules.
--
-- BACKWARDS COMPATIBLE: existing bills are backfilled with kind='product'.
-- All new columns are nullable except `kind` (which has a default).
--
-- Idempotent: safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- 1. Extend bill_items table
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE bill_items
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'product';

ALTER TABLE bill_items
  ADD CONSTRAINT bill_items_kind_check
  CHECK (kind IN ('product', 'service', 'room'))
  NOT VALID;
-- NOT VALID skips check on existing rows (already 'product' from default)
-- New rows still validated.

ALTER TABLE bill_items VALIDATE CONSTRAINT bill_items_kind_check;

ALTER TABLE bill_items
  ADD COLUMN IF NOT EXISTS service_id uuid;
ALTER TABLE bill_items
  ADD COLUMN IF NOT EXISTS room_type_id uuid;
ALTER TABLE bill_items
  ADD COLUMN IF NOT EXISTS room_id uuid;
ALTER TABLE bill_items
  ADD COLUMN IF NOT EXISTS booking_id uuid;
ALTER TABLE bill_items
  ADD COLUMN IF NOT EXISTS unit text;
ALTER TABLE bill_items
  ADD COLUMN IF NOT EXISTS qty_unit_label text;
-- e.g. "3 nights", "2 sessions", "1 hour"

-- Backfill: any existing rows are products (this is a no-op since
-- the default value 'product' was used at column creation, but we
-- guarantee idempotency)
UPDATE bill_items
SET kind = 'product'
WHERE kind IS NULL OR kind = '';

-- Indexes for the new search columns
CREATE INDEX IF NOT EXISTS idx_bill_items_kind
  ON bill_items(kind);
CREATE INDEX IF NOT EXISTS idx_bill_items_service
  ON bill_items(service_id) WHERE service_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bill_items_room_type
  ON bill_items(room_type_id) WHERE room_type_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bill_items_booking
  ON bill_items(booking_id) WHERE booking_id IS NOT NULL;

COMMENT ON COLUMN bill_items.kind IS
  'product | service | room — what the line item represents';
COMMENT ON COLUMN bill_items.service_id IS
  'FK to sbp_services.id when kind=service (no DB-level FK to allow soft deletes)';
COMMENT ON COLUMN bill_items.room_type_id IS
  'FK to sbp_room_types.id when kind=room';
COMMENT ON COLUMN bill_items.unit IS
  'piece | kg | hour | night | session — display unit for qty';

-- ──────────────────────────────────────────────────────────────────
-- 2. shop_type → allowed kinds mapping
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_picker_kinds_for_shop_type(p_shop_type text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE LOWER(COALESCE(p_shop_type, ''))
    -- Pure-product shops
    WHEN 'general_retail'    THEN ARRAY['product']
    WHEN 'kirana'            THEN ARRAY['product']
    WHEN 'grocery'           THEN ARRAY['product']
    WHEN 'wholesale'         THEN ARRAY['product']
    WHEN 'online_brand'      THEN ARRAY['product']
    WHEN 'd2c'               THEN ARRAY['product']
    WHEN 'pharmacy'          THEN ARRAY['product']
    WHEN 'restaurant'        THEN ARRAY['product']
    WHEN 'cafe'              THEN ARRAY['product']

    -- Service-led shops (still useful to sell products too — combos, retail)
    WHEN 'salon'             THEN ARRAY['service','product']
    WHEN 'spa'               THEN ARRAY['service','product']
    WHEN 'salon_wellness'    THEN ARRAY['service','product']
    WHEN 'services'          THEN ARRAY['service']
    WHEN 'plumber'           THEN ARRAY['service']
    WHEN 'photographer'      THEN ARRAY['service']
    WHEN 'tailor'            THEN ARRAY['service']

    -- Healthcare: consultation + medicines
    WHEN 'healthcare'        THEN ARRAY['service','product']
    WHEN 'clinic'            THEN ARRAY['service','product']

    -- Education: course/exam fees
    WHEN 'education'         THEN ARRAY['service']
    WHEN 'coaching'          THEN ARRAY['service']

    -- Hospitality: rooms + services + products (minibar, F&B)
    WHEN 'hotel'             THEN ARRAY['room','service','product']
    WHEN 'resort'            THEN ARRAY['room','service','product']
    WHEN 'guesthouse'        THEN ARRAY['room','service','product']
    WHEN 'service_apartment' THEN ARRAY['room','service','product']
    WHEN 'boutique_hotel'    THEN ARRAY['room','service','product']
    WHEN 'hostel'            THEN ARRAY['room']
    WHEN 'dharamshala'       THEN ARRAY['room']
    WHEN 'day_room'          THEN ARRAY['room']
    WHEN 'camping'           THEN ARRAY['room','service']

    -- Default: products only (safest fallback)
    ELSE ARRAY['product']
  END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_picker_kinds_for_shop_type(text) TO authenticated, anon;

-- ──────────────────────────────────────────────────────────────────
-- 3. RPC: sbp_picker_search(shop_id, query, kinds)
--   Returns merged list of products + services + room_types
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_picker_search(
  p_shop_id uuid,
  p_query   text DEFAULT NULL,
  p_kinds   text[] DEFAULT NULL,
  p_limit   int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shop_type text;
  v_allowed_kinds text[];
  v_query_lc  text;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
BEGIN
  IF p_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_id_required');
  END IF;

  -- Determine which kinds to search
  IF p_kinds IS NULL OR array_length(p_kinds, 1) = 0 THEN
    SELECT shop_type INTO v_shop_type FROM shops WHERE id = p_shop_id;
    v_allowed_kinds := sbp_picker_kinds_for_shop_type(v_shop_type);
  ELSE
    v_allowed_kinds := p_kinds;
  END IF;

  v_query_lc := lower(trim(COALESCE(p_query, '')));

  -- ── Products ────────────────────────────────────────────────
  IF 'product' = ANY(v_allowed_kinds) THEN
    FOR v_row IN
      SELECT jsonb_build_object(
        'kind',      'product',
        'id',        p.id,
        'name',      p.name,
        'code',      p.code,
        'category',  p.category,
        'rate',      p.price,
        'cost',      p.cost_price,
        'gst_rate',  p.gst_rate,
        'unit',      COALESCE(p.unit, 'piece'),
        'stock_qty', p.stock_qty,
        'emoji',     COALESCE(p.emoji, '📦'),
        'image_url', NULL,
        'sub',       p.sub_category
      )
      FROM products p
      WHERE p.shop_id = p_shop_id
        AND (
          v_query_lc = '' OR
          lower(p.name)         LIKE '%' || v_query_lc || '%' OR
          lower(COALESCE(p.code,'')) LIKE '%' || v_query_lc || '%' OR
          lower(COALESCE(p.category,'')) LIKE '%' || v_query_lc || '%'
        )
      ORDER BY p.name
      LIMIT p_limit
    LOOP
      v_results := v_results || v_row;
    END LOOP;
  END IF;

  -- ── Services ────────────────────────────────────────────────
  IF 'service' = ANY(v_allowed_kinds) THEN
    FOR v_row IN
      SELECT jsonb_build_object(
        'kind',      'service',
        'id',        s.id,
        'name',      s.name,
        'code',      s.hsn_sac_code,
        'category',  s.category,
        'rate',      s.price,
        'cost',      0,
        'gst_rate',  s.gst_rate,
        'unit',      CASE WHEN s.duration_minutes IS NOT NULL THEN 'session' ELSE 'service' END,
        'duration',  s.duration_minutes,
        'stock_qty', NULL,
        'emoji',     '✂️',
        'image_url', s.image_url,
        'description', s.description
      )
      FROM sbp_services s
      WHERE s.shop_id = p_shop_id
        AND s.active = true
        AND (
          v_query_lc = '' OR
          lower(s.name) LIKE '%' || v_query_lc || '%' OR
          lower(COALESCE(s.category,'')) LIKE '%' || v_query_lc || '%'
        )
      ORDER BY s.display_order, s.name
      LIMIT p_limit
    LOOP
      v_results := v_results || v_row;
    END LOOP;
  END IF;

  -- ── Room Types ──────────────────────────────────────────────
  IF 'room' = ANY(v_allowed_kinds) THEN
    -- Only proceed if sbp_room_types exists (hospitality migration may not be deployed)
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = 'sbp_room_types'
    ) THEN
      FOR v_row IN
        SELECT jsonb_build_object(
          'kind',          'room',
          'id',            rt.id,
          'name',          rt.name,
          'code',          NULL,
          'category',      'Rooms',
          'rate',          rt.base_price,
          'weekend_rate',  rt.weekend_price,
          'cost',          0,
          'gst_rate',      12,                       -- default hotel GST 12%
          'unit',          'night',
          'capacity',      rt.capacity_adults + rt.capacity_children,
          'amenities',     rt.amenities,
          'stock_qty',     NULL,
          'emoji',         '🛏️',
          'image_url',     NULL,
          'description',   rt.description
        )
        FROM sbp_room_types rt
        WHERE rt.shop_id = p_shop_id
          AND rt.active = true
          AND (
            v_query_lc = '' OR
            lower(rt.name)  LIKE '%' || v_query_lc || '%'
          )
        ORDER BY rt.display_order, rt.name
        LIMIT p_limit
      LOOP
        v_results := v_results || v_row;
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',     true,
    'kinds',  to_jsonb(v_allowed_kinds),
    'count',  jsonb_array_length(v_results),
    'items',  v_results
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_picker_search(uuid, text, text[], int) TO authenticated, anon;

-- ──────────────────────────────────────────────────────────────────
-- 4. Verification queries
-- ──────────────────────────────────────────────────────────────────

-- (1) Confirm new columns exist:
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'bill_items' AND column_name IN
--     ('kind','service_id','room_type_id','room_id','booking_id','unit','qty_unit_label');
--   Expected: 7 rows.
--
-- (2) Confirm backfill completed:
--   SELECT kind, COUNT(*) FROM bill_items GROUP BY kind;
--   Expected: only 'product' (until you create service/room bills).
--
-- (3) Test kind mapping:
--   SELECT public.sbp_picker_kinds_for_shop_type('hotel');     -- {room,service,product}
--   SELECT public.sbp_picker_kinds_for_shop_type('kirana');    -- {product}
--   SELECT public.sbp_picker_kinds_for_shop_type('salon');     -- {service,product}
--
-- (4) Test the unified search RPC (replace SHOP_UUID with a real shop id):
--   SELECT public.sbp_picker_search(
--     'YOUR_SHOP_UUID_HERE'::uuid,
--     '',
--     NULL,    -- auto-detect kinds from shop_type
--     20
--   );

-- ──────────────────────── End of 020_universal_item_picker.sql ────────────────────────
