-- ════════════════════════════════════════════════════════════════════
-- 074_covers_and_server_capture.sql   (Restaurant Reports — Phase A)
-- ════════════════════════════════════════════════════════════════════
-- WHY
--   Full restaurant reports (locked: build everything, skip nothing)
--   require per-cover metrics and waiter performance. Today NOTHING
--   records guest count or which staff served. A report can only
--   aggregate columns that exist, so capture MUST land before the
--   report RPC — otherwise those sections would be empty stubs.
--
-- DECISIONS (locked with Vinay)
--   • Covers: set at Seat Guests, editable at billing. Stored on the
--     running-order session; copied to the bill at settle.
--   • Server: AUTO = the logged-in staff (auth.uid()) who opens the
--     table; resolved to a display name via sbp_authorized_users
--     .user_name (the proven-correct lookup from 072). Re-stamped at
--     bill time so the biller is recorded if different.
--   • Staff list: reuse sbp_authorized_users (no new roster).
--
-- WHAT THIS MIGRATION DOES
--   1. sbp_running_orders  += covers int, server_user_id uuid,
--                              server_name text
--   2. bills               += covers int, server_user_id uuid,
--                              server_name text   (carried at settle)
--   3. sbp_ro_open         → stamps server_user_id/server_name from
--                              auth.uid() on a NEW session (auto).
--   4. NEW sbp_ro_set_covers(shop_id, order_id, covers) → set/edit
--      covers from Seat Guests prompt OR billing screen. Self-contained,
--      exception-safe envelope.
--   5. sbp_ro_generate_bill → returns covers + server so billing.html
--      can copy them onto the bill row it writes, and re-stamps the
--      session server to the biller if it was never set.
--
-- SAFETY
--   • All ADD COLUMN IF NOT EXISTS → idempotent, no data loss.
--   • Existing sessions get covers NULL (reports treat NULL as
--     "not recorded", never 0 — no fake per-cover math).
--   • sbp_ro_open signature unchanged → no client breakage; server
--     stamp is purely additive on the INSERT path.
--   • Server lookup wrapped exception-safe (same pattern as 072).
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Schema additions ─────────────────────────────────────────────
ALTER TABLE sbp_running_orders
  ADD COLUMN IF NOT EXISTS covers          int,
  ADD COLUMN IF NOT EXISTS server_user_id  uuid,
  ADD COLUMN IF NOT EXISTS server_name     text;

ALTER TABLE bills
  ADD COLUMN IF NOT EXISTS covers          int,
  ADD COLUMN IF NOT EXISTS server_user_id  uuid,
  ADD COLUMN IF NOT EXISTS server_name     text;

-- Report query patterns: per-server and per-cover over a date range.
CREATE INDEX IF NOT EXISTS idx_bills_server
  ON bills(shop_id, server_user_id, created_at DESC)
  WHERE server_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ro_server
  ON sbp_running_orders(shop_id, server_user_id)
  WHERE server_user_id IS NOT NULL;


