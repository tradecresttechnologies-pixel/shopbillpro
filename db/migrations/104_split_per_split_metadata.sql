-- ════════════════════════════════════════════════════════════════════
-- 104_split_per_split_metadata.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   v7.1 — Per-split customer name / phone / payment_mode for all 3
--   split RPCs. Adds Credit support per split. Backward-compatible
--   with v7.0.1 callers (NULL metadata → defaults to walk-in + cash).
--
-- WHY
--   v7.0.x writes a single payment_mode for the whole split operation
--   and one customer (from the running order) only to the first bill.
--   The sequential confirm UX needs each split to carry its own
--   {customer_name, customer_phone, payment_mode}, and Credit splits
--   need correct status / paid_amount / balance_due.
--
-- NEW BEHAVIOUR
--   • sbp_ro_split_equal  — adds p_splits jsonb DEFAULT NULL
--     Shape: [{customer_name, customer_phone, payment_mode}, ...]
--     Must have exactly p_n_ways elements if provided.
--
--   • sbp_ro_split_custom — p_amounts elements may now be either:
--       - bare number (legacy)               → use p_payment_mode + walk-in
--       - object {amount, customer_name,
--                 customer_phone,
--                 payment_mode}              → per-split overrides
--     Detection: jsonb_typeof of p_amounts->0.
--
--   • sbp_ro_split_by_item — p_groups objects already exist
--     ({label, item_ids}). Now also read:
--       - customer_name, customer_phone, payment_mode (optional)
--
--   • Payment-mode normalisation: 'cash'|'CASH'|'Cash' → 'Cash'.
--     Allowed: Cash, UPI, Card, Credit. Others rejected.
--
--   • Credit split: status='Credit', paid_amount=0,
--     balance_due=grand_total. Cash/UPI/Card: status='Paid',
--     paid=grand_total, balance=0.
--
--   • Credit requires customer name. Returns:
--       {ok:false, error:'credit_requires_customer', split_index:N}
--     The entire split rolls back (one bad split aborts all).
--
--   • Customer_id lookup: if override name+phone match the RO's
--     customer (via sbp_normalize_phone), reuse v_ro.customer_id.
--     For Credit splits with a different customer, attempt
--     sbp_resolve_customer_for_booking (exception-safe — same pattern
--     mig 076 uses). Walk-in splits keep customer_id NULL.
--
-- DEPLOY
--   1. Run in Supabase SQL Editor.
--   2. Deploy running-order.html (Stage-1 modal + new Stage-2
--      sequential confirm modal + state machine).
--
-- ROLLBACK
--   Re-run migration 103 (v7.0.1 hotfix). Loses Credit + per-split
--   payment but split itself stays functional.
-- ════════════════════════════════════════════════════════════════════

-- ── _sbp_split_normalize_pay (internal helper) ──────────────────────
-- Normalises any input to one of: Cash | UPI | Card | Credit.
-- Returns NULL for unknown values (caller decides what to do).

DROP FUNCTION IF EXISTS _sbp_split_normalize_pay(text);
CREATE OR REPLACE FUNCTION _sbp_split_normalize_pay(p_raw text)
RETURNS text LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE v_upper text;
BEGIN
  IF p_raw IS NULL OR trim(p_raw) = '' THEN RETURN 'Cash'; END IF;
  v_upper := upper(trim(p_raw));
  IF v_upper = 'CASH'   THEN RETURN 'Cash';   END IF;
  IF v_upper = 'UPI'    THEN RETURN 'UPI';    END IF;
  IF v_upper = 'CARD'   THEN RETURN 'Card';   END IF;
  IF v_upper = 'CREDIT' THEN RETURN 'Credit'; END IF;
  RETURN NULL;  -- unknown
END;
$$;

-- ════════════════════════════════════════════════════════════════════
-- 1. sbp_ro_split_equal — adds p_splits param
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_ro_split_equal(uuid, int, text);
DROP FUNCTION IF EXISTS sbp_ro_split_equal(uuid, int, jsonb, text);

