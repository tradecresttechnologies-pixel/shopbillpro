-- ════════════════════════════════════════════════════════════════════
-- 103_split_customer_and_covers.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   v7.0.1 quality hotfix for migration 100. Two display bugs on the
--   bills produced by Bill Split:
--
--   1. Customer name slot showed the share label
--      ("Equal share (1 of 2)") instead of the actual customer name.
--      cust_phone and customer_id were dropped entirely.
--
--   2. Covers (guest count) was copied from the running order in full
--      to each split. A 4-person table split 2 ways printed "Covers: 4"
--      on both bills.
--
-- WHY
--   In migration 100 the INSERTs into bills used v_label
--   (the share label) for customer_name, and v_ro.covers (the total)
--   verbatim for every split row. I forgot to carry forward
--   sbp_running_orders.cust_name / cust_phone / customer_id, which mig
--   076 added precisely for this purpose. And covers was a thinko —
--   the total has to be apportioned across splits like grand_total is.
--
-- WHAT'S FIXED
--   For all 3 split RPCs (sbp_ro_split_equal / sbp_ro_split_custom /
--   sbp_ro_split_by_item):
--
--   • customer_name  ← v_ro.cust_name   (NULL = walk-in, renders as "—")
--   • customer_wa    ← v_ro.cust_phone
--   • customer_id    ← v_ro.customer_id (links bill to customer record)
--   • covers         ← proportional: each split gets v_ro.covers / N,
--                     the last split absorbs the remainder. NULL stays
--                     NULL. Integer-division, paise-style allocation.
--
-- WHAT'S NOT FIXED (v7.1)
--   • payment_mode  — still hard-coded to p_payment_mode (defaulting
--                     to 'cash') because the split modal has no
--                     per-split picker yet. Tracked in v7.1.
--   • status        — still 'Paid' (auto-settled) for the same reason.
--   • per-split customer entry — needs UI work in the split modal.
--
-- ACTION
--   Drop and re-create the 3 split RPCs. Idempotent.
--   No table changes. No data migration.
--
-- DEPLOY
--   1. Run this file in Supabase SQL Editor.
--   2. Refresh PostgREST (NOTIFY at end handles it).
--   3. Retry a split on a table that had a customer attached
--      (use sbp_ro_set_customer first if needed) — verify the bill
--      shows the customer name, not the share label, and covers are
--      apportioned, not duplicated.
--
-- ROLLBACK
--   Re-run migration 100 — reintroduces the bug but is safe.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_ro_split_equal(uuid, int, text);
CREATE OR REPLACE FUNCTION sbp_ro_split_equal(
  p_order_id     uuid,
  p_n_ways       int,
  p_payment_mode text DEFAULT 'cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ro          sbp_running_orders%ROWTYPE;
  v_shop_id     uuid;
  v_totals      jsonb;
  v_grand       numeric;
  v_subtotal    numeric;
  v_gst         numeric;
  v_per_grand   numeric;
  v_per_subtotal numeric;
  v_per_gst     numeric;
  v_last_grand  numeric;
  v_last_sub    numeric;
  v_last_gst    numeric;
  v_session_id  uuid := gen_random_uuid();
  v_first_bill  uuid;
  v_inv_no      text;
  v_bill_id     uuid;
  v_sub_i       numeric;
  v_gst_i       numeric;
  v_grand_i     numeric;
  v_label       text;
  i             int;
  v_bills_out   jsonb := '[]'::jsonb;
BEGIN
  -- Validate
  IF p_n_ways IS NULL OR p_n_ways < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_n_ways', 'message', 'Must split into at least 2');
  END IF;
  IF p_n_ways > 50 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_splits', 'message', 'Max 50 splits per bill');
  END IF;

  -- Load + lock RO
  SELECT * INTO v_ro FROM sbp_running_orders
   WHERE id = p_order_id
     AND status = 'open'
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

  -- Per-split values (rounded to paise). Last split absorbs round-off.
  v_per_subtotal := ROUND(v_subtotal / p_n_ways, 2);
  v_per_gst      := ROUND(v_gst / p_n_ways, 2);
  v_per_grand    := ROUND(v_grand / p_n_ways, 2);

  -- Last split = total - (n-1)*per. Exact reconciliation to paise.
  v_last_sub   := v_subtotal - v_per_subtotal * (p_n_ways - 1);
  v_last_gst   := v_gst      - v_per_gst      * (p_n_ways - 1);
  v_last_grand := v_grand    - v_per_grand    * (p_n_ways - 1);

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
      v_ro.cust_name, v_ro.cust_phone, v_ro.customer_id,
      v_sub_i, v_gst_i, 0, v_grand_i,
      v_grand_i, 0,
      'Paid', p_payment_mode, 'pos',
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

    -- Bill item: single summary line
    INSERT INTO bill_items (
      bill_id, item_name, qty, rate, gst_rate, discount,
      line_total, gst_amount, kind, unit
    ) VALUES (
      v_bill_id, v_label, 1, v_sub_i,
      CASE WHEN v_sub_i > 0 THEN ROUND(v_gst_i / v_sub_i * 100, 2) ELSE 0 END,
      0, v_sub_i, v_gst_i, 'split_share', 'share'
    );

    IF i = 1 THEN
      v_first_bill := v_bill_id;
    END IF;

    v_bills_out := v_bills_out || jsonb_build_object(
      'bill_id', v_bill_id,
      'invoice_no', v_inv_no,
      'grand_total', v_grand_i
    );
  END LOOP;

  -- Mark RO as billed, pointing to first split for back-compat
  UPDATE sbp_running_orders
  SET status     = 'billed',
      bill_id    = v_first_bill,
      billed_at  = now(),
      updated_at = now()
  WHERE id = p_order_id;

  -- Free the table
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

GRANT EXECUTE ON FUNCTION sbp_ro_split_equal(uuid, int, text) TO authenticated;

DROP FUNCTION IF EXISTS sbp_ro_split_custom(uuid, jsonb, text);
CREATE OR REPLACE FUNCTION sbp_ro_split_custom(
  p_order_id     uuid,
  p_amounts      jsonb,
  p_payment_mode text DEFAULT 'cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ro          sbp_running_orders%ROWTYPE;
  v_shop_id     uuid;
  v_totals      jsonb;
  v_grand       numeric;
  v_subtotal    numeric;
  v_gst         numeric;
  v_amt_sum     numeric := 0;
  v_n           int;
  v_session_id  uuid := gen_random_uuid();
  v_first_bill  uuid;
  v_inv_no      text;
  v_bill_id     uuid;
  v_amt_i       numeric;
  v_sub_i       numeric;
  v_gst_i       numeric;
  v_label       text;
  v_eff_gst_rate numeric;
  i             int;
  v_bills_out   jsonb := '[]'::jsonb;
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

  -- Sum validation: must equal RO total to the paise
  FOR i IN 0..v_n-1 LOOP
    v_amt_i := (p_amounts->>i)::numeric;
    IF v_amt_i IS NULL OR v_amt_i <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_amount',
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

  -- Reconciliation check: amounts must sum to grand total (paise precision)
  IF ABS(v_amt_sum - v_grand) > 0.01 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'amounts_mismatch',
      'message', 'Amounts sum (' || v_amt_sum || ') must equal bill total (' || v_grand || ')',
      'amount_sum', v_amt_sum,
      'bill_total', v_grand
    );
  END IF;

  -- Effective GST rate for proportional allocation
  v_eff_gst_rate := CASE WHEN v_subtotal > 0 THEN v_gst / v_subtotal * 100 ELSE 0 END;

  -- Generate bills
  FOR i IN 0..v_n-1 LOOP
    v_amt_i := (p_amounts->>i)::numeric;

    -- Allocate GST proportionally: bill's share of grand → bill's share of GST
    v_gst_i := ROUND(v_gst * v_amt_i / v_grand, 2);
    v_sub_i := ROUND(v_amt_i - v_gst_i, 2);

    -- Last bill absorbs paise round-off
    IF i = v_n - 1 THEN
      v_gst_i := v_gst - (SELECT COALESCE(SUM((b.gst_amount)::numeric), 0)
                          FROM bills b WHERE b.split_session_id = v_session_id);
      v_sub_i := v_amt_i - v_gst_i;
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
      v_ro.cust_name, v_ro.cust_phone, v_ro.customer_id,
      v_sub_i, v_gst_i, 0, v_amt_i,
      v_amt_i, 0,
      'Paid', p_payment_mode, 'pos',
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
      'grand_total', v_amt_i
    );
  END LOOP;

  -- Close RO + free table
  UPDATE sbp_running_orders
  SET status='billed', bill_id=v_first_bill, billed_at=now(), updated_at=now()
  WHERE id = p_order_id;

  IF v_ro.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status='free', current_bill_id=NULL, updated_at=now()
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

