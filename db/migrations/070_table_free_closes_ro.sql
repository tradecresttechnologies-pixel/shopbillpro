-- ════════════════════════════════════════════════════════════════════
-- 070_table_free_closes_ro.sql
-- ════════════════════════════════════════════════════════════════════
-- PROBLEM
--   "Time on table" never resets after a bill is settled. New session
--   keeps counting from the very first time the table was ever opened
--   (observed: T10 still "1d 10h" long after settling).
--
-- ROOT CAUSE
--   The settle flow (billing.html) frees the table via sbp_tables_free
--   FIRST, then closes the running order via sbp_ro_generate_bill ONLY
--   when the bill came from a running order AND a real server bill id
--   exists. If the bill id is local/offline, or the RO flag isn't set,
--   sbp_ro_generate_bill is never called → the running order stays
--   status='open' with its ORIGINAL opened_at. On next open,
--   sbp_ro_open finds that still-open order and RESUMES it (resumed:
--   true), so opened_at — and the timer — never resets.
--
-- FIX (server-side, unconditional — the table's lifecycle owns this,
--      not a client flag)
--   Whenever a table transitions to 'free' (via sbp_tables_free OR
--   sbp_tables_set_status p_status='free'), also close ANY open running
--   order for that table: status → 'billed', billed_at stamped. A
--   closed session means sbp_ro_open will create a FRESH running order
--   with a new opened_at next time → the timer correctly restarts from
--   when the table is reopened.
--
-- SAFETY
--   • 'billed' is an allowed status (CHECK open|billed|void, mig 065).
--   • Per Batch 069 UI, Free is unreachable from the floor screen while
--     items are punched, so the only caller that frees a table with an
--     items-bearing open RO is the legitimate billing-settle path —
--     closing it there is exactly correct.
--   • Empty RO shells (0 items) are also closed → no more phantom
--     "₹0 · resume order" rows lingering after a free.
--   • bill_id is left untouched (COALESCE) so a later
--     sbp_ro_generate_bill from billing.html can still stamp the real
--     bill id onto the now-billed row without error.
--   • Idempotent: re-freeing a table with no open RO is a no-op.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. sbp_tables_free ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sbp_tables_free(p_shop_id uuid, p_table_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_closed int := 0;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  -- Close the table session: end any OPEN running order so the next
  -- open starts a fresh one (fresh opened_at → timer resets).
  WITH closed AS (
    UPDATE sbp_running_orders
       SET status     = 'billed',
           billed_at  = COALESCE(billed_at, now()),
           updated_at = now()
     WHERE shop_id  = p_shop_id
       AND table_id = p_table_id
       AND status   = 'open'
    RETURNING 1
  )
  SELECT count(*) INTO v_closed FROM closed;

  UPDATE sbp_restaurant_tables
     SET status = 'free', current_bill_id = null, updated_at = now()
   WHERE id = p_table_id AND shop_id = p_shop_id AND active = true;

  RETURN jsonb_build_object('ok', true, 'orders_closed', v_closed);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_tables_free(uuid, uuid) TO authenticated;


-- ── 2. sbp_tables_set_status ────────────────────────────────────────
-- Generic status setter. When the new status is 'free' it must close
-- the open running order too (same reasoning as sbp_tables_free).
DROP FUNCTION IF EXISTS sbp_tables_set_status(uuid, uuid, text);
CREATE OR REPLACE FUNCTION sbp_tables_set_status(
  p_shop_id  uuid,
  p_table_id uuid,
  p_status   text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_closed int := 0;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  IF p_status NOT IN ('free','occupied','reserved','cleaning') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  IF p_status = 'free' THEN
    WITH closed AS (
      UPDATE sbp_running_orders
         SET status     = 'billed',
             billed_at  = COALESCE(billed_at, now()),
             updated_at = now()
       WHERE shop_id  = p_shop_id
         AND table_id = p_table_id
         AND status   = 'open'
      RETURNING 1
    )
    SELECT count(*) INTO v_closed FROM closed;
  END IF;

  UPDATE sbp_restaurant_tables
     SET status = p_status,
         current_bill_id = CASE WHEN p_status = 'free' THEN null ELSE current_bill_id END,
         updated_at = now()
   WHERE id = p_table_id AND shop_id = p_shop_id AND active = true;

  RETURN jsonb_build_object('ok', true, 'orders_closed', v_closed);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_tables_set_status(uuid, uuid, text) TO authenticated;


-- PostgREST schema cache reload (permanent rule)
NOTIFY pgrst, 'reload schema';