-- ── helper: resolve a display name for the calling staff ────────────
-- Reuses sbp_authorized_users.user_name (correct column, proven in
-- 072). Exception-safe; returns NULL on any miss so callers default.
CREATE OR REPLACE FUNCTION public._sbp_actor_name(p_shop_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_name text;
BEGIN
  BEGIN
    SELECT user_name INTO v_name
    FROM sbp_authorized_users
    WHERE shop_id = p_shop_id
      AND created_by = auth.uid()
      AND active = true
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_name := NULL;
  END;
  IF v_name IS NULL OR length(trim(v_name)) = 0 THEN
    RETURN NULL;
  END IF;
  RETURN v_name;
END;
$$;
GRANT EXECUTE ON FUNCTION public._sbp_actor_name(uuid) TO authenticated;


-- ── 2. sbp_ro_open — auto-stamp server on NEW session ───────────────
-- Signature UNCHANGED (uuid,uuid,text). Only the INSERT path gains the
-- server stamp; resume path untouched.
CREATE OR REPLACE FUNCTION sbp_ro_open(
  p_shop_id      uuid,
  p_table_id     uuid,
  p_table_number text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_existing sbp_running_orders%ROWTYPE;
  v_new      sbp_running_orders%ROWTYPE;
  v_sname    text;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_existing
  FROM sbp_running_orders
  WHERE shop_id = p_shop_id AND table_id = p_table_id AND status = 'open'
  ORDER BY opened_at DESC
  LIMIT 1;

  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_existing), 'resumed', true);
  END IF;

  v_sname := public._sbp_actor_name(p_shop_id);

  INSERT INTO sbp_running_orders
    (shop_id, table_id, table_number, server_user_id, server_name)
  VALUES
    (p_shop_id, p_table_id, p_table_number, auth.uid(), v_sname)
  RETURNING * INTO v_new;

  UPDATE sbp_restaurant_tables
  SET status = 'occupied', updated_at = now()
  WHERE id = p_table_id AND shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true, 'order', to_jsonb(v_new), 'resumed', false);
END; $$;
GRANT EXECUTE ON FUNCTION sbp_ro_open(uuid, uuid, text) TO authenticated;


-- ── 3. NEW sbp_ro_set_covers — set/edit guest count ─────────────────
-- Called from the Seat Guests party-size prompt AND from billing.html.
-- p_covers NULL or <1 clears it (treated as "not recorded").
DROP FUNCTION IF EXISTS sbp_ro_set_covers(uuid, uuid, int);
CREATE OR REPLACE FUNCTION sbp_ro_set_covers(
  p_shop_id  uuid,
  p_order_id uuid,
  p_covers   int
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE v_row sbp_running_orders%ROWTYPE;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_row
  FROM sbp_running_orders
  WHERE id = p_order_id AND shop_id = p_shop_id
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;

  UPDATE sbp_running_orders
     SET covers     = CASE WHEN p_covers IS NULL OR p_covers < 1
                           THEN NULL ELSE p_covers END,
         updated_at = now()
   WHERE id = p_order_id
   RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok', true, 'covers', v_row.covers);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception',
    'detail', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
END; $$;
GRANT EXECUTE ON FUNCTION sbp_ro_set_covers(uuid, uuid, int) TO authenticated;


-- ── 4. sbp_ro_generate_bill — surface covers+server, backfill server ─
-- Same 3-arg signature. Adds: if session never got a server (legacy /
-- edge), stamp the biller now; return covers+server so billing.html
-- copies them onto the bill row.
CREATE OR REPLACE FUNCTION sbp_ro_generate_bill(
  p_shop_id  uuid,
  p_order_id uuid,
  p_bill_id  uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_row   sbp_running_orders%ROWTYPE;
  v_sname text;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

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

  -- Backfill server if the session never captured one.
  IF v_row.server_user_id IS NULL THEN
    v_sname := public._sbp_actor_name(p_shop_id);
  END IF;

  UPDATE sbp_running_orders
  SET status         = 'billed',
      bill_id        = COALESCE(p_bill_id, bill_id),
      billed_at      = COALESCE(billed_at, now()),
      server_user_id = COALESCE(server_user_id, auth.uid()),
      server_name    = COALESCE(server_name, v_sname),
      updated_at     = now()
  WHERE id = p_order_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok',             true,
    'items',          v_row.items,
    'table_number',   v_row.table_number,
    'table_id',       v_row.table_id,
    'order_id',       v_row.id,
    'kot_count',      v_row.kot_count,
    'bill_id',        v_row.bill_id,
    'covers',         v_row.covers,
    'server_user_id', v_row.server_user_id,
    'server_name',    v_row.server_name
  );
END; $$;
GRANT EXECUTE ON FUNCTION sbp_ro_generate_bill(uuid, uuid, uuid) TO authenticated;


-- PostgREST schema cache reload (permanent rule)
NOTIFY pgrst, 'reload schema';
