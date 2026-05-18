-- ════════════════════════════════════════════════════════════════════
-- 080_restaurant_drill.sql
-- ════════════════════════════════════════════════════════════════════
-- Click-through drill for the restaurant report (locked with Vinay):
-- existing sections stay as-is; rows become clickable and drill DOWN.
--
--   Level 1 (section row)  → Level 2: bills for that dimension
--   Level 2 (a bill row)   → Level 3: that bill's line items
--
-- ONE RPC, two modes:
--   mode='bills'  + p_dim/p_val → list of bills matching the dimension
--                  dims: 'table' | 'server' | 'category' | 'item'
--                        | 'payment' | 'day'  (value = the row's key)
--   mode='items'  + p_bill_id  → line items of that one bill
--
-- Owner-checked, read-only, exception-safe, IST. Dine-in scope =
-- bills.table_number IS NOT NULL & not voided (same rule as the
-- report engine). Columns verified: bills.invoice_no, grand_total,
-- created_at, payment_mode, server_name, cust_name, covers,
-- table_number; bill_items.item_name, qty, rate, line_total,
-- gst_amount, kind.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_restaurant_drill(uuid, text, text, text, uuid, date, date);

CREATE OR REPLACE FUNCTION sbp_restaurant_drill(
  p_shop_id uuid,
  p_mode    text,                       -- 'bills' | 'items'
  p_dim     text DEFAULT NULL,          -- for mode='bills'
  p_val     text DEFAULT NULL,          -- the clicked row's key
  p_bill_id uuid DEFAULT NULL,          -- for mode='items'
  p_from    date DEFAULT NULL,
  p_to      date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_from date := COALESCE(p_from, (CURRENT_DATE - INTERVAL '30 days')::date);
  v_to   date := COALESCE(p_to, CURRENT_DATE);
  v_dim  text := lower(NULLIF(trim(COALESCE(p_dim,'')),''));
  v_val  text := NULLIF(trim(COALESCE(p_val,'')),'');
  v_out  jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  -- ── Level 3: items of one bill ────────────────────────────────────
  IF lower(COALESCE(p_mode,'')) = 'items' THEN
    IF p_bill_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'bill_id_required');
    END IF;

    SELECT jsonb_build_object(
      'ok', true,
      'mode', 'items',
      'bill', (
        SELECT jsonb_build_object(
          'invoice_no',   b.invoice_no,
          'table',        b.table_number,
          'covers',       b.covers,
          'server',       b.server_name,
          'customer',     COALESCE(b.cust_name, b.customer_name),
          'payment_mode', b.payment_mode,
          'grand_total',  b.grand_total,
          'gst',          COALESCE(b.gst_amount,0),
          'discount',     COALESCE(b.discount,0),
          'at', to_char(b.created_at AT TIME ZONE 'Asia/Kolkata',
                        'YYYY-MM-DD HH24:MI'))
        FROM bills b
        WHERE b.id = p_bill_id AND b.shop_id = p_shop_id
      ),
      'items', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'name',     bi.item_name,
            'category', COALESCE(NULLIF(trim(bi.kind),''),'Uncategorised'),
            'qty',      bi.qty,
            'rate',     bi.rate,
            'gst',      COALESCE(bi.gst_amount,0),
            'total',    bi.line_total)
          ORDER BY bi.id)
        FROM bill_items bi
        WHERE bi.bill_id = p_bill_id
      ), '[]'::jsonb)
    ) INTO v_out;

    -- bill must belong to this shop (null bill block above only
    -- catches missing id; this catches wrong-shop)
    IF (v_out->'bill') IS NULL OR v_out->'bill' = 'null'::jsonb THEN
      RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
    END IF;
    RETURN v_out;
  END IF;

  -- ── Level 2: bills for a clicked dimension ────────────────────────
  IF lower(COALESCE(p_mode,'')) = 'bills' THEN
    IF v_dim IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'dim_required');
    END IF;

    SELECT jsonb_build_object(
      'ok', true,
      'mode', 'bills',
      'dim',  v_dim,
      'val',  v_val,
      'bills', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'bill_id',      b.id,
            'invoice_no',   b.invoice_no,
            'table',        b.table_number,
            'covers',       b.covers,
            'server',       b.server_name,
            'customer',     COALESCE(b.cust_name, b.customer_name),
            'payment_mode', b.payment_mode,
            'grand_total',  b.grand_total,
            'at', to_char(b.created_at AT TIME ZONE 'Asia/Kolkata',
                          'YYYY-MM-DD HH24:MI'))
          ORDER BY b.created_at DESC)
        FROM bills b
        WHERE b.shop_id = p_shop_id
          AND b.invoice_date >= v_from
          AND b.invoice_date <= v_to
          AND b.table_number IS NOT NULL
          AND COALESCE(LOWER(b.status),'') <> 'voided'
          AND b.voided_at IS NULL
          AND (
            CASE v_dim
              WHEN 'table'   THEN b.table_number = v_val
              WHEN 'server'  THEN COALESCE(NULLIF(trim(b.server_name),''),
                                           'Unattributed') = v_val
              WHEN 'payment' THEN COALESCE(b.payment_mode,'Unknown') = v_val
              WHEN 'day'     THEN b.invoice_date::text = v_val
              WHEN 'item'    THEN EXISTS (
                                    SELECT 1 FROM bill_items x
                                    WHERE x.bill_id = b.id
                                      AND x.item_name = v_val)
              WHEN 'category' THEN EXISTS (
                                    SELECT 1 FROM bill_items x
                                    WHERE x.bill_id = b.id
                                      AND COALESCE(NULLIF(trim(x.kind),''),
                                          'Uncategorised') = v_val)
              ELSE false
            END
          )
      ), '[]'::jsonb)
    ) INTO v_out;

    RETURN v_out;
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'bad_mode',
    'detail', 'p_mode must be ''bills'' or ''items''');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception',
    'detail', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
END;
$$;

REVOKE ALL ON FUNCTION sbp_restaurant_drill(uuid, text, text, text, uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_restaurant_drill(uuid, text, text, text, uuid, date, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
