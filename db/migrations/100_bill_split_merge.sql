-- ════════════════════════════════════════════════════════════════════
-- 100_bill_split_merge.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   Bill split (3 modes) + table merge (combine RO + move single item).
--
--   SPLIT (each split becomes a fully independent bill with own invoice_no):
--     • sbp_ro_split_equal(p_order_id, p_n_ways, p_payment_mode)
--         Divides total equally into N bills. Each bill has ONE line:
--         "Equal share (1 of N)". Paise round-off absorbed by the LAST split.
--     • sbp_ro_split_custom(p_order_id, p_amounts jsonb, p_payment_mode)
--         Splits by custom amounts. amounts is jsonb array of numerics.
--         MUST sum to running-order total exactly (to the paise).
--     • sbp_ro_split_by_item(p_order_id, p_groups jsonb, p_payment_mode)
--         Splits by item assignment. Each group = one bill with its items.
--         groups is jsonb array: [{label, item_ids:[uuid,...]}, ...]
--         Every non-voided RO item must belong to exactly one group.
--
--   MERGE:
--     • sbp_ro_merge_into(p_source_order_id, p_dest_order_id)
--         Moves all items from source RO into dest RO, frees source table.
--     • sbp_ro_move_item(p_source_order_id, p_dest_order_id, p_item_id)
--         Moves single item from source RO into dest RO. Both stay open.
--
-- ARCHITECTURE DECISIONS (locked May 2026 per session spec)
--   • Each split = INDEPENDENT bill with own invoice_no (audit clean)
--   • Splits track lineage via new columns on `bills`:
--       split_kind ('equal'|'custom'|'item'), split_index, split_total_ways
--       split_session_id (uuid grouping siblings — reuses table_session_id pattern)
--   • Original running order marked 'billed', bill_id points to FIRST split
--     (so existing reports/queries continue to work; siblings findable via
--     table_session_id which all splits share)
--   • Stock NOT touched on split — it was already deducted when items were
--     added to the running order. Splits are paper-divisions.
--   • GST reconciles to the paise: SUM(split.grand_total) == RO total exactly.
--   • Invoice numbers allocated atomically via existing next_invoice_no RPC.
--
-- DEPENDENCIES
--   • bills, bill_items, sbp_running_orders, shops, sbp_restaurant_tables
--   • next_invoice_no(shop_id) RPC (from migration 025)
--   • _sbp_check_shop_owner helper
--
-- DEPLOY
--   1. Run this migration
--   2. Replace running-order.html (adds 3 split modes + merge button)
--   3. Replace tables.html (merge into picker)
--   4. (Optional) bills.html update to show split lineage
--
-- ROLLBACK
--   DROP FUNCTION IF EXISTS sbp_ro_split_equal(uuid, int, text);
--   DROP FUNCTION IF EXISTS sbp_ro_split_custom(uuid, jsonb, text);
--   DROP FUNCTION IF EXISTS sbp_ro_split_by_item(uuid, jsonb, text);
--   DROP FUNCTION IF EXISTS sbp_ro_merge_into(uuid, uuid);
--   DROP FUNCTION IF EXISTS sbp_ro_move_item(uuid, uuid, text);
--   ALTER TABLE bills
--     DROP COLUMN IF EXISTS split_kind,
--     DROP COLUMN IF EXISTS split_index,
--     DROP COLUMN IF EXISTS split_total_ways,
--     DROP COLUMN IF EXISTS split_session_id;
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 0. SCHEMA SAFETY CHECKS ───────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('public.bills') IS NULL THEN
    RAISE EXCEPTION 'bills table missing — abort';
  END IF;
  IF to_regclass('public.bill_items') IS NULL THEN
    RAISE EXCEPTION 'bill_items table missing — abort';
  END IF;
  IF to_regclass('public.sbp_running_orders') IS NULL THEN
    RAISE EXCEPTION 'sbp_running_orders table missing — abort';
  END IF;
  -- next_invoice_no must exist (from migration 025)
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'next_invoice_no'
  ) THEN
    RAISE EXCEPTION 'next_invoice_no RPC missing — run migration 025 first';
  END IF;
END $$;

-- ── 1. AUDIT LINEAGE COLUMNS ON BILLS ─────────────────────────────
ALTER TABLE bills
  ADD COLUMN IF NOT EXISTS split_kind        text,
  ADD COLUMN IF NOT EXISTS split_index       int,
  ADD COLUMN IF NOT EXISTS split_total_ways  int,
  ADD COLUMN IF NOT EXISTS split_session_id  uuid;

COMMENT ON COLUMN bills.split_kind       IS 'NULL for normal bill; equal|custom|item if this bill was a split';
COMMENT ON COLUMN bills.split_index      IS '1-based position of this split among siblings';
COMMENT ON COLUMN bills.split_total_ways IS 'How many splits total were generated together';
COMMENT ON COLUMN bills.split_session_id IS 'Shared uuid linking all siblings of one split operation';

