-- ════════════════════════════════════════════════════════════════════
-- 067_restaurant_fixes.sql
-- Closes 6 defects identified in the 15-May-26 restaurant vertical audit.
--
-- Defects closed:
--   #1 menu.html calls non-existent sbp_services_upsert       (showstopper S1)
--   #2 waiter menu picker strips gst_rate → 0% GST on bills   (showstopper S2)
--   #3 sbp_ro_void left pending KOTs cooking in KDS           (process gap P1)
--   #4 strand: closing billing tab left tables 'occupied'     (process gap P2)
--   #5 bill record had no link back to its table              (process gap P5)
--   #6 wrong sbp_module_profiles rows for half the food
--      sub-verticals (orphan inserts from migration 066)      (wiring bug W3)
--
-- Dependencies (must already be deployed):
--   003_business_categories.sql  — sbp_module_profiles, get_shop_modules
--   010_service_catalog.sql      — sbp_services + RPCs
--   061_pin_multiuser_fix.sql    — _sbp_check_shop_owner (owner OR active staff)
--   062_restaurant_tables.sql    — sbp_restaurant_tables
--   063_restaurant_orders.sql    — sbp_restaurant_orders (KDS)
--   065_running_orders.sql       — sbp_running_orders + 6 RPCs
--   066_menu_enhancements.sql    — sbp_services.is_available
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────
-- 1. sbp_services_upsert  — closes showstopper S1
-- ─────────────────────────────────────────────────────────────────
-- menu.html has been calling this RPC since batch 066 (3 call sites:
-- save, delete, toggleAvailability). It does not exist; Postgres
-- returns "function does not exist". Net effect: an owner cannot
-- add a single menu item from the UI.
-- This RPC routes to INSERT or UPDATE based on the presence of `id`.
-- Owner + active-staff allowed via _sbp_check_shop_owner (matches the
-- pattern used by every restaurant RPC since 062).
DROP FUNCTION IF EXISTS sbp_services_upsert(uuid, jsonb);
CREATE OR REPLACE FUNCTION sbp_services_upsert(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_id   uuid;
  v_row  sbp_services%ROWTYPE;
  v_name text;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  v_name := trim(coalesce(p_data->>'name', ''));
  IF length(v_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_required');
  END IF;

  v_id := NULLIF(p_data->>'id', '')::uuid;

  IF v_id IS NULL THEN
    -- INSERT new menu item
    INSERT INTO sbp_services (
      shop_id, name, description, category, price, gst_rate,
      hsn_sac_code, image_url, duration_minutes, is_available,
      active, display_order
    ) VALUES (
      p_shop_id,
      v_name,
      NULLIF(p_data->>'description', ''),
      NULLIF(p_data->>'category', ''),
      COALESCE((p_data->>'price')::numeric, 0),
      COALESCE((p_data->>'gst_rate')::numeric, 0),
      NULLIF(p_data->>'hsn_sac_code', ''),
      NULLIF(p_data->>'image_url', ''),
      COALESCE((p_data->>'duration_minutes')::int, 0),
      COALESCE((p_data->>'is_available')::boolean, true),
      COALESCE((p_data->>'active')::boolean, true),
      COALESCE((p_data->>'display_order')::int, 0)
    ) RETURNING * INTO v_row;
  ELSE
    -- UPDATE existing item. COALESCE keeps unchanged fields; explicit
    -- nulls in payload are preserved (NULLIF on empty string sentinels).
    UPDATE sbp_services SET
      name             = v_name,
      description      = COALESCE(NULLIF(p_data->>'description',''),       description),
      category         = COALESCE(NULLIF(p_data->>'category',''),          category),
      price            = COALESCE((p_data->>'price')::numeric,             price),
      gst_rate         = COALESCE((p_data->>'gst_rate')::numeric,          gst_rate),
      hsn_sac_code     = COALESCE(NULLIF(p_data->>'hsn_sac_code',''),      hsn_sac_code),
      image_url        = COALESCE(NULLIF(p_data->>'image_url',''),         image_url),
      duration_minutes = COALESCE((p_data->>'duration_minutes')::int,      duration_minutes),
      is_available     = COALESCE((p_data->>'is_available')::boolean,      is_available),
      active           = COALESCE((p_data->>'active')::boolean,            active),
      display_order    = COALESCE((p_data->>'display_order')::int,         display_order),
      updated_at       = now()
    WHERE id = v_id AND shop_id = p_shop_id
    RETURNING * INTO v_row;

    IF v_row.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'service_not_found');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'service', to_jsonb(v_row));
END; $$;

