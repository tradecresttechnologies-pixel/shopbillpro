-- ════════════════════════════════════════════════════════════════════
-- 079_void_delete_report_and_filters.sql
-- ════════════════════════════════════════════════════════════════════
-- Two locked deliverables:
--  (1) sbp_restaurant_void_report — auditable Void & Delete report from
--      the REAL sbp_audit_log trail. Covers (per Vinay):
--        • bill.void        (whole bill voided)
--        • bill.void_item   (item-level void during service / KOT cancel)
--        • bill.delete      (bill deleted — audit of removal)
--        • bill.delete_item (item deleted from a bill)
--        • payment.void     (payment reversed)
--      Each row: when, action, bill/item, amount, who did it, reason,
--      who authorized + method. before_json/after_json shapes verified
--      from migrations 032/038 (no guessing).
--
--  (2) sbp_restaurant_report gains optional filters so the page can
--      drill: p_category (bill_items.kind), p_item (item_name),
--      p_table (table_number). NULL = no filter (back-compat: existing
--      3-arg behaviour preserved via DEFAULT NULLs). Filters apply to
--      the line-item + bill scoped sections; headline summary stays
--      whole-period so the user sees the filter's share of the total.
--
-- Owner-checked, read-only, exception-safe envelope, IST timestamps.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Void & Delete audit report ───────────────────────────────────
DROP FUNCTION IF EXISTS sbp_restaurant_void_report(uuid, date, date);