-- Index for "find all siblings of this split"
CREATE INDEX IF NOT EXISTS idx_bills_split_session
  ON bills(shop_id, split_session_id)
  WHERE split_session_id IS NOT NULL;

-- Check constraint: split_kind must be valid when set
DO $$
BEGIN
  ALTER TABLE bills DROP CONSTRAINT IF EXISTS chk_bills_split_kind;
  ALTER TABLE bills ADD CONSTRAINT chk_bills_split_kind
    CHECK (split_kind IS NULL OR split_kind IN ('equal','custom','item'));
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'split_kind constraint skipped: %', SQLERRM;
END $$;

-- ── 2. HELPER: Compute totals from running-order items jsonb ──────
-- Each item: {item_id, name, qty, price (or rate), gst_rate, voided?, ...}
-- Returns: {subtotal, gst_amount, grand_total, item_count}
DROP FUNCTION IF EXISTS _sbp_ro_compute_totals(jsonb);
CREATE OR REPLACE FUNCTION _sbp_ro_compute_totals(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_subtotal   numeric := 0;
  v_gst        numeric := 0;
  v_count      int := 0;
  v_qty        numeric;
  v_rate       numeric;
  v_gst_rate   numeric;
  v_line_total numeric;
  it           jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('subtotal',0,'gst_amount',0,'grand_total',0,'item_count',0);
  END IF;

  FOR it IN SELECT jsonb_array_elements(p_items)
  LOOP
    IF COALESCE((it->>'voided')::boolean, false) THEN CONTINUE; END IF;

    v_qty      := COALESCE((it->>'qty')::numeric, (it->>'q')::numeric, 1);
    v_rate     := COALESCE((it->>'price')::numeric, (it->>'rate')::numeric, (it->>'r')::numeric, 0);
    v_gst_rate := COALESCE((it->>'gst_rate')::numeric, (it->>'rate')::numeric, 0);
    -- If item has explicit line_total/gst_amount fields use them; else compute.
    v_line_total := COALESCE((it->>'line_total')::numeric, (it->>'tot')::numeric, v_qty * v_rate);

    v_subtotal := v_subtotal + v_line_total;
    -- Some items store gst inline (lineGST); else derive from gst_rate
    v_gst := v_gst + COALESCE((it->>'lineGST')::numeric,
                              (it->>'gst_amount')::numeric,
                              ROUND(v_line_total * v_gst_rate / 100, 2));
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'subtotal',    ROUND(v_subtotal, 2),
    'gst_amount',  ROUND(v_gst, 2),
    'grand_total', ROUND(v_subtotal + v_gst, 2),
    'item_count',  v_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION _sbp_ro_compute_totals(jsonb) TO authenticated;

-- ── 3. HELPER: Allocate next invoice number INTO a text value ─────
-- Wraps next_invoice_no for simpler use inside other RPCs.
-- Returns "INV-0042" style string.
DROP FUNCTION IF EXISTS _sbp_alloc_invoice_no(uuid);
CREATE OR REPLACE FUNCTION _sbp_alloc_invoice_no(p_shop_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix  text;
  v_counter int;
BEGIN
  SELECT invoice_prefix, invoice_counter
    INTO v_prefix, v_counter
  FROM next_invoice_no(p_shop_id);
  RETURN COALESCE(v_prefix, 'INV') || '-' || LPAD(v_counter::text, 4, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION _sbp_alloc_invoice_no(uuid) TO authenticated;

-- ── 4. SPLIT EQUAL ────────────────────────────────────────────────
-- Divides total into N equal bills. Each bill: 1 line item "Equal share (i/N)".
-- Round-off absorbed by the LAST split so SUM(splits) == original exactly.
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
      customer_name, items_count,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      status, payment_mode, bill_mode,
      table_number, table_session_id,
      split_kind, split_index, split_total_ways, split_session_id,
      covers, server_user_id, server_name,
      notes
    ) VALUES (
      v_shop_id, v_inv_no, CURRENT_DATE,
      v_label, 1,
      v_sub_i, v_gst_i, 0, v_grand_i,
      v_grand_i, 0,
      'Paid', p_payment_mode, 'pos',
      v_ro.table_number, v_ro.id,
      'equal', i, p_n_ways, v_session_id,
      v_ro.covers, v_ro.server_user_id, v_ro.server_name,
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

-- ── 5. SPLIT CUSTOM ───────────────────────────────────────────────
-- p_amounts is jsonb array of grand-total amounts. Sum MUST equal RO total.
-- Each split gets ONE line "Custom share (i/N)" with their grand amount.
-- GST allocated proportionally to each split's amount.
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
      customer_name, items_count,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      status, payment_mode, bill_mode,
      table_number, table_session_id,
      split_kind, split_index, split_total_ways, split_session_id,
      covers, server_user_id, server_name,
      notes
    ) VALUES (
      v_shop_id, v_inv_no, CURRENT_DATE,
      v_label, 1,
      v_sub_i, v_gst_i, 0, v_amt_i,
      v_amt_i, 0,
      'Paid', p_payment_mode, 'pos',
      v_ro.table_number, v_ro.id,
      'custom', i+1, v_n, v_session_id,
      v_ro.covers, v_ro.server_user_id, v_ro.server_name,
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

-- ── 6. SPLIT BY ITEM ──────────────────────────────────────────────
-- p_groups: jsonb array of {label: "Vinay", item_ids: ["uuid", "uuid", ...]}
-- Every non-voided item in RO must belong to exactly one group.
-- Each group becomes a bill with ITS items (proper itemization).
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
      customer_name, items_count,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      status, payment_mode, bill_mode,
      table_number, table_session_id,
      split_kind, split_index, split_total_ways, split_session_id,
      covers, server_user_id, server_name,
      notes
    ) VALUES (
      v_shop_id, v_inv_no, CURRENT_DATE,
      v_label, 0,  -- items_count updated after item inserts
      0, 0, 0, 0,
      0, 0,
      'Paid', p_payment_mode, 'pos',
      v_ro.table_number, v_ro.id,
      'item', i+1, v_n, v_session_id,
      v_ro.covers, v_ro.server_user_id, v_ro.server_name,
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
      items_count = v_grp_count,
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

-- ── 7. MERGE INTO (combine all items source → dest, free source table) ─
DROP FUNCTION IF EXISTS sbp_ro_merge_into(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_ro_merge_into(
  p_source_order_id uuid,
  p_dest_order_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src   sbp_running_orders%ROWTYPE;
  v_dest  sbp_running_orders%ROWTYPE;
  v_merged_items jsonb;
  v_merged_kots  jsonb;
  v_total_kots   int;
BEGIN
  IF p_source_order_id = p_dest_order_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_merge_into_self');
  END IF;

  -- Lock both ROs (deterministic order to prevent deadlocks)
  IF p_source_order_id < p_dest_order_id THEN
    SELECT * INTO v_src  FROM sbp_running_orders WHERE id = p_source_order_id FOR UPDATE;
    SELECT * INTO v_dest FROM sbp_running_orders WHERE id = p_dest_order_id   FOR UPDATE;
  ELSE
    SELECT * INTO v_dest FROM sbp_running_orders WHERE id = p_dest_order_id   FOR UPDATE;
    SELECT * INTO v_src  FROM sbp_running_orders WHERE id = p_source_order_id FOR UPDATE;
  END IF;

  IF v_src.id IS NULL OR v_dest.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;
  IF v_src.shop_id <> v_dest.shop_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_mismatch');
  END IF;
  IF v_src.status <> 'open' OR v_dest.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_open');
  END IF;

  IF NOT _sbp_check_shop_owner(v_src.shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  -- Concat items + kots (items may have round numbers — keep source rounds as-is)
  v_merged_items := v_dest.items || v_src.items;
  v_merged_kots  := v_dest.kots  || v_src.kots;
  v_total_kots   := v_dest.kot_count + v_src.kot_count;

  -- Update dest with combined items
  UPDATE sbp_running_orders
  SET items      = v_merged_items,
      kots       = v_merged_kots,
      kot_count  = v_total_kots,
      notes      = COALESCE(v_dest.notes, '') ||
                   CASE WHEN v_dest.notes IS NOT NULL AND v_dest.notes <> '' THEN E'\n' ELSE '' END ||
                   'Merged from T' || v_src.table_number ||
                   ' on ' || to_char(now() AT TIME ZONE 'Asia/Kolkata', 'HH24:MI'),
      updated_at = now()
  WHERE id = p_dest_order_id;

  -- Void source RO (status='void' is valid per check constraint)
  UPDATE sbp_running_orders
  SET status     = 'void',
      notes      = COALESCE(notes, '') ||
                   CASE WHEN notes IS NOT NULL AND notes <> '' THEN E'\n' ELSE '' END ||
                   'Merged into T' || v_dest.table_number,
      updated_at = now()
  WHERE id = p_source_order_id;

  -- Free source table
  IF v_src.table_id IS NOT NULL THEN
    UPDATE sbp_restaurant_tables
    SET status='free', current_bill_id=NULL, updated_at=now()
    WHERE id = v_src.table_id AND shop_id = v_src.shop_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'merged_into',  p_dest_order_id,
    'merged_from',  p_source_order_id,
    'item_count',   jsonb_array_length(v_merged_items),
    'dest_table',   v_dest.table_number,
    'src_table',    v_src.table_number
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_ro_merge_into(uuid, uuid) TO authenticated;

-- ── 8. MOVE SINGLE ITEM (granular: move one line item between ROs) ──
-- Both ROs stay open. Item identified by item_id within source's items jsonb.
DROP FUNCTION IF EXISTS sbp_ro_move_item(uuid, uuid, text);
CREATE OR REPLACE FUNCTION sbp_ro_move_item(
  p_source_order_id uuid,
  p_dest_order_id   uuid,
  p_item_id         text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_src   sbp_running_orders%ROWTYPE;
  v_dest  sbp_running_orders%ROWTYPE;
  v_item  jsonb := NULL;
  v_remaining jsonb := '[]'::jsonb;
  it      jsonb;
BEGIN
  IF p_source_order_id = p_dest_order_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_move_to_self');
  END IF;
  IF p_item_id IS NULL OR p_item_id = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'item_id_required');
  END IF;

  -- Lock both ROs deterministically
  IF p_source_order_id < p_dest_order_id THEN
    SELECT * INTO v_src  FROM sbp_running_orders WHERE id = p_source_order_id FOR UPDATE;
    SELECT * INTO v_dest FROM sbp_running_orders WHERE id = p_dest_order_id   FOR UPDATE;
  ELSE
    SELECT * INTO v_dest FROM sbp_running_orders WHERE id = p_dest_order_id   FOR UPDATE;
    SELECT * INTO v_src  FROM sbp_running_orders WHERE id = p_source_order_id FOR UPDATE;
  END IF;

  IF v_src.id IS NULL OR v_dest.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_found');
  END IF;
  IF v_src.shop_id <> v_dest.shop_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_mismatch');
  END IF;
  IF v_src.status <> 'open' OR v_dest.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'order_not_open');
  END IF;

  IF NOT _sbp_check_shop_owner(v_src.shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  -- Find and remove item from source
  FOR it IN SELECT jsonb_array_elements(v_src.items)
  LOOP
    IF COALESCE(it->>'item_id', it->>'id') = p_item_id THEN
      v_item := it;
    ELSE
      v_remaining := v_remaining || it;
    END IF;
  END LOOP;

  IF v_item IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'item_not_found',
      'message', 'Item ' || p_item_id || ' not found in source order');
  END IF;

  -- Update source: items without the moved item
  UPDATE sbp_running_orders
  SET items      = v_remaining,
      updated_at = now()
  WHERE id = p_source_order_id;

  -- Update dest: append the item
  UPDATE sbp_running_orders
  SET items      = items || jsonb_build_array(v_item),
      updated_at = now()
  WHERE id = p_dest_order_id;

  RETURN jsonb_build_object(
    'ok', true,
    'moved_item_id', p_item_id,
    'from_table',    v_src.table_number,
    'to_table',      v_dest.table_number,
    'src_remaining', jsonb_array_length(v_remaining)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_ro_move_item(uuid, uuid, text) TO authenticated;

-- ── 9. HELPER FOR UI: List all open running orders for merge picker ──
DROP FUNCTION IF EXISTS sbp_ro_list_open(uuid);
CREATE OR REPLACE FUNCTION sbp_ro_list_open(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT _sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_id',     r.id,
    'table_id',     r.table_id,
    'table_number', r.table_number,
    'item_count',   jsonb_array_length(r.items),
    'opened_at',    r.opened_at
  ) ORDER BY r.table_number), '[]'::jsonb)
  INTO v_rows
  FROM sbp_running_orders r
  WHERE r.shop_id = p_shop_id AND r.status = 'open';

  RETURN jsonb_build_object('ok', true, 'orders', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_ro_list_open(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- POST-DEPLOY VERIFICATION
-- ════════════════════════════════════════════════════════════════════
-- 1. New columns:
--    SELECT split_kind, split_index, split_total_ways, split_session_id
--    FROM bills LIMIT 1;
--
-- 2. RPCs registered (expect 7 + helper):
--    SELECT proname FROM pg_proc WHERE proname IN (
--      '_sbp_ro_compute_totals', '_sbp_alloc_invoice_no',
--      'sbp_ro_split_equal', 'sbp_ro_split_custom', 'sbp_ro_split_by_item',
--      'sbp_ro_merge_into', 'sbp_ro_move_item', 'sbp_ro_list_open'
--    );
--    -- Expected: 8 rows
--
-- 3. Reconciliation test (after a real equal-split):
--    SELECT split_session_id,
--           SUM(grand_total) AS total_split,
--           split_total_ways
--    FROM bills
--    WHERE split_session_id IS NOT NULL
--    GROUP BY split_session_id, split_total_ways
--    ORDER BY MAX(created_at) DESC LIMIT 1;
--    -- total_split should match the original RO total to the paise
-- ════════════════════════════════════════════════════════════════════