GRANT EXECUTE ON FUNCTION sbp_services_upsert(uuid, jsonb) TO authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 2. sbp_get_menu_for_pos  — closes showstopper S2
-- ─────────────────────────────────────────────────────────────────
-- running-order.html has been loading its menu via sbp_get_shop_services_public
-- which intentionally strips gst_rate, hsn_sac_code and is_available
-- (it's the anonymous storefront RPC for /s/<slug>). Result:
-- (a) every dine-in bill came out at 0% GST — direct GSTR-1 violation,
-- (b) 86'd items still appeared in the waiter's picker.
-- This RPC is the proper authenticated POS-side menu loader.
DROP FUNCTION IF EXISTS sbp_get_menu_for_pos(uuid);
CREATE OR REPLACE FUNCTION sbp_get_menu_for_pos(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'services', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',            s.id,
          'name',          s.name,
          'description',   s.description,
          'category',      s.category,
          'price',         s.price,
          'gst_rate',      s.gst_rate,
          'hsn_sac_code',  s.hsn_sac_code,
          'image_url',     s.image_url,
          'is_available',  s.is_available,
          'display_order', s.display_order
        )
        ORDER BY s.display_order ASC, s.name ASC
      )
      FROM sbp_services s
      WHERE s.shop_id = p_shop_id
        AND s.active  = true
    ), '[]'::jsonb)
  );
END; $$;