CREATE OR REPLACE FUNCTION sbp_restaurant_void_report(
  p_shop_id uuid,
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
  v_out  jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  WITH ev AS (
    SELECT
      a.recorded_at,
      a.action_code,
      a.actor_name,
      a.reason,
      a.authorized_by_name,
      a.auth_method,
      a.before_json AS bj,
      a.after_json  AS aj
    FROM sbp_audit_log a
    WHERE a.shop_id = p_shop_id
      AND a.action_code IN ('bill.void','bill.void_item',
                            'bill.delete','bill.delete_item','payment.void')
      AND (a.recorded_at AT TIME ZONE 'Asia/Kolkata')::date >= v_from
      AND (a.recorded_at AT TIME ZONE 'Asia/Kolkata')::date <= v_to
  ),
  -- Normalise each event into a flat reporting row. Amount/label
  -- extraction is per action_code using the verified before_json shape.
  rows AS (
    SELECT
      to_char(recorded_at AT TIME ZONE 'Asia/Kolkata',
              'YYYY-MM-DD HH24:MI') AS at_ist,
      recorded_at,
      action_code,
      CASE action_code
        WHEN 'bill.void'        THEN 'Bill voided'
        WHEN 'bill.delete'      THEN 'Bill deleted'
        WHEN 'bill.void_item'   THEN 'Item voided (in service)'
        WHEN 'bill.delete_item' THEN 'Item deleted'
        WHEN 'payment.void'     THEN 'Payment voided'
        ELSE action_code
      END AS action_label,
      -- Reference: invoice no for bill.* ; item name for *_item
      CASE
        WHEN action_code IN ('bill.void','bill.delete')
          THEN COALESCE(bj->>'invoice_no', bj->>'invoice_number', '—')
        WHEN action_code IN ('bill.void_item','bill.delete_item')
          THEN COALESCE(bj->>'item_name', '—')
        WHEN action_code = 'payment.void'
          THEN COALESCE(bj->>'invoice_no','payment','—')
        ELSE '—'
      END AS ref,
      -- Amount affected
      CASE
        WHEN action_code IN ('bill.void','bill.delete')
          THEN COALESCE((bj->>'grand_total')::numeric, 0)
        WHEN action_code IN ('bill.void_item','bill.delete_item')
          THEN COALESCE((bj->>'line_total')::numeric,
                        (bj->>'amount')::numeric, 0)
        WHEN action_code = 'payment.void'
          THEN COALESCE((bj->>'amount')::numeric,
                        (bj->>'paid_amount')::numeric, 0)
        ELSE 0
      END AS amount,
      COALESCE(NULLIF(trim(actor_name),''),'—')          AS actor,
      COALESCE(NULLIF(trim(reason),''),'—')              AS reason,
      COALESCE(NULLIF(trim(authorized_by_name),''),'—')  AS authorized_by,
      COALESCE(auth_method,'none')                       AS auth_method
    FROM ev
  )
  SELECT jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('from', v_from, 'to', v_to),

    -- Summary counts + value by action type
    'summary', (
      SELECT jsonb_build_object(
        'total_events',     COUNT(*),
        'bills_voided',     COUNT(*) FILTER (WHERE action_code='bill.void'),
        'bills_deleted',    COUNT(*) FILTER (WHERE action_code='bill.delete'),
        'items_voided',     COUNT(*) FILTER (WHERE action_code='bill.void_item'),
        'items_deleted',    COUNT(*) FILTER (WHERE action_code='bill.delete_item'),
        'payments_voided',  COUNT(*) FILTER (WHERE action_code='payment.void'),
        'total_value',      COALESCE(SUM(amount),0),
        'voided_value',     COALESCE(SUM(amount) FILTER (
                              WHERE action_code IN ('bill.void','bill.void_item')),0),
        'deleted_value',    COALESCE(SUM(amount) FILTER (
                              WHERE action_code IN ('bill.delete','bill.delete_item')),0)
      ) FROM rows
    ),

    -- By actor (who is voiding/deleting the most — control signal)
    'by_actor', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('actor', actor, 'events', events, 'value', value)
        ORDER BY value DESC)
      FROM (
        SELECT actor, COUNT(*) AS events, COALESCE(SUM(amount),0) AS value
        FROM rows GROUP BY actor
      ) y
    ), '[]'::jsonb),

    -- By reason (why)
    'by_reason', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('reason', reason, 'count', cnt)
        ORDER BY cnt DESC)
      FROM (
        SELECT reason, COUNT(*) AS cnt FROM rows GROUP BY reason
      ) y
    ), '[]'::jsonb),

    -- Full line-by-line trail (most recent first), capped to 500
    'events', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'at',            at_ist,
          'action',        action_label,
          'ref',           ref,
          'amount',        amount,
          'actor',         actor,
          'reason',        reason,
          'authorized_by', authorized_by,
          'auth_method',   auth_method)
        ORDER BY recorded_at DESC)
      FROM (SELECT * FROM rows ORDER BY recorded_at DESC LIMIT 500) z
    ), '[]'::jsonb)

  ) INTO v_out;

  RETURN v_out;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception',
    'detail', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
END;
$$;

