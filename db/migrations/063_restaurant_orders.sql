-- ════════════════════════════════════════════════════════════════════
-- 063_restaurant_orders.sql
-- Kitchen Display System — order tracking for restaurant tables
--
-- Tables:
--   sbp_restaurant_orders  — order records (from POS bills + manual entry)
--
-- RPCs:
--   sbp_orders_create(p_shop_id, p_data)      — create order from bill save
--   sbp_orders_list(p_shop_id, p_status)       — list orders for KDS
--   sbp_orders_set_status(p_shop_id, p_order_id, p_status) — mark done etc
--   sbp_orders_add_manual(p_shop_id, p_data)   — manual order (walk-in/WhatsApp)
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── Orders table ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sbp_restaurant_orders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  table_number  text NOT NULL,
  table_id      uuid REFERENCES sbp_restaurant_tables(id) ON DELETE SET NULL,
  bill_id       uuid,                           -- linked bill (null for manual)
  items         jsonb NOT NULL DEFAULT '[]',    -- [{name, qty, notes}]
  status        text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','in_progress','done','cancelled')),
  source        text NOT NULL DEFAULT 'pos'
    CHECK (source IN ('pos','qr','manual')),
  notes         text,
  kot_number    int,                            -- sequential KOT number per shop/day
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  done_at       timestamptz
);

CREATE INDEX IF NOT EXISTS idx_rorders_shop_status
  ON sbp_restaurant_orders(shop_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_rorders_shop_date
  ON sbp_restaurant_orders(shop_id, created_at DESC);

ALTER TABLE sbp_restaurant_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_rorders_shop ON sbp_restaurant_orders;
CREATE POLICY p_rorders_shop ON sbp_restaurant_orders
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


-- ── Helper: next KOT number for today ────────────────────────────
CREATE OR REPLACE FUNCTION _sbp_next_kot(p_shop_id uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  SELECT COALESCE(MAX(kot_number), 0) + 1 INTO v_n
  FROM sbp_restaurant_orders
  WHERE shop_id = p_shop_id
    AND created_at >= date_trunc('day', now() AT TIME ZONE 'Asia/Kolkata')::timestamptz;
  RETURN v_n;
END; $$;


-- ── 1. sbp_orders_create ─────────────────────────────────────────
-- Called by billing.html after saving a table-linked bill.
-- p_data: { table_number, table_id?, bill_id?, items:[{name,qty}], notes?, source? }
DROP FUNCTION IF EXISTS sbp_orders_create(uuid, jsonb);
CREATE OR REPLACE FUNCTION sbp_orders_create(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_row  sbp_restaurant_orders%ROWTYPE;
  v_tnum text;
  v_kot  int;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  v_tnum := trim(coalesce(p_data->>'table_number', ''));
  IF length(v_tnum) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'table_number_required');
  END IF;

  -- items must be a non-empty array
  IF coalesce(jsonb_array_length(p_data->'items'), 0) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'items_required');
  END IF;

  v_kot := public._sbp_next_kot(p_shop_id);

  INSERT INTO sbp_restaurant_orders (
    shop_id, table_number, table_id, bill_id,
    items, status, source, notes, kot_number
  ) VALUES (
    p_shop_id,
    v_tnum,
    NULLIF(p_data->>'table_id', '')::uuid,
    NULLIF(p_data->>'bill_id', '')::uuid,
    p_data->'items',
    'pending',
    COALESCE(NULLIF(p_data->>'source',''), 'pos'),
    NULLIF(p_data->>'notes', ''),
    v_kot
  ) RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_row), 'kot_number', v_kot);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_orders_create(uuid, jsonb) TO authenticated;


-- ── 2. sbp_orders_list ───────────────────────────────────────────
-- p_status: 'active' (pending+in_progress) | 'done' | 'all'
DROP FUNCTION IF EXISTS sbp_orders_list(uuid, text);
CREATE OR REPLACE FUNCTION sbp_orders_list(p_shop_id uuid, p_status text DEFAULT 'active')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'orders', COALESCE((
      SELECT jsonb_agg(to_jsonb(o) ORDER BY o.created_at ASC)
      FROM sbp_restaurant_orders o
      WHERE o.shop_id = p_shop_id
        AND (
          CASE p_status
            WHEN 'active' THEN o.status IN ('pending','in_progress')
            WHEN 'pending' THEN o.status = 'pending'
            WHEN 'in_progress' THEN o.status = 'in_progress'
            WHEN 'done' THEN o.status = 'done'
              AND o.done_at >= now() - interval '4 hours'
            WHEN 'cancelled' THEN o.status = 'cancelled'
            ELSE true  -- 'all'
          END
        )
    ), '[]'::jsonb)
  );
END; $$;

GRANT EXECUTE ON FUNCTION sbp_orders_list(uuid, text) TO authenticated;


-- ── 3. sbp_orders_set_status ─────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_orders_set_status(uuid, uuid, text);
CREATE OR REPLACE FUNCTION sbp_orders_set_status(
  p_shop_id  uuid,
  p_order_id uuid,
  p_status   text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  IF p_status NOT IN ('pending','in_progress','done','cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  UPDATE sbp_restaurant_orders
    SET status     = p_status,
        updated_at = now(),
        done_at    = CASE WHEN p_status = 'done' THEN now() ELSE done_at END
  WHERE id = p_order_id AND shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_orders_set_status(uuid, uuid, text) TO authenticated;


-- ── 4. sbp_orders_add_manual ─────────────────────────────────────
-- For kitchen staff to add orders not in the POS (WhatsApp orders etc.)
-- p_data: { table_number, items:[{name,qty}], notes? }
DROP FUNCTION IF EXISTS sbp_orders_add_manual(uuid, jsonb);
CREATE OR REPLACE FUNCTION sbp_orders_add_manual(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  p_data := p_data || jsonb_build_object('source', 'manual');
  RETURN public.sbp_orders_create(p_shop_id, p_data);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_orders_add_manual(uuid, jsonb) TO authenticated;


NOTIFY pgrst, 'reload schema';
COMMIT;

-- Verify:
--   SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema='public' AND routine_name LIKE 'sbp_orders%'
--   ORDER BY routine_name;
--   -- Should return 4 rows
