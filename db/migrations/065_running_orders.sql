-- ════════════════════════════════════════════════════════════════════
-- 065_running_orders.sql
-- Proper dine-in restaurant POS: Running Order architecture
--
-- Flow: Open table → Running Order accumulates items across rounds
--       → Each round prints KOT to kitchen
--       → Customer says "bill please" → Generate Bill from running order
--       → Billing.html pre-filled → Payment → Table freed
--
-- Tables:
--   sbp_running_orders  — active order per table session
--
-- RPCs:
--   sbp_ro_open(shop_id, table_id, table_number)       → create/resume running order
--   sbp_ro_get(shop_id, table_id)                      → get active order for table
--   sbp_ro_add_items(shop_id, order_id, items, notes)  → add round + auto-create KOT
--   sbp_ro_generate_bill(shop_id, order_id)            → mark billed, return all items
--   sbp_ro_void(shop_id, order_id)                     → cancel order, free table
--   sbp_ro_get_by_id(shop_id, order_id)                → get specific order
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS sbp_running_orders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  table_id      uuid REFERENCES sbp_restaurant_tables(id) ON DELETE SET NULL,
  table_number  text NOT NULL,
  -- All items accumulated across ALL rounds: [{name, qty, price, round, notes}]
  items         jsonb NOT NULL DEFAULT '[]',
  -- Each KOT sent: [{round, items:[{name,qty}], sent_at, kot_number}]
  kots          jsonb NOT NULL DEFAULT '[]',
  kot_count     int  NOT NULL DEFAULT 0,
  status        text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','billed','void')),
  bill_id       uuid,                     -- set when generate_bill is called
  notes         text,
  opened_at     timestamptz NOT NULL DEFAULT now(),
  billed_at     timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ro_shop_table
  ON sbp_running_orders(shop_id, table_id, status)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_ro_shop_status
  ON sbp_running_orders(shop_id, status, opened_at DESC);

ALTER TABLE sbp_running_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_ro ON sbp_running_orders;
CREATE POLICY p_ro ON sbp_running_orders
  FOR ALL TO authenticated
  USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
    OR shop_id IN (SELECT shop_id FROM shop_users WHERE user_id = auth.uid() AND is_active = true)
  )
  WITH CHECK (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
    OR shop_id IN (SELECT shop_id FROM shop_users WHERE user_id = auth.uid() AND is_active = true)
  );


-- ── 1. sbp_ro_open ───────────────────────────────────────────────
-- Opens a new running order for a table (or returns existing open one)
DROP FUNCTION IF EXISTS sbp_ro_open(uuid, uuid, text);
CREATE OR REPLACE FUNCTION sbp_ro_open(
  p_shop_id     uuid,
  p_table_id    uuid,
  p_table_number text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_existing  sbp_running_orders%ROWTYPE;
  v_new       sbp_running_orders%ROWTYPE;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  -- Check if open order already exists for this table
  SELECT * INTO v_existing
  FROM sbp_running_orders
  WHERE shop_id = p_shop_id
    AND table_id = p_table_id
    AND status   = 'open'
  ORDER BY opened_at DESC
  LIMIT 1;

  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_existing), 'resumed', true);
  END IF;

  -- Create new running order
  INSERT INTO sbp_running_orders (shop_id, table_id, table_number)
  VALUES (p_shop_id, p_table_id, p_table_number)
  RETURNING * INTO v_new;

  -- Mark table as occupied
  UPDATE sbp_restaurant_tables
  SET status = 'occupied', updated_at = now()
  WHERE id = p_table_id AND shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_new), 'resumed', false);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_open(uuid, uuid, text) TO authenticated;


-- ── 2. sbp_ro_get ────────────────────────────────────────────────
-- Get the active (open) running order for a table
DROP FUNCTION IF EXISTS sbp_ro_get(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_ro_get(p_shop_id uuid, p_table_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_row sbp_running_orders%ROWTYPE;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_row
  FROM sbp_running_orders
  WHERE shop_id = p_shop_id AND table_id = p_table_id AND status = 'open'
  ORDER BY opened_at DESC LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'order', null);
  END IF;

  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_row));
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_get(uuid, uuid) TO authenticated;