REVOKE ALL ON FUNCTION sbp_restaurant_void_report(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_restaurant_void_report(uuid, date, date) TO authenticated;


-- ── 2. Filterable restaurant report ─────────────────────────────────
-- Adds p_category / p_item / p_table (all default NULL = no filter).
-- Old 3-arg callers keep working unchanged (defaults). The filter is
-- applied to the line-item CTE (ri) and the bill CTE (rb) so item /
-- category / table sections drill, while sales_summary still reflects
-- the FILTERED scope so the number matches what's shown.
DROP FUNCTION IF EXISTS sbp_restaurant_report(uuid, date, date);
DROP FUNCTION IF EXISTS sbp_restaurant_report(uuid, date, date, text, text, text);

CREATE OR REPLACE FUNCTION sbp_restaurant_report(
  p_shop_id  uuid,
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
  v_from date := COALESCE(p_from, (CURRENT_DATE - INTERVAL '30 days')::date);
  v_to   date := COALESCE(p_to, CURRENT_DATE);
  v_cat  text := NULLIF(trim(COALESCE(p_category,'')),'');
  v_item text := NULLIF(trim(COALESCE(p_item,'')),'');
  v_tbl  text := NULLIF(trim(COALESCE(p_table,'')),'');
  v_out  jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  WITH
  rb AS (
    SELECT b.*
    FROM bills b
    WHERE b.shop_id = p_shop_id
      AND b.invoice_date >= v_from
      AND b.invoice_date <= v_to
      AND b.table_number IS NOT NULL
      AND COALESCE(LOWER(b.status), '') <> 'voided'
      AND b.voided_at IS NULL
      AND (v_tbl IS NULL OR b.table_number = v_tbl)
      -- when filtering by item/category, restrict bills to those
      -- containing a matching line so bill-level sections stay coherent
      AND (
        (v_item IS NULL AND v_cat IS NULL)
        OR EXISTS (
          SELECT 1 FROM bill_items x
          WHERE x.bill_id = b.id
            AND (v_item IS NULL OR x.item_name = v_item)
            AND (v_cat  IS NULL OR COALESCE(NULLIF(trim(x.kind),''),'Uncategorised')
                                   = v_cat)
        )
      )
  ),
  vb AS (
    SELECT b.*
    FROM bills b
    WHERE b.shop_id = p_shop_id
      AND b.invoice_date >= v_from
      AND b.invoice_date <= v_to
      AND b.table_number IS NOT NULL
      AND (b.voided_at IS NOT NULL OR LOWER(COALESCE(b.status,'')) = 'voided')
      AND (v_tbl IS NULL OR b.table_number = v_tbl)
  ),
  ri AS (
    SELECT bi.*, b.invoice_date, b.created_at AS bill_created
    FROM bill_items bi
    JOIN rb b ON b.id = bi.bill_id
    WHERE (v_item IS NULL OR bi.item_name = v_item)
      AND (v_cat  IS NULL OR COALESCE(NULLIF(trim(bi.kind),''),'Uncategorised')
                             = v_cat)
  ),
  rs AS (
    SELECT r.*
    FROM sbp_running_orders r
    WHERE r.shop_id = p_shop_id
      AND r.billed_at IS NOT NULL
      AND r.billed_at::date >= v_from
      AND r.billed_at::date <= v_to
      AND (v_tbl IS NULL OR r.table_number = v_tbl)
  )
  SELECT jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('from', v_from, 'to', v_to),
    'filters', jsonb_build_object(
      'category', v_cat, 'item', v_item, 'table', v_tbl,
      -- when an item/category filter is on, session-level sections
      -- (turnaround/KOT) can't be meaningfully scoped per-item, and
      -- qr/day_close/audit are inherently whole-period. The UI uses
      -- this to label or hide them so numbers are never misleading.
      'item_or_cat_active', (v_cat IS NOT NULL OR v_item IS NOT NULL),
      'any_active', (v_cat IS NOT NULL OR v_item IS NOT NULL OR v_tbl IS NOT NULL)),

    -- Filter option lists for the UI dropdowns (whole-period, unfiltered
    -- so the user can always pick any value). Derived from real data.
    'filter_options', jsonb_build_object(
      'categories', COALESCE((
        SELECT jsonb_agg(DISTINCT c ORDER BY c) FROM (
          SELECT COALESCE(NULLIF(trim(bi.kind),''),'Uncategorised') AS c
          FROM bill_items bi JOIN bills b ON b.id = bi.bill_id
          WHERE b.shop_id = p_shop_id AND b.table_number IS NOT NULL
            AND b.invoice_date >= v_from AND b.invoice_date <= v_to
            AND COALESCE(LOWER(b.status),'') <> 'voided'
        ) q), '[]'::jsonb),
      'items', COALESCE((
        SELECT jsonb_agg(DISTINCT i ORDER BY i) FROM (
          SELECT bi.item_name AS i
          FROM bill_items bi JOIN bills b ON b.id = bi.bill_id
          WHERE b.shop_id = p_shop_id AND b.table_number IS NOT NULL
            AND b.invoice_date >= v_from AND b.invoice_date <= v_to
            AND COALESCE(LOWER(b.status),'') <> 'voided'
        ) q), '[]'::jsonb),
      'tables', COALESCE((
        SELECT jsonb_agg(DISTINCT t ORDER BY t) FROM (
          SELECT b.table_number AS t
          FROM bills b
          WHERE b.shop_id = p_shop_id AND b.table_number IS NOT NULL
            AND b.invoice_date >= v_from AND b.invoice_date <= v_to
            AND COALESCE(LOWER(b.status),'') <> 'voided'
        ) q), '[]'::jsonb)
    ),

    'sales_summary', (
      SELECT jsonb_build_object(
        'bills',        COUNT(*),
        'gross',        COALESCE(SUM(grand_total), 0),
        'net',          COALESCE(SUM(grand_total - COALESCE(gst_amount,0)), 0),
        'discount',     COALESCE(SUM(COALESCE(discount,0)), 0),
        'gst',          COALESCE(SUM(COALESCE(gst_amount,0)), 0),
        'paid',         COALESCE(SUM(COALESCE(paid_amount,0)), 0),
        'balance_due',  COALESCE(SUM(COALESCE(balance_due,0)), 0),
        'covers',       COALESCE(SUM(COALESCE(covers,0)), 0),
        'aov',          CASE WHEN COUNT(*)>0
                          THEN ROUND(SUM(grand_total)/COUNT(*),2) ELSE 0 END,
        'rev_per_cover',CASE WHEN COALESCE(SUM(covers),0)>0
                          THEN ROUND(SUM(grand_total)/SUM(covers),2) ELSE NULL END
      ) FROM rb
    ),

    'daily_trend', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('date', d, 'bills', bills, 'gross', gross,
          'aov', CASE WHEN bills>0 THEN ROUND(gross/bills,2) ELSE 0 END)
        ORDER BY d)
      FROM (
        SELECT invoice_date AS d, COUNT(*) AS bills,
               COALESCE(SUM(grand_total),0) AS gross
        FROM rb GROUP BY invoice_date
      ) y
    ), '[]'::jsonb),

    'day_part', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('part', part, 'bills', bills, 'gross', gross)
        ORDER BY part)
      FROM (
        SELECT
          CASE
            WHEN h BETWEEN 6  AND 11 THEN '1 Breakfast (6-11)'
            WHEN h BETWEEN 12 AND 16 THEN '2 Lunch (12-16)'
            WHEN h BETWEEN 17 AND 21 THEN '3 Dinner (17-21)'
            ELSE '4 Late (22-5)' END AS part,
          COUNT(*) AS bills,
          COALESCE(SUM(grand_total),0) AS gross
        FROM (
          SELECT grand_total,
            EXTRACT(HOUR FROM (created_at AT TIME ZONE 'Asia/Kolkata'))::int AS h
          FROM rb
        ) hb
        GROUP BY 1
      ) y
    ), '[]'::jsonb),

    'payment_split', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('mode', mode, 'bills', bills, 'amount', amount)
        ORDER BY amount DESC)
      FROM (
        SELECT COALESCE(payment_mode,'Unknown') AS mode,
               COUNT(*) AS bills, COALESCE(SUM(grand_total),0) AS amount
        FROM rb GROUP BY payment_mode
      ) y
    ), '[]'::jsonb),

    'discounts', (
      SELECT jsonb_build_object(
        'total_discount', COALESCE(SUM(COALESCE(discount,0)),0),
        'bills_with_disc',COUNT(*) FILTER (WHERE COALESCE(discount,0) > 0),
        'avg_disc',       CASE WHEN COUNT(*) FILTER (WHERE COALESCE(discount,0)>0) > 0
                            THEN ROUND(SUM(COALESCE(discount,0))
                              / COUNT(*) FILTER (WHERE COALESCE(discount,0)>0),2)
                            ELSE 0 END
      ) FROM rb
    ),

    'tax_summary', (
      SELECT jsonb_build_object(
        'total_gst', COALESCE(SUM(COALESCE(gst_amount,0)),0),
        'cgst',      ROUND(COALESCE(SUM(COALESCE(gst_amount,0)),0)/2.0,2),
        'sgst',      ROUND(COALESCE(SUM(COALESCE(gst_amount,0)),0)/2.0,2),
        'taxable',   COALESCE(SUM(grand_total - COALESCE(gst_amount,0)),0)
      ) FROM rb
    ),

    'per_table', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('table', table_number, 'bills', bills,
          'covers', covers, 'gross', gross,
          'aov', CASE WHEN bills>0 THEN ROUND(gross/bills,2) ELSE 0 END)
        ORDER BY gross DESC)
      FROM (
        SELECT table_number, COUNT(*) AS bills,
               COALESCE(SUM(COALESCE(covers,0)),0) AS covers,
               COALESCE(SUM(grand_total),0) AS gross
        FROM rb GROUP BY table_number
      ) y
    ), '[]'::jsonb),

    'per_section', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('section', section, 'bills', bills, 'gross', gross)
        ORDER BY gross DESC)
      FROM (
        SELECT
          COALESCE(NULLIF(trim(t.section),''),'Main') AS section,
          COUNT(*) AS bills,
          COALESCE(SUM(b.grand_total),0) AS gross
        FROM rb b
        LEFT JOIN sbp_restaurant_tables t
          ON t.shop_id = p_shop_id AND t.table_number = b.table_number
        GROUP BY 1
      ) y
    ), '[]'::jsonb),

    'table_turnaround', (
      SELECT jsonb_build_object(
        'sessions', sessions, 'avg_minutes', avg_minutes, 'turns', sessions)
      FROM (
        SELECT COUNT(*) AS sessions,
          COALESCE(ROUND(AVG(
            EXTRACT(EPOCH FROM (billed_at - opened_at))/60.0)::numeric,1),0) AS avg_minutes
        FROM rs
      ) y
    ),

    'table_utilisation', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('table', table_number, 'turns', turns,
          'avg_minutes', avg_minutes)
        ORDER BY turns DESC)
      FROM (
        SELECT table_number, COUNT(*) AS turns,
          COALESCE(ROUND(AVG(
            EXTRACT(EPOCH FROM (billed_at - opened_at))/60.0)::numeric,1),0) AS avg_minutes
        FROM rs GROUP BY table_number
      ) y
    ), '[]'::jsonb),

    'server_performance', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('server', server, 'bills', bills, 'gross', gross,
          'covers', covers,
          'aov', CASE WHEN bills>0 THEN ROUND(gross/bills,2) ELSE 0 END)
        ORDER BY gross DESC)
      FROM (
        SELECT COALESCE(NULLIF(trim(server_name),''),'Unattributed') AS server,
               COUNT(*) AS bills, COALESCE(SUM(grand_total),0) AS gross,
               COALESCE(SUM(COALESCE(covers,0)),0) AS covers
        FROM rb GROUP BY 1
      ) y
    ), '[]'::jsonb),

    'top_items', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('name', name, 'qty', qty, 'revenue', revenue)
        ORDER BY revenue DESC NULLS LAST)
      FROM (
        SELECT item_name AS name, COALESCE(SUM(qty),0) AS qty,
               COALESCE(SUM(line_total),0) AS revenue
        FROM ri GROUP BY item_name
        ORDER BY SUM(line_total) DESC NULLS LAST LIMIT 25
      ) y
    ), '[]'::jsonb),

    'bottom_items', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('name', name, 'qty', qty, 'revenue', revenue)
        ORDER BY revenue ASC NULLS LAST)
      FROM (
        SELECT item_name AS name, COALESCE(SUM(qty),0) AS qty,
               COALESCE(SUM(line_total),0) AS revenue
        FROM ri GROUP BY item_name
        ORDER BY SUM(line_total) ASC NULLS LAST LIMIT 15
      ) y
    ), '[]'::jsonb),

    'category_mix', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('category', category, 'qty', qty, 'revenue', revenue)
        ORDER BY revenue DESC)
      FROM (
        SELECT COALESCE(NULLIF(trim(kind),''),'Uncategorised') AS category,
               COALESCE(SUM(qty),0) AS qty,
               COALESCE(SUM(line_total),0) AS revenue
        FROM ri GROUP BY 1
      ) y
    ), '[]'::jsonb),

    'voids', (
      SELECT jsonb_build_object(
        'voided_bills',  (SELECT COUNT(*) FROM vb),
        'voided_amount', (SELECT COALESCE(SUM(grand_total),0) FROM vb),
        'voided_items_value', COALESCE((
          SELECT SUM( (it->>'price')::numeric
                    * COALESCE((it->>'voided_qty')::numeric,0) )
          FROM rs s, jsonb_array_elements(COALESCE(s.items,'[]'::jsonb)) it
        ),0)
      )
    ),

    'kot_analysis', (
      SELECT jsonb_build_object(
        'sessions',   COUNT(*),
        'total_kots', COALESCE(SUM(COALESCE(kot_count,0)),0),
        'avg_kots',   CASE WHEN COUNT(*)>0
                        THEN ROUND(AVG(COALESCE(kot_count,0))::numeric,2) ELSE 0 END
      ) FROM rs
    ),

    'qr_funnel', (
      SELECT jsonb_build_object(
        'placed',   COUNT(*),
        'accepted', COUNT(*) FILTER (WHERE status='accepted' AND accepted_kot_no IS NOT NULL),
        'modified', COUNT(*) FILTER (WHERE status='accepted' AND accepted_kot_no IS NULL),
        'rejected', COUNT(*) FILTER (WHERE status='rejected'),
        'pending',  COUNT(*) FILTER (WHERE status='pending'),
        'expired',  COUNT(*) FILTER (WHERE status='expired')
      )
      FROM sbp_guest_orders
      WHERE shop_id = p_shop_id
        AND created_at::date >= v_from
        AND created_at::date <= v_to
    ),

    'qr_reject_reasons', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('reason', reason, 'count', c)
        ORDER BY c DESC)
      FROM (
        SELECT COALESCE(NULLIF(trim(rejected_reason),''),'No reason') reason,
               COUNT(*) c
        FROM sbp_guest_orders
        WHERE shop_id = p_shop_id AND status='rejected'
          AND created_at::date >= v_from AND created_at::date <= v_to
        GROUP BY 1
      ) y
    ), '[]'::jsonb),

    'day_close', (
      SELECT jsonb_build_object(
        'date',  (now() AT TIME ZONE 'Asia/Kolkata')::date,
        'bills', COUNT(*),
        'gross', COALESCE(SUM(grand_total),0),
        'cash',  COALESCE(SUM(grand_total) FILTER (WHERE LOWER(COALESCE(payment_mode,''))='cash'),0),
        'upi',   COALESCE(SUM(grand_total) FILTER (WHERE LOWER(COALESCE(payment_mode,''))='upi'),0),
        'card',  COALESCE(SUM(grand_total) FILTER (WHERE LOWER(COALESCE(payment_mode,''))='card'),0),
        'credit',COALESCE(SUM(grand_total) FILTER (WHERE LOWER(COALESCE(payment_mode,''))='credit'),0)
      )
      FROM bills
      WHERE shop_id = p_shop_id
        AND table_number IS NOT NULL
        AND COALESCE(LOWER(status),'') <> 'voided' AND voided_at IS NULL
        AND (created_at AT TIME ZONE 'Asia/Kolkata')::date
            = (now() AT TIME ZONE 'Asia/Kolkata')::date
    ),

    'open_tables', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'table',     table_number,
        'opened_at', opened_at,
        'mins_open', ROUND(EXTRACT(EPOCH FROM (now()-opened_at))/60.0)::int,
        'covers',    covers,
        'server',    server_name)
        ORDER BY opened_at ASC)
      FROM sbp_running_orders
      WHERE shop_id = p_shop_id AND status='open'
    ), '[]'::jsonb)

  ) INTO v_out;

  RETURN v_out;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception',
    'detail', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
END;
$$;

REVOKE ALL ON FUNCTION sbp_restaurant_report(uuid, date, date, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_restaurant_report(uuid, date, date, text, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
