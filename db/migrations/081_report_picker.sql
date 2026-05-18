-- ════════════════════════════════════════════════════════════════════
-- 081_report_picker.sql
-- ════════════════════════════════════════════════════════════════════
-- Picker model (locked with Vinay): user picks ONE report from a
-- grouped dropdown, sets date + filters, presses Run → only that
-- report is computed/returned, with its own Print. "Show Everything"
-- remains available.
--
-- DESIGN — wrapper, do NOT rewrite the working 300-line engine.
--   sbp_restaurant_report (079, 6-arg) stays EXACTLY as is and keeps
--   working for the "Show Everything" view (back-compat, zero risk).
--   This migration adds:
--     1. sbp_restaurant_report_one(shop, report, from, to, cat, item,
--        table) — calls the full engine, returns ONLY the requested
--        section + always-needed meta (ok, range, filters,
--        filter_options). Less data over the wire; the picker calls
--        this. report='all' → passes the whole payload through.
--     2. A NEW 'discount_detail' section (per-bill discount list) —
--        the only genuinely new computation, surfaced via the wrapper
--        so the heavy engine is left untouched.
--     3. sbp_restaurant_void_report already standalone — wrapper
--        recognises report IN ('void','void_audit') and tells the UI
--        to call that RPC instead (returns a small redirect marker).
--
-- Owner-checked (engine already checks; wrapper double-checks cheaply),
-- read-only, exception-safe.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_restaurant_report_one(uuid, text, date, date, text, text, text);

CREATE OR REPLACE FUNCTION sbp_restaurant_report_one(
  p_shop_id  uuid,
  p_report   text,
  p_from     date DEFAULT NULL,
  p_to       date DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_item     text DEFAULT NULL,
  p_table    text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_full   jsonb;
  v_rep    text := lower(NULLIF(trim(COALESCE(p_report,'')),''));
  v_from   date := COALESCE(p_from, (CURRENT_DATE - INTERVAL '30 days')::date);
  v_to     date := COALESCE(p_to, CURRENT_DATE);
  v_key    text;
  v_out    jsonb;
  v_disc   jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  IF v_rep IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'report_required');
  END IF;

  -- Void/audit live in their own RPC — tell the UI to call it.
  IF v_rep IN ('void','void_audit','void_delete') THEN
    RETURN jsonb_build_object(
      'ok', true, 'use_rpc', 'sbp_restaurant_void_report',
      'report', v_rep);
  END IF;

  -- Compute the full payload once (engine unchanged). For single
  -- reports this is the simplest correct approach; the saving is in
  -- payload size returned + the UI rendering only one report.
  v_full := public.sbp_restaurant_report(
              p_shop_id, v_from, v_to, p_category, p_item, p_table);

  IF v_full IS NULL OR COALESCE((v_full->>'ok')::boolean, false) = false THEN
    RETURN COALESCE(v_full,
      jsonb_build_object('ok', false, 'error', 'engine_returned_null'));
  END IF;

  -- "Show Everything" → pass the whole thing through unchanged.
  IF v_rep IN ('all','everything','dashboard') THEN
    RETURN v_full;
  END IF;

  -- Map picker id → engine section key.
  v_key := CASE v_rep
    WHEN 'sales_summary'      THEN 'sales_summary'
    WHEN 'daily_trend'        THEN 'daily_trend'
    WHEN 'day_part'           THEN 'day_part'
    WHEN 'payment_split'      THEN 'payment_split'
    WHEN 'discount'           THEN 'discounts'
    WHEN 'tax_summary'        THEN 'tax_summary'
    WHEN 'itemised'           THEN 'top_items'      -- + bottom_items below
    WHEN 'category_mix'       THEN 'category_mix'
    WHEN 'per_table'          THEN 'per_table'
    WHEN 'per_section'        THEN 'per_section'
    WHEN 'turnaround'         THEN 'table_turnaround'
    WHEN 'server'             THEN 'server_performance'
    WHEN 'kot'                THEN 'kot_analysis'
    WHEN 'qr_funnel'          THEN 'qr_funnel'
    WHEN 'day_close'          THEN 'day_close'
    WHEN 'open_tables'        THEN 'open_tables'
    ELSE NULL
  END;

  IF v_key IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_report',
      'report', v_rep);
  END IF;

  -- Base envelope: always carry meta the picker UI needs.
  v_out := jsonb_build_object(
    'ok', true,
    'report', v_rep,
    'range', v_full->'range',
    'filters', v_full->'filters',
    'filter_options', v_full->'filter_options'
  );

  -- Attach just the requested section.
  v_out := v_out || jsonb_build_object(v_key, v_full->v_key);

  -- Itemised also needs the slow movers + a combined view.
  IF v_rep = 'itemised' THEN
    v_out := v_out || jsonb_build_object(
      'bottom_items', v_full->'bottom_items');
  END IF;

  -- Discount report: enrich with a per-bill discount detail list
  -- (the one new computation; engine left untouched).
  IF v_rep = 'discount' THEN
    SELECT COALESCE(jsonb_agg(
             jsonb_build_object(
               'invoice_no',  b.invoice_no,
               'at', to_char(b.created_at AT TIME ZONE 'Asia/Kolkata',
                             'YYYY-MM-DD HH24:MI'),
               'table',       b.table_number,
               'grand_total', b.grand_total,
               'discount',    COALESCE(b.discount,0),
               'disc_pct',    CASE WHEN COALESCE(b.grand_total,0) > 0
                                THEN ROUND(COALESCE(b.discount,0)
                                  / (b.grand_total + COALESCE(b.discount,0))
                                  * 100, 1)
                                ELSE 0 END)
             ORDER BY b.created_at DESC), '[]'::jsonb)
      INTO v_disc
      FROM bills b
      WHERE b.shop_id = p_shop_id
        AND b.invoice_date >= v_from AND b.invoice_date <= v_to
        AND b.table_number IS NOT NULL
        AND COALESCE(LOWER(b.status),'') <> 'voided'
        AND b.voided_at IS NULL
        AND COALESCE(b.discount,0) > 0
        AND (NULLIF(trim(COALESCE(p_table,'')),'') IS NULL
             OR b.table_number = trim(p_table));
    v_out := v_out || jsonb_build_object('discount_detail', v_disc);
  END IF;

  RETURN v_out;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception',
    'detail', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
END;
$$;

REVOKE ALL ON FUNCTION sbp_restaurant_report_one(uuid, text, date, date, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_restaurant_report_one(uuid, text, date, date, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