-- ── 3. sbp_ro_get_by_id ──────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_ro_get_by_id(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_ro_get_by_id(p_shop_id uuid, p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_row sbp_running_orders%ROWTYPE;
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

  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_row));
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_get_by_id(uuid, uuid) TO authenticated;


-- ── 4. sbp_ro_add_items ──────────────────────────────────────────
-- Add a new round of items to the running order.
-- Also creates a KOT record (auto-registered in sbp_restaurant_orders).
-- p_items: [{name, qty, price?, notes?}]
DROP FUNCTION IF EXISTS sbp_ro_add_items(uuid, uuid, jsonb, text);
CREATE OR REPLACE FUNCTION sbp_ro_add_items(
  p_shop_id  uuid,
  p_order_id uuid,
  p_items    jsonb,
  p_notes    text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_row     sbp_running_orders%ROWTYPE;
  v_kot_n   int;
  v_new_kot jsonb;
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

  -- Stamp round number onto each item
  v_new_kot := jsonb_build_object(
    'round',      v_kot_n,
    'items',      p_items,
    'notes',      p_notes,
    'sent_at',    to_char(now() AT TIME ZONE 'Asia/Kolkata', 'HH24:MI'),
    'kot_number', v_kot_n
  );

  -- Add items to master list (with round tag)
  UPDATE sbp_running_orders
  SET items     = items || (
        SELECT jsonb_agg(item || jsonb_build_object('round', v_kot_n))
        FROM jsonb_array_elements(p_items) AS item
      ),
      kots      = kots || jsonb_build_array(v_new_kot),
      kot_count = v_kot_n,
      notes     = COALESCE(p_notes, notes),
      updated_at = now()
  WHERE id = p_order_id AND shop_id = p_shop_id;

  -- Also register in sbp_restaurant_orders (for KDS)
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='sbp_restaurant_orders') THEN
    INSERT INTO sbp_restaurant_orders (
      shop_id, table_number, table_id, items, status, source, notes, kot_number
    ) VALUES (
      p_shop_id, v_row.table_number, v_row.table_id,
      p_items, 'pending', 'pos', p_notes, v_kot_n
    );
  END IF;

  -- Re-read updated row
  SELECT * INTO v_row FROM sbp_running_orders WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_row), 'kot_number', v_kot_n);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_add_items(uuid, uuid, jsonb, text) TO authenticated;


-- ── 5. sbp_ro_generate_bill ──────────────────────────────────────
-- Marks running order as 'billed', returns all accumulated items
-- for billing.html to pre-fill.
DROP FUNCTION IF EXISTS sbp_ro_generate_bill(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_ro_generate_bill(p_shop_id uuid, p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_row sbp_running_orders%ROWTYPE;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_row
  FROM sbp_running_orders
  WHERE id = p_order_id AND shop_id = p_shop_id AND status = 'open';

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found_or_already_billed');
  END IF;

  IF jsonb_array_length(v_row.items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_items_to_bill');
  END IF;

  -- Mark as billed (table freed after actual payment in billing.html)
  UPDATE sbp_running_orders
  SET status = 'billed', billed_at = now(), updated_at = now()
  WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'items',        v_row.items,
    'table_number', v_row.table_number,
    'table_id',     v_row.table_id,
    'order_id',     v_row.id,
    'kot_count',    v_row.kot_count
  );
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_generate_bill(uuid, uuid) TO authenticated;


-- ── 6. sbp_ro_void ───────────────────────────────────────────────
-- Cancel running order, free table
DROP FUNCTION IF EXISTS sbp_ro_void(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_ro_void(p_shop_id uuid, p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE v_row sbp_running_orders%ROWTYPE;
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

  UPDATE sbp_running_orders
  SET status = 'void', updated_at = now()
  WHERE id = p_order_id;

  -- Free the table
  IF v_row.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status = 'free', current_bill_id = null, updated_at = now()
    WHERE id = v_row.table_id AND shop_id = p_shop_id;
  END IF;

  RETURN jsonb_build_object('ok', true);
END; $$;

GRANT EXECUTE ON FUNCTION sbp_ro_void(uuid, uuid) TO authenticated;


NOTIFY pgrst, 'reload schema';
COMMIT;
