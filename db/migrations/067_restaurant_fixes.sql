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


-- ─────────────────────────────────────────────────────────────────
-- 7. sbp_ro_add_items  — patched, stamps stable item_id
-- ─────────────────────────────────────────────────────────────────
-- BEFORE: items in sbp_running_orders.items only carried a `round` tag —
-- no stable per-item identifier. Made it impossible to void/cancel a
-- single line item once sent to the kitchen; only whole-order void
-- worked.
-- AFTER: each item is stamped with `item_id` (uuid generated server-side)
-- + `voided:false` baseline + `notes` passthrough. The RPC's signature is
-- unchanged, so the UI keeps calling it the same way; the new fields are
-- additive in jsonb. Old items already in the array stay as-is (legacy
-- void-whole-order is still available for them).
DROP FUNCTION IF EXISTS sbp_ro_add_items(uuid, uuid, jsonb, text);
CREATE OR REPLACE FUNCTION sbp_ro_add_items(
  p_shop_id  uuid,
  p_order_id uuid,
  p_items    jsonb,
  p_notes    text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_row       sbp_running_orders%ROWTYPE;
  v_kot_n     int;
  v_new_kot   jsonb;
  v_stamped   jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_row
  FROM sbp_running_orders
  WHERE id = p_order_id AND shop_id = p_shop_id AND status = 'open';

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found_or_closed');
  END IF;

  IF coalesce(jsonb_array_length(p_items), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_items');
  END IF;

  v_kot_n := v_row.kot_count + 1;

  -- Stamp each item with: round, item_id (uuid), voided:false baseline.
  -- This is the new behaviour — gives the UI a stable handle per line
  -- for per-item void/cancel.
  SELECT jsonb_agg(
    item
      || jsonb_build_object('round', v_kot_n)
      || jsonb_build_object('item_id', gen_random_uuid())
      || jsonb_build_object('voided', false)
  )
  INTO v_stamped
  FROM jsonb_array_elements(p_items) AS item;

  v_new_kot := jsonb_build_object(
    'round',      v_kot_n,
    'items',      v_stamped,
    'notes',      p_notes,
    'sent_at',    to_char(now() AT TIME ZONE 'Asia/Kolkata', 'HH24:MI'),
    'kot_number', v_kot_n
  );

  UPDATE sbp_running_orders
  SET items      = items || v_stamped,
      kots       = kots  || jsonb_build_array(v_new_kot),
      kot_count  = v_kot_n,
      notes      = COALESCE(p_notes, notes),
      updated_at = now()
  WHERE id = p_order_id AND shop_id = p_shop_id;

  -- Also register in KDS (sbp_restaurant_orders) with the stamped items
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='sbp_restaurant_orders') THEN
    INSERT INTO sbp_restaurant_orders (
      shop_id, table_number, table_id, items, status, source, notes, kot_number
    ) VALUES (
      p_shop_id, v_row.table_number, v_row.table_id,
      v_stamped, 'pending', 'pos', p_notes, v_kot_n
    );
  END IF;

  SELECT * INTO v_row FROM sbp_running_orders WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_row), 'kot_number', v_kot_n);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_add_items(uuid, uuid, jsonb, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 8. sbp_ro_void_item  — PIN-gated per-item void (full or partial qty)
-- ─────────────────────────────────────────────────────────────────
-- Customer changes their mind on ONE item that's already been sent to
-- the kitchen. Whole-order void is too aggressive. This RPC:
--   • Verifies the manager PIN server-side (re-check, not just client).
--   • Voids p_qty units (NULL = all remaining). Uses CUMULATIVE
--     `voided_qty` so partial voids stack across calls:
--         Garlic Naan ×11 → void 3 → voided_qty=3, active=8
--                        → void 2 → voided_qty=5, active=6
--                        → void NULL (all) → voided_qty=11, active=0
--     `voided:true` flag is only set when voided_qty reaches qty
--     (fully gone). Renderers can show "× of ×N cancelled" hints
--     based on voided_qty when partially voided.
--   • Updates the corresponding sbp_restaurant_orders entry so the
--     kitchen sees the cancellation (full or partial).
--   • Writes an audit_log entry.
DROP FUNCTION IF EXISTS sbp_ro_void_item(uuid, uuid, uuid, text, text);
DROP FUNCTION IF EXISTS sbp_ro_void_item(uuid, uuid, uuid, text, text, int);
CREATE OR REPLACE FUNCTION sbp_ro_void_item(
  p_shop_id   uuid,
  p_order_id  uuid,
  p_item_id   uuid,
  p_auth_pin  text,
  p_reason    text DEFAULT NULL,
  p_qty       int  DEFAULT NULL    -- NULL = void all remaining
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_row         sbp_running_orders%ROWTYPE;
  v_pin         jsonb;
  v_user_id     uuid;
  v_user_name   text;
  v_item_iid    text := p_item_id::text;
  v_found       boolean := false;
  v_orig_qty    int;
  v_already_v   int;
  v_remaining   int;
  v_to_void     int;
  v_new_voided  int;
  v_item_before jsonb;
  v_new_items   jsonb := '[]'::jsonb;
  v_elem        jsonb;
  v_voided_now  text;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  v_pin := public.sbp_verify_pin(p_shop_id, p_auth_pin);
  IF NOT COALESCE((v_pin->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_invalid');
  END IF;
  v_user_id   := NULLIF(v_pin->>'user_id', '')::uuid;
  v_user_name := v_pin->>'user_name';

  SELECT * INTO v_row FROM sbp_running_orders
  WHERE id = p_order_id AND shop_id = p_shop_id
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;
  IF v_row.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_open');
  END IF;

  v_voided_now := to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD"T"HH24:MI:SS');

  FOR v_elem IN SELECT * FROM jsonb_array_elements(v_row.items)
  LOOP
    IF v_elem->>'item_id' = v_item_iid THEN
      v_found := true;
      v_orig_qty  := COALESCE((v_elem->>'qty')::int, 0);
      v_already_v := COALESCE((v_elem->>'voided_qty')::int, 0);
      v_remaining := GREATEST(v_orig_qty - v_already_v, 0);
      IF v_remaining = 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_voided');
      END IF;

      -- Resolve target qty: NULL → void all remaining; else clamp 1..remaining
      v_to_void := COALESCE(p_qty, v_remaining);
      IF v_to_void < 1 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_qty');
      END IF;
      IF v_to_void > v_remaining THEN
        v_to_void := v_remaining;
      END IF;

      v_new_voided := v_already_v + v_to_void;
      v_item_before := v_elem;

      v_elem := v_elem
        || jsonb_build_object('voided_qty', v_new_voided)
        || jsonb_build_object('voided', v_new_voided >= v_orig_qty)
        || jsonb_build_object('voided_at', v_voided_now)
        || jsonb_build_object('voided_reason', COALESCE(p_reason, ''))
        || jsonb_build_object('voided_by', COALESCE(v_user_name, ''));
    END IF;
    v_new_items := v_new_items || jsonb_build_array(v_elem);
  END LOOP;

  IF NOT v_found THEN
    RETURN jsonb_build_object('ok', false, 'error', 'item_not_found');
  END IF;

  -- Refuse if this would void the LAST active unit across the whole order
  -- (operator should void the whole order instead, which frees the table).
  IF (
    SELECT COALESCE(SUM(
      GREATEST(
        COALESCE((e->>'qty')::int, 0) - COALESCE((e->>'voided_qty')::int, 0),
        0
      )
    ), 0)
    FROM jsonb_array_elements(v_new_items) e
  ) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'last_active_item');
  END IF;

  UPDATE sbp_running_orders
  SET items = v_new_items, updated_at = now()
  WHERE id = p_order_id;

  -- Mirror to KDS so the kitchen sees the matching cancel
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='sbp_restaurant_orders') THEN
    UPDATE sbp_restaurant_orders ro
    SET items = (
      SELECT jsonb_agg(
        CASE
          WHEN e->>'item_id' = v_item_iid THEN
            e || jsonb_build_object(
              'voided_qty', LEAST(
                COALESCE((e->>'voided_qty')::int, 0) +
                LEAST(
                  COALESCE(p_qty, GREATEST(COALESCE((e->>'qty')::int,0) - COALESCE((e->>'voided_qty')::int,0), 0)),
                  GREATEST(COALESCE((e->>'qty')::int,0) - COALESCE((e->>'voided_qty')::int,0), 0)
                ),
                COALESCE((e->>'qty')::int, 0)
              ),
              'voided',
                (COALESCE((e->>'voided_qty')::int, 0) +
                 LEAST(
                  COALESCE(p_qty, GREATEST(COALESCE((e->>'qty')::int,0) - COALESCE((e->>'voided_qty')::int,0), 0)),
                  GREATEST(COALESCE((e->>'qty')::int,0) - COALESCE((e->>'voided_qty')::int,0), 0)
                 )
                ) >= COALESCE((e->>'qty')::int, 0),
              'voided_at',     v_voided_now,
              'voided_reason', COALESCE(p_reason, ''),
              'voided_by',     COALESCE(v_user_name, '')
            )
          ELSE e
        END
      )
      FROM jsonb_array_elements(ro.items) AS e
    )
    WHERE ro.shop_id = p_shop_id
      AND ro.table_number = v_row.table_number
      AND ro.created_at >= v_row.opened_at
      AND ro.items @> jsonb_build_array(jsonb_build_object('item_id', v_item_iid));
  END IF;

  BEGIN
    PERFORM public.sbp_audit_log_write(
      p_shop_id              => p_shop_id,
      p_action_code          => 'restaurant.void_running_item',
      p_target_table         => 'sbp_running_orders',
      p_target_id            => p_order_id,
      p_before_json          => v_item_before,
      p_after_json           => jsonb_build_object('item_id', v_item_iid, 'qty_voided', v_to_void, 'voided_qty_total', v_new_voided, 'orig_qty', v_orig_qty),
      p_reason               => p_reason,
      p_authorized_by_user_id=> v_user_id,
      p_authorized_by_name   => v_user_name
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Audit log write skipped: %', SQLERRM;
  END;

  SELECT * INTO v_row FROM sbp_running_orders WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_row), 'qty_voided', v_to_void, 'voided_qty_total', v_new_voided);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_void_item(uuid, uuid, uuid, text, text, int) TO authenticated;


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