CREATE OR REPLACE FUNCTION sbp_ro_split_equal(
  p_order_id     uuid,
  p_n_ways       int,
  p_splits       jsonb DEFAULT NULL,
  p_payment_mode text  DEFAULT 'Cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ro            sbp_running_orders%ROWTYPE;
  v_shop_id       uuid;
  v_totals        jsonb;
  v_grand         numeric;
  v_subtotal      numeric;
  v_gst           numeric;
  v_per_grand     numeric;
  v_per_subtotal  numeric;
  v_per_gst       numeric;
  v_last_grand    numeric;
  v_last_sub      numeric;
  v_last_gst      numeric;
  v_session_id    uuid := gen_random_uuid();
  v_first_bill    uuid;
  v_inv_no        text;
  v_bill_id       uuid;
  v_sub_i         numeric;
  v_gst_i         numeric;
  v_grand_i       numeric;
  v_label         text;
  i               int;
  v_bills_out     jsonb := '[]'::jsonb;
  v_meta          jsonb;
  v_pay           text;
  v_name          text;
  v_phone         text;
  v_phone_norm    text;
  v_cid           uuid;
  v_ro_phone_norm text;
  v_status        text;
  v_paid          numeric;
  v_balance       numeric;
  v_global_pay    text;
BEGIN
  -- Validate basic params
  IF p_n_ways IS NULL OR p_n_ways < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_n_ways',
      'message', 'Must split into at least 2');
  END IF;
  IF p_n_ways > 50 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_splits',
      'message', 'Max 50 splits per bill');
  END IF;

  v_global_pay := _sbp_split_normalize_pay(p_payment_mode);
  IF v_global_pay IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode',
      'message', 'payment_mode must be Cash/UPI/Card/Credit');
  END IF;

  -- Validate p_splits shape if provided
  IF p_splits IS NOT NULL THEN
    IF jsonb_typeof(p_splits) <> 'array' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'splits_must_be_array');
    END IF;
    IF jsonb_array_length(p_splits) <> p_n_ways THEN
      RETURN jsonb_build_object('ok', false, 'error', 'splits_length_mismatch',
        'message', 'p_splits length must equal p_n_ways');
    END IF;
  END IF;

  -- Load + lock RO
  SELECT * INTO v_ro FROM sbp_running_orders
   WHERE id = p_order_id AND status = 'open'
   FOR UPDATE;

  IF v_ro.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found_or_closed');
  END IF;
  v_shop_id := v_ro.shop_id;

  IF NOT _sbp_check_shop_owner(v_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  IF jsonb_array_length(v_ro.items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_items_to_split');
  END IF;

  -- Compute totals
  v_totals   := _sbp_ro_compute_totals(v_ro.items);
  v_grand    := (v_totals->>'grand_total')::numeric;
  v_subtotal := (v_totals->>'subtotal')::numeric;
  v_gst      := (v_totals->>'gst_amount')::numeric;

  IF v_grand <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'zero_total');
  END IF;

  -- Per-split values
  v_per_subtotal := ROUND(v_subtotal / p_n_ways, 2);
  v_per_gst      := ROUND(v_gst / p_n_ways, 2);
  v_per_grand    := ROUND(v_grand / p_n_ways, 2);

  -- Last absorbs round-off
  v_last_sub   := v_subtotal - v_per_subtotal * (p_n_ways - 1);
  v_last_gst   := v_gst      - v_per_gst      * (p_n_ways - 1);
  v_last_grand := v_grand    - v_per_grand    * (p_n_ways - 1);

  -- Normalise RO phone for customer_id reuse check
  v_ro_phone_norm := sbp_normalize_phone(v_ro.cust_phone);

  -- Generate N bills
  FOR i IN 1..p_n_ways LOOP
    IF i = p_n_ways THEN
      v_sub_i   := v_last_sub;
      v_gst_i   := v_last_gst;
      v_grand_i := v_last_grand;
    ELSE
      v_sub_i   := v_per_subtotal;
      v_gst_i   := v_per_gst;
      v_grand_i := v_per_grand;
    END IF;

    -- Resolve per-split metadata
    IF p_splits IS NOT NULL THEN
      v_meta  := p_splits->(i - 1);
      v_pay   := _sbp_split_normalize_pay(v_meta->>'payment_mode');
      v_name  := NULLIF(trim(COALESCE(v_meta->>'customer_name', '')), '');
      v_phone := NULLIF(trim(COALESCE(v_meta->>'customer_phone', '')), '');
    ELSE
      v_meta  := NULL;
      v_pay   := v_global_pay;
      -- Fall back: prefill first split from RO customer
      IF i = 1 THEN
        v_name  := v_ro.cust_name;
        v_phone := v_ro.cust_phone;
      ELSE
        v_name  := NULL;
        v_phone := NULL;
      END IF;
    END IF;

    IF v_pay IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode',
        'split_index', i, 'message', 'payment_mode must be Cash/UPI/Card/Credit');
    END IF;

    -- Credit requires a customer name
    IF v_pay = 'Credit' AND v_name IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'credit_requires_customer',
        'split_index', i,
        'message', 'Credit splits need a customer name');
    END IF;

    -- Customer_id resolution
    v_cid        := NULL;
    v_phone_norm := sbp_normalize_phone(v_phone);
    IF v_phone_norm IS NOT NULL AND v_phone_norm = v_ro_phone_norm THEN
      v_cid := v_ro.customer_id;
    ELSIF v_phone_norm IS NOT NULL AND v_name IS NOT NULL THEN
      BEGIN
        v_cid := sbp_resolve_customer_for_booking(
                   v_shop_id, v_name, v_phone, v_phone, NULL);
      EXCEPTION WHEN OTHERS THEN
        v_cid := NULL;
      END;
    END IF;

    -- Payment status / amounts
    IF v_pay = 'Credit' THEN
      v_status  := 'Credit';
      v_paid    := 0;
      v_balance := v_grand_i;
    ELSE
      v_status  := 'Paid';
      v_paid    := v_grand_i;
      v_balance := 0;
    END IF;

    v_inv_no := _sbp_alloc_invoice_no(v_shop_id);
    v_label  := 'Equal share (' || i || ' of ' || p_n_ways || ')';

    INSERT INTO bills (
      shop_id, invoice_no, invoice_date,
      customer_name, customer_wa, customer_id,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      status, payment_mode, bill_mode,
      table_number, table_session_id,
      split_kind, split_index, split_total_ways, split_session_id,
      covers, server_user_id, server_name,
      notes
    ) VALUES (
      v_shop_id, v_inv_no, CURRENT_DATE,
      v_name, v_phone, v_cid,
      v_sub_i, v_gst_i, 0, v_grand_i,
      v_paid, v_balance,
      v_status, v_pay, 'pos',
      v_ro.table_number, v_ro.id,
      'equal', i, p_n_ways, v_session_id,
      CASE WHEN v_ro.covers IS NULL THEN NULL
           WHEN i = p_n_ways THEN v_ro.covers - (v_ro.covers / p_n_ways) * (p_n_ways - 1)
           ELSE v_ro.covers / p_n_ways
      END,
      v_ro.server_user_id, v_ro.server_name,
      'Split-equal from T' || v_ro.table_number
    )
    RETURNING id INTO v_bill_id;

    INSERT INTO bill_items (
      bill_id, item_name, qty, rate, gst_rate, discount,
      line_total, gst_amount, kind, unit
    ) VALUES (
      v_bill_id, v_label, 1, v_sub_i,
      CASE WHEN v_sub_i > 0 THEN ROUND(v_gst_i / v_sub_i * 100, 2) ELSE 0 END,
      0, v_sub_i, v_gst_i, 'split_share', 'share'
    );

    IF i = 1 THEN v_first_bill := v_bill_id; END IF;

    v_bills_out := v_bills_out || jsonb_build_object(
      'bill_id',     v_bill_id,
      'invoice_no',  v_inv_no,
      'grand_total', v_grand_i,
      'payment_mode', v_pay,
      'status',      v_status,
      'customer_name', v_name
    );
  END LOOP;

  -- Mark RO billed
  UPDATE sbp_running_orders
  SET status     = 'billed',
      bill_id    = v_first_bill,
      billed_at  = now(),
      updated_at = now()
  WHERE id = p_order_id;

  -- Free table
  IF v_ro.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status = 'free', current_bill_id = NULL, updated_at = now()
    WHERE id = v_ro.table_id AND shop_id = v_shop_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'split_kind', 'equal',
    'split_session_id', v_session_id,
    'n_ways', p_n_ways,
    'original_total', v_grand,
    'bills', v_bills_out
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_ro_split_equal(uuid, int, jsonb, text) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 2. sbp_ro_split_custom — p_amounts elements may be number OR object
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_ro_split_custom(uuid, jsonb, text);