DROP FUNCTION IF EXISTS sbp_ro_split_by_item(uuid, jsonb, text);
CREATE OR REPLACE FUNCTION sbp_ro_split_by_item(
  p_order_id     uuid,
  p_groups       jsonb,
  p_payment_mode text DEFAULT 'cash'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ro          sbp_running_orders%ROWTYPE;
  v_shop_id     uuid;
  v_n           int;
  v_session_id  uuid := gen_random_uuid();
  v_first_bill  uuid;
  v_inv_no      text;
  v_bill_id     uuid;
  v_group       jsonb;
  v_label       text;
  v_item_ids    jsonb;
  v_assigned    jsonb := '[]'::jsonb;
  v_all_item_ids jsonb := '[]'::jsonb;
  v_grp_subtotal numeric;
  v_grp_gst     numeric;
  v_grp_grand   numeric;
  v_grp_count   int;
  it            jsonb;
  v_qty         numeric;
  v_rate        numeric;
  v_gst_rate    numeric;
  v_line_total  numeric;
  v_line_gst    numeric;
  v_item_id     text;
  i             int;
  v_bills_out   jsonb := '[]'::jsonb;
BEGIN
  IF p_groups IS NULL OR jsonb_typeof(p_groups) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'groups_must_be_array');
  END IF;
  v_n := jsonb_array_length(p_groups);
  IF v_n < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'need_at_least_2_groups');
  END IF;

  -- Load + lock RO
  SELECT * INTO v_ro FROM sbp_running_orders
   WHERE id = p_order_id AND status = 'open' FOR UPDATE;
  IF v_ro.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found_or_closed');
  END IF;
  v_shop_id := v_ro.shop_id;

  IF NOT _sbp_check_shop_owner(v_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  -- Collect all non-voided RO item_ids
  FOR it IN SELECT jsonb_array_elements(v_ro.items)
  LOOP
    IF NOT COALESCE((it->>'voided')::boolean, false) THEN
      v_item_id := COALESCE(it->>'item_id', it->>'id');
      IF v_item_id IS NOT NULL THEN
        v_all_item_ids := v_all_item_ids || to_jsonb(v_item_id);
      END IF;
    END IF;
  END LOOP;

  -- Validation: collect all item_ids from groups, ensure they cover the RO exactly
  FOR i IN 0..v_n-1 LOOP
    v_group := p_groups->i;
    v_item_ids := COALESCE(v_group->'item_ids', '[]'::jsonb);
    IF jsonb_typeof(v_item_ids) <> 'array' OR jsonb_array_length(v_item_ids) = 0 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'empty_group',
        'message', 'Group ' || (i+1) || ' has no items');
    END IF;
    -- Append to assigned set (will check for duplicates next)
    FOR it IN SELECT jsonb_array_elements(v_item_ids) LOOP
      IF v_assigned @> jsonb_build_array(it) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'item_assigned_twice',
          'message', 'Item ' || (it::text) || ' assigned to multiple groups');
      END IF;
      v_assigned := v_assigned || it;
    END LOOP;
  END LOOP;

  -- Every item in RO must be in some group
  IF jsonb_array_length(v_assigned) <> jsonb_array_length(v_all_item_ids) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'items_not_fully_covered',
      'message', 'All items must be assigned to a group',
      'ro_count', jsonb_array_length(v_all_item_ids),
      'group_count', jsonb_array_length(v_assigned));
  END IF;

  -- Generate bills
  FOR i IN 0..v_n-1 LOOP
    v_group    := p_groups->i;
    v_label    := COALESCE(v_group->>'label', 'Group ' || (i+1));
    v_item_ids := v_group->'item_ids';
    v_grp_subtotal := 0;
    v_grp_gst      := 0;
    v_grp_count    := 0;

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
      v_ro.cust_name, v_ro.cust_phone, v_ro.customer_id,
      0, 0, 0, 0,
      0, 0,
      'Paid', p_payment_mode, 'pos',
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

    -- Insert bill_items for each item assigned to this group
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

    -- Update bill totals
    UPDATE bills SET
      subtotal    = ROUND(v_grp_subtotal, 2),
      gst_amount  = ROUND(v_grp_gst, 2),
      grand_total = v_grp_grand,
      paid_amount = v_grp_grand
    WHERE id = v_bill_id;

    IF i = 0 THEN v_first_bill := v_bill_id; END IF;

    v_bills_out := v_bills_out || jsonb_build_object(
      'bill_id', v_bill_id,
      'invoice_no', v_inv_no,
      'label', v_label,
      'grand_total', v_grp_grand,
      'item_count', v_grp_count
    );
  END LOOP;

  -- Close RO + free table
  UPDATE sbp_running_orders
  SET status='billed', bill_id=v_first_bill, billed_at=now(), updated_at=now()
  WHERE id = p_order_id;

  IF v_ro.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status='free', current_bill_id=NULL, updated_at=now()
    WHERE id = v_ro.table_id AND shop_id = v_shop_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'split_kind', 'item',
    'split_session_id', v_session_id,
    'n_ways', v_n,
    'bills', v_bills_out
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_ro_split_by_item(uuid, jsonb, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