GRANT EXECUTE ON FUNCTION sbp_get_menu_for_pos(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 3. sbp_ro_void  — patched, closes process gap P1
-- ─────────────────────────────────────────────────────────────────
-- BEFORE: voiding a running order only flipped sbp_running_orders.status
-- to 'void' and freed the table. Per-round KOT rows in sbp_restaurant_orders
-- stayed at status='pending' — the kitchen continued to cook them.
-- AFTER: also cancels every pending/in_progress KDS row that belongs to
-- this table-session (matched by shop_id + table_number + opened_at).
DROP FUNCTION IF EXISTS sbp_ro_void(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_ro_void(p_shop_id uuid, p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_row        sbp_running_orders%ROWTYPE;
  v_cancelled  int := 0;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_row
  FROM sbp_running_orders
  WHERE id = p_order_id AND shop_id = p_shop_id;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Void the running order
  UPDATE sbp_running_orders
  SET status = 'void', updated_at = now()
  WHERE id = p_order_id;

  -- Free the table
  IF v_row.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status = 'free', current_bill_id = null, updated_at = now()
    WHERE id = v_row.table_id AND shop_id = p_shop_id;
  END IF;

  -- Cancel related KOTs that are still active. Window: from opened_at
  -- forward. Same shop + same table_number. Won't touch bills already
  -- saved against the table.
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='sbp_restaurant_orders') THEN
    UPDATE sbp_restaurant_orders
    SET status     = 'cancelled',
        updated_at = now()
    WHERE shop_id      = p_shop_id
      AND table_number = v_row.table_number
      AND created_at   >= v_row.opened_at
      AND status       IN ('pending','in_progress');
    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object('ok', true, 'cancelled_kots', v_cancelled);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_void(uuid, uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 4. sbp_ro_generate_bill  — patched, closes process gap P2 properly
-- ─────────────────────────────────────────────────────────────────
-- BEFORE: running-order.html called sbp_ro_generate_bill(shop, order)
-- which flipped status to 'billed' BEFORE any bill was actually saved.
-- If the waiter closed the billing tab, the running order was stuck at
-- 'billed' with no real bill ever saved. Next tap on the table created
-- a fresh RO; the original items + KOTs were orphaned.
--
-- AFTER: a new optional 3rd argument p_bill_id moves the state
-- transition to billing.html's save path:
--   • running-order.html (UI patched in this batch) now uses
--     sbp_ro_get_by_id (read-only) → RO stays 'open'.
--   • billing.html save handler calls sbp_ro_generate_bill(shop, order,
--     bill_id) once the bill is committed → status flips to 'billed'
--     AND bill_id is stamped.
--   • Closing the billing tab leaves the RO at 'open' — existing
--     resume-on-tap logic in sbp_ro_open handles it correctly.
--
-- Signature compatibility:
--   The 3rd arg has DEFAULT NULL so old cached running-order pages
--   that still call the 2-arg form will continue to resolve to this
--   function (with bill_id NULL). They retain the original "mark
--   billed without bill_id" behaviour — broken, but matching legacy.
--   Once caches refresh and the new running-order.html lands, that
--   path is no longer used.
DROP FUNCTION IF EXISTS sbp_ro_generate_bill(uuid, uuid);
DROP FUNCTION IF EXISTS sbp_ro_generate_bill(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_ro_generate_bill(
  p_shop_id  uuid,
  p_order_id uuid,
  p_bill_id  uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_row sbp_running_orders%ROWTYPE;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  -- Match status 'open' OR 'billed-without-bill'. Once a real bill is
  -- attached (bill_id IS NOT NULL), this RO is closed and re-calling
  -- generate_bill is a no-op error to surface programmer mistakes.
  SELECT * INTO v_row
  FROM sbp_running_orders
  WHERE id = p_order_id AND shop_id = p_shop_id
    AND (status = 'open' OR (status = 'billed' AND bill_id IS NULL));

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found_or_already_billed');
  END IF;

  IF jsonb_array_length(v_row.items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_items_to_bill');
  END IF;

  -- Stamp bill_id only when supplied (i.e. coming from billing.html save).
  -- A NULL bill_id leaves the column untouched on UPDATE.
  UPDATE sbp_running_orders
  SET status     = 'billed',
      bill_id    = COALESCE(p_bill_id, bill_id),
      billed_at  = COALESCE(billed_at, now()),
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok',           true,
    'items',        v_row.items,
    'table_number', v_row.table_number,
    'table_id',     v_row.table_id,
    'order_id',     v_row.id,
    'kot_count',    v_row.kot_count,
    'bill_id',      v_row.bill_id
  );
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_generate_bill(uuid, uuid, uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 5. bills: add table_number + table_session_id  — closes P5
-- ─────────────────────────────────────────────────────────────────
-- BEFORE: a saved bill had no idea which table it came from. Reports
-- couldn't break revenue down per table; bills.html showed dine-in
-- bills with no table indicator. The only link was a fragile reverse
-- lookup via sbp_restaurant_tables.current_bill_id (overwritten when
-- the table is freed) or sbp_running_orders.bill_id (only set on
-- generate_bill).
-- AFTER: every dine-in bill carries the human table number AND a FK
-- to the running-order session that produced it.
ALTER TABLE bills
  ADD COLUMN IF NOT EXISTS table_number     text,
  ADD COLUMN IF NOT EXISTS table_session_id uuid;

-- Indexes for the two report patterns:
--   • "all bills for session X"            → idx_bills_table_session
--   • "bills for table T1 in last 30 days" → idx_bills_table_number
CREATE INDEX IF NOT EXISTS idx_bills_table_session
  ON bills(shop_id, table_session_id)
  WHERE table_session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_bills_table_number
  ON bills(shop_id, table_number, created_at DESC)
  WHERE table_number IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────
-- 6. sbp_module_profiles cleanup  — closes wiring bug W3
-- ─────────────────────────────────────────────────────────────────
-- Migration 066 inserted rows like ('cafe','menu','active') — but
-- 'cafe' is a shop_type code, not a module_profile value. The shop_type
-- 'cafe' resolves to profile='restaurant' via sbp_business_categories.
-- Those 066 rows are orphans that get_shop_modules() never reads.
--
-- Meanwhile the real 'food' profile (resolved from shop_type ice_cream,
-- catering, food_other) only had online_orders. Tables / Kitchen /
-- Menu / QR Menu were invisible for those shops. Tiffin (profile=
-- 'subscription') had nothing food-related at all.

-- Drop the orphan rows from 066. ON CONFLICT in 066 only updated; if
-- the row genuinely didn't exist before 066, it's a 066 insert with
-- no matching shop_type → safe to delete.
DELETE FROM sbp_module_profiles
WHERE profile IN ('cafe','qsr','cloud_kitchen','bar_lounge','dhaba',
                  'food_other','tiffin','catering','ice_cream')
  AND module_code = 'menu';

-- Add proper rows to the 'food' profile (covers ice_cream, catering,
-- food_other shop_types). Tables/Kitchen reasonable because even
-- ice-cream parlours with seating + cake shops with prep stations
-- benefit from those modules.
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('food', 'menu',    'active', NULL, 15),
  ('food', 'tables',  'active', NULL, 25),
  ('food', 'kitchen', 'active', NULL, 28),
  ('food', 'qr_menu', 'active', NULL, 42)
ON CONFLICT (profile, module_code) DO UPDATE
  SET status = 'active', badge = NULL;

-- Tiffin shops resolve to profile='subscription'. They prep at one
-- location and deliver — they need Menu, not Tables / Kitchen.
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('subscription', 'menu', 'active', NULL, 15)
ON CONFLICT (profile, module_code) DO UPDATE
  SET status = 'active', badge = NULL;


NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify (run in Supabase SQL Editor):
--
-- -- New + patched RPCs exist
-- SELECT routine_name FROM information_schema.routines
-- WHERE routine_schema = 'public'
--   AND routine_name IN ('sbp_services_upsert','sbp_get_menu_for_pos',
--                        'sbp_ro_void','sbp_ro_open');
-- -- expect 4 rows
--
-- -- bills has the new columns
-- SELECT column_name, data_type FROM information_schema.columns
-- WHERE table_name='bills'
--   AND column_name IN ('table_number','table_session_id');
-- -- expect 2 rows: text, uuid
--
-- -- food + subscription profiles have the right module rows
-- SELECT profile, module_code, status
-- FROM sbp_module_profiles
-- WHERE module_code IN ('menu','tables','kitchen','qr_menu')
--   AND profile IN ('food','subscription','restaurant')
-- ORDER BY profile, module_code;
-- -- expect: food=4 rows, restaurant=4 rows, subscription=1 row
--
-- -- Orphan rows from 066 are gone
-- SELECT count(*) FROM sbp_module_profiles
-- WHERE profile IN ('cafe','qsr','cloud_kitchen','bar_lounge',
--                   'dhaba','food_other','tiffin','catering','ice_cream');
-- -- expect 0
-- ════════════════════════════════════════════════════════════════════
