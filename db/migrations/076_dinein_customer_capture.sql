-- ════════════════════════════════════════════════════════════════════
-- 076_dinein_customer_capture.sql   (Restaurant — customer capture)
-- ════════════════════════════════════════════════════════════════════
-- GOAL (locked with Vinay)
--   Capture customer name + mobile for dine-in at Seat Guests AND
--   auto-carry the QR guest's typed name/phone to the bill; save as a
--   customer record for history / loyalty / WhatsApp bill.
--
-- DESIGN — REUSE, DON'T REBUILD
--   sbp_resolve_customer_for_booking (024) ALREADY does exactly the
--   safe find-or-create we need:
--     • phone-first match via sbp_normalize_phone (dedupe — a repeat
--       diner is NOT duplicated)
--     • name fallback only when no phone
--     • creates only when not found
--     • requires a name (no junk rows)
--   It is general-purpose despite the "_for_booking" name. We reuse it
--   verbatim — no parallel dedupe logic, no new resolver.
--
--   GUARDRAIL (protects the customer DB): a customer record is created
--   ONLY when a valid mobile is present. Name-only goes on the bill as
--   a label but does NOT create a customer (can't dedupe or WhatsApp
--   it; would flood the DB with one-off walk-ins). This is enforced in
--   sbp_ro_set_customer below.
--
-- WHAT THIS MIGRATION DOES
--   1. sbp_running_orders += cust_name text, cust_phone text,
--      customer_id uuid  (session holds the customer between seat and
--      bill so any open path can carry it forward)
--   2. NEW sbp_ro_set_customer(shop_id, order_id, name, phone):
--        • stores name/phone on the session always (label)
--        • if a valid normalized phone exists → calls
--          sbp_resolve_customer_for_booking → stamps customer_id
--        • exception-safe envelope
--   3. sbp_ro_generate_bill → returns cust_name/cust_phone/customer_id
--      so billing copies them onto the bill row.
--
-- SAFETY
--   • ADD COLUMN IF NOT EXISTS → idempotent.
--   • Reuses existing GRANTed helpers; no privilege changes.
--   • Existing sessions get NULLs (treated as walk-in, unchanged).
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Schema ───────────────────────────────────────────────────────
ALTER TABLE sbp_running_orders
  ADD COLUMN IF NOT EXISTS cust_name   text,
  ADD COLUMN IF NOT EXISTS cust_phone  text,
  ADD COLUMN IF NOT EXISTS customer_id uuid;


-- ── 2. sbp_ro_set_customer ──────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_ro_set_customer(uuid, uuid, text, text);
CREATE OR REPLACE FUNCTION sbp_ro_set_customer(
  p_shop_id  uuid,
  p_order_id uuid,
  p_name     text,
  p_phone    text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_row    sbp_running_orders%ROWTYPE;
  v_norm   text;
  v_cid    uuid := NULL;
  v_name   text := NULLIF(trim(COALESCE(p_name, '')), '');
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

  v_norm := public.sbp_normalize_phone(p_phone);

  -- Create / find a saved customer ONLY when a valid mobile exists
  -- (guardrail: no phone = no customer record, just a bill label).
  IF v_norm IS NOT NULL AND v_name IS NOT NULL THEN
    BEGIN
      v_cid := public.sbp_resolve_customer_for_booking(
                 p_shop_id, v_name, p_phone, p_phone, NULL);
    EXCEPTION WHEN OTHERS THEN
      v_cid := NULL;   -- never fail the session over customer resolve
    END;
  END IF;

  UPDATE sbp_running_orders
     SET cust_name   = v_name,
         cust_phone  = v_norm,
         customer_id = COALESCE(v_cid, customer_id),
         updated_at  = now()
   WHERE id = p_order_id
   RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok',          true,
    'cust_name',   v_row.cust_name,
    'cust_phone',  v_row.cust_phone,
    'customer_id', v_row.customer_id,
    'saved',       (v_cid IS NOT NULL)
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception',
    'detail', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_ro_set_customer(uuid, uuid, text, text) TO authenticated;


-- ── 3. sbp_ro_generate_bill — surface customer to billing ───────────
-- Same 3-arg signature as 074. Adds cust_name/cust_phone/customer_id
-- to the return so billing.html / running-order bill writes them.
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
    'server_name',    v_row.server_name,
    'cust_name',      v_row.cust_name,
    'cust_phone',     v_row.cust_phone,
    'customer_id',    v_row.customer_id
  );
END; $$;
GRANT EXECUTE ON FUNCTION sbp_ro_generate_bill(uuid, uuid, uuid) TO authenticated;


NOTIFY pgrst, 'reload schema';