CREATE OR REPLACE FUNCTION sbp_ro_split_custom(
  p_order_id     uuid,
  p_amounts      jsonb,
  p_payment_mode text DEFAULT 'Cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ro            sbp_running_orders%ROWTYPE;
  v_shop_id       uuid;
  v_n             int;
  v_totals        jsonb;
  v_grand         numeric;
  v_subtotal      numeric;
  v_gst           numeric;
  v_amt_sum       numeric := 0;
  v_amt_i         numeric;
  v_sub_i         numeric;
  v_gst_i         numeric;
  v_session_id    uuid := gen_random_uuid();
  v_first_bill    uuid;
  v_inv_no        text;
  v_bill_id       uuid;
  v_label         text;
  v_eff_gst_rate  numeric;
  i               int;
  v_bills_out     jsonb := '[]'::jsonb;
  v_is_object     boolean;
  v_el            jsonb;
  v_pay           text;
  v_name          text;
  v_phone         text;
  v_phone_norm    text;
  v_cid           uuid;
  v_ro_phone_norm text;
  v_status        text;
  v_paid          numeric;
  v_balance       numeric;
  v_global_pay    text;
BEGIN
  IF p_amounts IS NULL OR jsonb_typeof(p_amounts) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amounts_must_be_array');
  END IF;
  v_n := jsonb_array_length(p_amounts);
  IF v_n < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'need_at_least_2_amounts');
  END IF;
  IF v_n > 50 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_splits');
  END IF;

  v_global_pay := _sbp_split_normalize_pay(p_payment_mode);
  IF v_global_pay IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode');
  END IF;

  -- Shape detect
  v_is_object := (jsonb_typeof(p_amounts->0) = 'object');

  -- Sum amounts (per shape)
  FOR i IN 0..v_n-1 LOOP
    IF v_is_object THEN
      v_amt_i := (p_amounts->i->>'amount')::numeric;
    ELSE
      v_amt_i := (p_amounts->>i)::numeric;
    END IF;
    IF v_amt_i IS NULL OR v_amt_i <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount',
        'split_index', i + 1,
        'message', 'All amounts must be positive numbers');
    END IF;
    v_amt_sum := v_amt_sum + v_amt_i;
  END LOOP;

  -- Load + lock RO
  SELECT * INTO v_ro FROM sbp_running_orders
   WHERE id = p_order_id AND status = 'open'
   FOR UPDATE;

  IF v_ro.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found_or_closed');
  END IF;
  v_shop_id := v_ro.shop_id;

  IF NOT _sbp_check_shop_owner(v_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  v_totals   := _sbp_ro_compute_totals(v_ro.items);
  v_grand    := (v_totals->>'grand_total')::numeric;
  v_subtotal := (v_totals->>'subtotal')::numeric;
  v_gst      := (v_totals->>'gst_amount')::numeric;

  IF v_grand <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'zero_total');
  END IF;

  IF ABS(v_amt_sum - v_grand) > 0.01 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'amounts_mismatch',
      'message', 'Amounts sum (' || v_amt_sum || ') must equal bill total (' || v_grand || ')',
      'amount_sum', v_amt_sum,
      'bill_total', v_grand
    );
  END IF;

  v_eff_gst_rate := CASE WHEN v_subtotal > 0 THEN v_gst / v_subtotal * 100 ELSE 0 END;
  v_ro_phone_norm := sbp_normalize_phone(v_ro.cust_phone);

  -- Generate bills
  FOR i IN 0..v_n-1 LOOP
    v_el := p_amounts->i;
    IF v_is_object THEN
      v_amt_i := (v_el->>'amount')::numeric;
      v_pay   := _sbp_split_normalize_pay(v_el->>'payment_mode');
      v_name  := NULLIF(trim(COALESCE(v_el->>'customer_name', '')), '');
      v_phone := NULLIF(trim(COALESCE(v_el->>'customer_phone', '')), '');
    ELSE
      v_amt_i := (v_el)::text::numeric;
      v_pay   := v_global_pay;
      IF i = 0 THEN
        v_name  := v_ro.cust_name;
        v_phone := v_ro.cust_phone;
      ELSE
        v_name  := NULL;
        v_phone := NULL;
      END IF;
    END IF;

    IF v_pay IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode',
        'split_index', i + 1);
    END IF;
    IF v_pay = 'Credit' AND v_name IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'credit_requires_customer',
        'split_index', i + 1,
        'message', 'Credit splits need a customer name');
    END IF;

    -- GST proportional
    v_gst_i := ROUND(v_gst * v_amt_i / v_grand, 2);
    v_sub_i := ROUND(v_amt_i - v_gst_i, 2);

    -- Last absorbs paise round-off
    IF i = v_n - 1 THEN
      v_gst_i := v_gst - (SELECT COALESCE(SUM((b.gst_amount)::numeric), 0)
                          FROM bills b WHERE b.split_session_id = v_session_id);
      v_sub_i := v_amt_i - v_gst_i;
    END IF;

    -- Customer resolution
    v_cid        := NULL;
    v_phone_norm := sbp_normalize_phone(v_phone);
    IF v_phone_norm IS NOT NULL AND v_phone_norm = v_ro_phone_norm THEN
      v_cid := v_ro.customer_id;
    ELSIF v_phone_norm IS NOT NULL AND v_name IS NOT NULL THEN
      BEGIN
        v_cid := sbp_resolve_customer_for_booking(
                   v_shop_id, v_name, v_phone, v_phone, NULL);
      EXCEPTION WHEN OTHERS THEN
        v_cid := NULL;
      END;
    END IF;

    -- Payment status
    IF v_pay = 'Credit' THEN
      v_status  := 'Credit'; v_paid := 0;       v_balance := v_amt_i;
    ELSE
      v_status  := 'Paid';   v_paid := v_amt_i; v_balance := 0;
    END IF;

    v_inv_no := _sbp_alloc_invoice_no(v_shop_id);
    v_label  := 'Custom share (' || (i+1) || ' of ' || v_n || ')';

    INSERT INTO bills (
      shop_id, invoice_no, invoice_date,
      customer_name, customer_wa, customer_id,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      status, payment_mode, bill_mode,
      table_number, table_session_id,
      split_kind, split_index, split_total_ways, split_session_id,
      covers, server_user_id, server_name,
      notes
    ) VALUES (
      v_shop_id, v_inv_no, CURRENT_DATE,
      v_name, v_phone, v_cid,
      v_sub_i, v_gst_i, 0, v_amt_i,
      v_paid, v_balance,
      v_status, v_pay, 'pos',
      v_ro.table_number, v_ro.id,
      'custom', i+1, v_n, v_session_id,
      CASE WHEN v_ro.covers IS NULL THEN NULL
           WHEN i = v_n - 1 THEN v_ro.covers - (v_ro.covers / v_n) * (v_n - 1)
           ELSE v_ro.covers / v_n
      END,
      v_ro.server_user_id, v_ro.server_name,
      'Split-custom from T' || v_ro.table_number
    )
    RETURNING id INTO v_bill_id;

    INSERT INTO bill_items (
      bill_id, item_name, qty, rate, gst_rate, discount,
      line_total, gst_amount, kind, unit
    ) VALUES (
      v_bill_id, v_label, 1, v_sub_i, v_eff_gst_rate,
      0, v_sub_i, v_gst_i, 'split_share', 'share'
    );

    IF i = 0 THEN v_first_bill := v_bill_id; END IF;

    v_bills_out := v_bills_out || jsonb_build_object(
      'bill_id', v_bill_id,
      'invoice_no', v_inv_no,
      'grand_total', v_amt_i,
      'payment_mode', v_pay,
      'status', v_status,
      'customer_name', v_name
    );
  END LOOP;

  UPDATE sbp_running_orders
  SET status = 'billed', bill_id = v_first_bill,
      billed_at = now(), updated_at = now()
  WHERE id = p_order_id;

  IF v_ro.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status = 'free', current_bill_id = NULL, updated_at = now()
    WHERE id = v_ro.table_id AND shop_id = v_shop_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'split_kind', 'custom',
    'split_session_id', v_session_id,
    'n_ways', v_n,
    'original_total', v_grand,
    'bills', v_bills_out
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_ro_split_custom(uuid, jsonb, text) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 3. sbp_ro_split_by_item — read optional metadata from group objects
-- ════════════════════════════════════════════════════════════════════
-- p_groups element shape (all fields except item_ids are optional):
--   { item_ids: [uuid, ...],
--     label:           text,
--     customer_name:   text,
--     customer_phone:  text,
--     payment_mode:    'Cash'|'UPI'|'Card'|'Credit' }

