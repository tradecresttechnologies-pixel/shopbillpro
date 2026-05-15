-- ════════════════════════════════════════════════════════════════════
-- 062_restaurant_tables.sql
-- Restaurant table management for food verticals
-- (restaurant, cafe, qsr, cloud_kitchen, bar_lounge, dhaba, etc.)
--
-- Tables created:
--   sbp_restaurant_tables  — table master (number, section, capacity, status)
--
-- RPCs:
--   sbp_tables_list(p_shop_id)              — list all active tables
--   sbp_tables_upsert(p_shop_id, p_data)    — create / update table
--   sbp_tables_delete(p_shop_id, p_table_id)— soft delete
--   sbp_tables_set_occupied(p_shop_id, p_table_id, p_bill_id)  — mark occupied
--   sbp_tables_free(p_shop_id, p_table_id)  — mark free (on bill save/void)
--   sbp_tables_set_status(p_shop_id, p_table_id, p_status)     — generic status set
--
-- Tier: Pro + Business (owner and active staff)
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── Table master ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sbp_restaurant_tables (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  table_number    text NOT NULL CHECK (length(trim(table_number)) > 0),
  section         text,                         -- Indoor / Outdoor / Bar / Terrace
  capacity        int  NOT NULL DEFAULT 4,
  status          text NOT NULL DEFAULT 'free'
    CHECK (status IN ('free','occupied','reserved','cleaning')),
  current_bill_id uuid,                         -- bill currently open on this table
  active          boolean NOT NULL DEFAULT true,
  display_order   int     NOT NULL DEFAULT 0,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, table_number)
);

CREATE INDEX IF NOT EXISTS idx_rtables_shop
  ON sbp_restaurant_tables(shop_id) WHERE active = true;

ALTER TABLE sbp_restaurant_tables ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_rtables_owner ON sbp_restaurant_tables;
CREATE POLICY p_rtables_owner ON sbp_restaurant_tables
  FOR ALL TO authenticated
  USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
    OR
    shop_id IN (SELECT shop_id FROM shop_users WHERE user_id = auth.uid() AND is_active = true)
  )
  WITH CHECK (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
    OR
    shop_id IN (SELECT shop_id FROM shop_users WHERE user_id = auth.uid() AND is_active = true)
  );


-- ── Helper: check owner or active staff ─────────────────────────
-- Reuses the existing _sbp_check_shop_owner (updated in 061 to include staff)
-- No new helper needed.


-- ── 1. sbp_tables_list ──────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_tables_list(uuid);
CREATE OR REPLACE FUNCTION sbp_tables_list(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'tables', COALESCE((
      SELECT jsonb_agg(
        to_jsonb(t) ORDER BY t.display_order ASC, t.table_number ASC
      )
      FROM sbp_restaurant_tables t
      WHERE t.shop_id = p_shop_id AND t.active = true
    ), '[]'::jsonb)
  );
END; $$;

GRANT EXECUTE ON FUNCTION sbp_tables_list(uuid) TO authenticated;


-- ── 2. sbp_tables_upsert ────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_tables_upsert(uuid, jsonb);
CREATE OR REPLACE FUNCTION sbp_tables_upsert(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_id   uuid;
  v_num  text;
  v_row  sbp_restaurant_tables%ROWTYPE;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  v_num := trim(coalesce(p_data->>'table_number', ''));
  IF length(v_num) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'table_number_required');
  END IF;

  v_id := NULLIF(p_data->>'id', '')::uuid;

  IF v_id IS NULL THEN
    INSERT INTO sbp_restaurant_tables (
      shop_id, table_number, section, capacity,
      status, notes, active, display_order
    ) VALUES (
      p_shop_id, v_num,
      NULLIF(p_data->>'section', ''),
      COALESCE((p_data->>'capacity')::int, 4),
      COALESCE(NULLIF(p_data->>'status',''), 'free'),
      NULLIF(p_data->>'notes', ''),
      COALESCE((p_data->>'active')::boolean, true),
      COALESCE((p_data->>'display_order')::int, 0)
    ) RETURNING * INTO v_row;
  ELSE
    UPDATE sbp_restaurant_tables SET
      table_number  = v_num,
      section       = COALESCE(NULLIF(p_data->>'section',''),  section),
      capacity      = COALESCE((p_data->>'capacity')::int,     capacity),
      notes         = COALESCE(NULLIF(p_data->>'notes',''),    notes),
      active        = COALESCE((p_data->>'active')::boolean,   active),
      display_order = COALESCE((p_data->>'display_order')::int, display_order),
      updated_at    = now()
    WHERE id = v_id AND shop_id = p_shop_id
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'table_not_found');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'table', to_jsonb(v_row));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate_table_number');
END; $$;

GRANT EXECUTE ON FUNCTION sbp_tables_upsert(uuid, jsonb) TO authenticated;


-- ── 3. sbp_tables_delete ────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_tables_delete(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_tables_delete(p_shop_id uuid, p_table_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  UPDATE sbp_restaurant_tables
    SET active = false, updated_at = now()
  WHERE id = p_table_id AND shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_tables_delete(uuid, uuid) TO authenticated;


-- ── 4. sbp_tables_set_occupied ──────────────────────────────────
-- Called by billing.html when a new bill is started for a table
DROP FUNCTION IF EXISTS sbp_tables_set_occupied(uuid, uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_tables_set_occupied(
  p_shop_id   uuid,
  p_table_id  uuid,
  p_bill_id   uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  UPDATE sbp_restaurant_tables
    SET status = 'occupied', current_bill_id = p_bill_id, updated_at = now()
  WHERE id = p_table_id AND shop_id = p_shop_id AND active = true;

  RETURN jsonb_build_object('ok', true);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_tables_set_occupied(uuid, uuid, uuid) TO authenticated;


-- ── 5. sbp_tables_free ──────────────────────────────────────────
-- Called by billing.html after bill is saved/settled
DROP FUNCTION IF EXISTS sbp_tables_free(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_tables_free(p_shop_id uuid, p_table_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  UPDATE sbp_restaurant_tables
    SET status = 'free', current_bill_id = null, updated_at = now()
  WHERE id = p_table_id AND shop_id = p_shop_id AND active = true;

  RETURN jsonb_build_object('ok', true);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_tables_free(uuid, uuid) TO authenticated;


-- ── 6. sbp_tables_set_status ─────────────────────────────────────
-- Generic status setter (reserved, cleaning, free)
DROP FUNCTION IF EXISTS sbp_tables_set_status(uuid, uuid, text);
CREATE OR REPLACE FUNCTION sbp_tables_set_status(
  p_shop_id  uuid,
  p_table_id uuid,
  p_status   text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  IF p_status NOT IN ('free','occupied','reserved','cleaning') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  UPDATE sbp_restaurant_tables
    SET status = p_status,
        current_bill_id = CASE WHEN p_status = 'free' THEN null ELSE current_bill_id END,
        updated_at = now()
  WHERE id = p_table_id AND shop_id = p_shop_id AND active = true;

  RETURN jsonb_build_object('ok', true);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_tables_set_status(uuid, uuid, text) TO authenticated;


NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════
-- Verify:
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema='public' AND routine_name LIKE 'sbp_tables%'
--   ORDER BY routine_name;
--   -- Should return 6 rows
-- ════════════════════════════════════════════════════════════════