DROP FUNCTION IF EXISTS sbp_ro_split_by_item(uuid, jsonb, text);

CREATE OR REPLACE FUNCTION sbp_ro_split_by_item(
  p_order_id     uuid,
  p_groups       jsonb,
  p_payment_mode text DEFAULT 'Cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ro             sbp_running_orders%ROWTYPE;
  v_shop_id        uuid;
  v_n              int;
  v_totals         jsonb;
  v_grand          numeric;
  v_session_id     uuid := gen_random_uuid();
  v_first_bill     uuid;
  v_inv_no         text;
  v_bill_id        uuid;
  v_label          text;
  v_group          jsonb;
  v_item_ids       jsonb;
  v_grp_subtotal   numeric;
  v_grp_gst        numeric;
  v_grp_grand      numeric;
  v_grp_count      int;
  v_assigned_ids   jsonb := '[]'::jsonb;
  v_all_assigned   jsonb := '[]'::jsonb;
  i                int;
  it               jsonb;
  v_item_id        text;
  v_qty            numeric;
  v_rate           numeric;
  v_gst_rate       numeric;
  v_line_total     numeric;
  v_line_gst       numeric;
  v_bills_out      jsonb := '[]'::jsonb;
  v_pay            text;
  v_name           text;
  v_phone          text;
  v_phone_norm     text;
  v_cid            uuid;
  v_ro_phone_norm  text;
  v_status         text;
  v_paid           numeric;
  v_balance        numeric;
  v_global_pay     text;
BEGIN
  IF p_groups IS NULL OR jsonb_typeof(p_groups) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'groups_must_be_array');
  END IF;
  v_n := jsonb_array_length(p_groups);
  IF v_n < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'need_at_least_2_groups');
  END IF;
  IF v_n > 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_groups');
  END IF;

  v_global_pay := _sbp_split_normalize_pay(p_payment_mode);
  IF v_global_pay IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode');
  END IF;

  -- Validate group shape
  FOR i IN 0..v_n-1 LOOP
    v_group := p_groups->i;
    IF jsonb_typeof(v_group) <> 'object' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_must_be_object',
        'split_index', i + 1);
    END IF;
    v_item_ids := COALESCE(v_group->'item_ids', '[]'::jsonb);
    IF jsonb_typeof(v_item_ids) <> 'array' OR jsonb_array_length(v_item_ids) = 0 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'group_needs_item_ids',
        'split_index', i + 1);
    END IF;
    -- Aggregate for duplicate-assignment check
    FOR it IN SELECT jsonb_array_elements(v_item_ids) LOOP
      IF v_all_assigned @> jsonb_build_array(it) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'item_assigned_twice',
          'item_id', it,
          'message', 'Each item can be assigned to only one person');
      END IF;
      v_all_assigned := v_all_assigned || jsonb_build_array(it);
    END LOOP;
  END LOOP;

  -- Load + lock RO
  SELECT * INTO v_ro FROM sbp_running_orders
   WHERE id = p_order_id AND status = 'open'
   FOR UPDATE;

  IF v_ro.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found_or_closed');
  END IF;
  v_shop_id := v_ro.shop_id;

  IF NOT _sbp_check_shop_owner(v_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  v_totals := _sbp_ro_compute_totals(v_ro.items);
  v_grand  := (v_totals->>'grand_total')::numeric;
  IF v_grand <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'zero_total');
  END IF;

  v_ro_phone_norm := sbp_normalize_phone(v_ro.cust_phone);

  -- Generate bills
  FOR i IN 0..v_n-1 LOOP
    v_group        := p_groups->i;
    v_item_ids     := v_group->'item_ids';
    v_grp_subtotal := 0;
    v_grp_gst      := 0;
    v_grp_count    := 0;
    v_label        := COALESCE(NULLIF(trim(v_group->>'label'), ''),
                               'Person ' || (i+1)) ||
                      ' (' || (i+1) || ' of ' || v_n || ')';

    -- Per-split metadata
    v_pay   := _sbp_split_normalize_pay(v_group->>'payment_mode');
    IF v_group->>'payment_mode' IS NULL THEN v_pay := v_global_pay; END IF;
    v_name  := NULLIF(trim(COALESCE(v_group->>'customer_name', '')), '');
    v_phone := NULLIF(trim(COALESCE(v_group->>'customer_phone', '')), '');

    -- Fall back: first split gets RO customer if no override
    IF v_name IS NULL AND v_phone IS NULL AND i = 0 THEN
      v_name  := v_ro.cust_name;
      v_phone := v_ro.cust_phone;
    END IF;

    IF v_pay IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode',
        'split_index', i + 1);
    END IF;
    IF v_pay = 'Credit' AND v_name IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'credit_requires_customer',
        'split_index', i + 1);
    END IF;

    -- Customer resolution
    v_cid        := NULL;
    v_phone_norm := sbp_normalize_phone(v_phone);
    IF v_phone_norm IS NOT NULL AND v_phone_norm = v_ro_phone_norm THEN
      v_cid := v_ro.customer_id;
    ELSIF v_phone_norm IS NOT NULL AND v_name IS NOT NULL THEN
      BEGIN
        v_cid := sbp_resolve_customer_for_booking(
                   v_shop_id, v_name, v_phone, v_phone, NULL);
      EXCEPTION WHEN OTHERS THEN
        v_cid := NULL;
      END;
    END IF;

    v_inv_no := _sbp_alloc_invoice_no(v_shop_id);

    INSERT INTO bills (
      shop_id, invoice_no, invoice_date,
      customer_name, customer_wa, customer_id,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      status, payment_mode, bill_mode,
      table_number, table_session_id,
      split_kind, split_index, split_total_ways, split_session_id,
      covers, server_user_id, server_name,
      notes
    ) VALUES (
      v_shop_id, v_inv_no, CURRENT_DATE,
      v_name, v_phone, v_cid,
      0, 0, 0, 0,
      0, 0,
      'Paid', v_pay, 'pos',
      v_ro.table_number, v_ro.id,
      'item', i+1, v_n, v_session_id,
      CASE WHEN v_ro.covers IS NULL THEN NULL
           WHEN i = v_n - 1 THEN v_ro.covers - (v_ro.covers / v_n) * (v_n - 1)
           ELSE v_ro.covers / v_n
      END,
      v_ro.server_user_id, v_ro.server_name,
      'Split-item from T' || v_ro.table_number
    )
    RETURNING id INTO v_bill_id;

    -- Per-item bill_items inserts
    FOR it IN SELECT jsonb_array_elements(v_ro.items) LOOP
      v_item_id := COALESCE(it->>'item_id', it->>'id');
      IF v_item_id IS NULL THEN CONTINUE; END IF;
      IF COALESCE((it->>'voided')::boolean, false) THEN CONTINUE; END IF;
      IF NOT v_item_ids @> to_jsonb(v_item_id) THEN CONTINUE; END IF;

      v_qty        := COALESCE((it->>'qty')::numeric, (it->>'q')::numeric, 1);
      v_rate       := COALESCE((it->>'price')::numeric, (it->>'rate')::numeric, (it->>'r')::numeric, 0);
      v_gst_rate   := COALESCE((it->>'gst_rate')::numeric, 0);
      v_line_total := COALESCE((it->>'line_total')::numeric, ROUND(v_qty * v_rate, 2));
      v_line_gst   := COALESCE((it->>'gst_amount')::numeric,
                               (it->>'lineGST')::numeric,
                               ROUND(v_line_total * v_gst_rate / 100, 2));

      INSERT INTO bill_items (
        bill_id, item_name, qty, rate, gst_rate, discount,
        line_total, gst_amount, kind, product_id, service_id, unit
      ) VALUES (
        v_bill_id,
        COALESCE(it->>'name', it->>'item_name', it->>'nm', 'Item'),
        v_qty, v_rate, v_gst_rate, 0,
        v_line_total, v_line_gst,
        COALESCE(it->>'kind', 'product'),
        NULLIF(it->>'product_id', '')::uuid,
        NULLIF(it->>'service_id', '')::uuid,
        COALESCE(it->>'unit', 'piece')
      );

      v_grp_subtotal := v_grp_subtotal + v_line_total;
      v_grp_gst      := v_grp_gst + v_line_gst;
      v_grp_count    := v_grp_count + 1;
    END LOOP;

    v_grp_grand := ROUND(v_grp_subtotal + v_grp_gst, 2);

    -- Final amounts + status based on payment_mode
    IF v_pay = 'Credit' THEN
      v_status := 'Credit'; v_paid := 0;           v_balance := v_grp_grand;
    ELSE
      v_status := 'Paid';   v_paid := v_grp_grand; v_balance := 0;
    END IF;

    UPDATE bills SET
      subtotal    = ROUND(v_grp_subtotal, 2),
      gst_amount  = ROUND(v_grp_gst, 2),
      grand_total = v_grp_grand,
      paid_amount = v_paid,
      balance_due = v_balance,
      status      = v_status
    WHERE id = v_bill_id;

    IF i = 0 THEN v_first_bill := v_bill_id; END IF;

    v_bills_out := v_bills_out || jsonb_build_object(
      'bill_id',      v_bill_id,
      'invoice_no',   v_inv_no,
      'grand_total',  v_grp_grand,
      'item_count',   v_grp_count,
      'payment_mode', v_pay,
      'status',       v_status,
      'customer_name', v_name
    );
  END LOOP;

  UPDATE sbp_running_orders
  SET status = 'billed', bill_id = v_first_bill,
      billed_at = now(), updated_at = now()
  WHERE id = p_order_id;

  IF v_ro.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status = 'free', current_bill_id = NULL, updated_at = now()
    WHERE id = v_ro.table_id AND shop_id = v_shop_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'split_kind', 'item',
    'split_session_id', v_session_id,
    'n_ways', v_n,
    'original_total', v_grand,
    'bills', v_bills_out
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_ro_split_by_item(uuid, jsonb, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
