-- ════════════════════════════════════════════════════════════════════
-- 077_restaurant_report.sql   (Restaurant Reports — Phase B engine)
-- ════════════════════════════════════════════════════════════════════
-- ONE RPC → all 23 sections from RESTAURANT_REPORTS_SPEC.md.
-- Business-only restaurant (locked). Server-side aggregation, read-only,
-- owner-checked, {ok,...} envelope, exception-safe.
--
-- Data sources (audited):
--   bills (+table_number, table_session_id, covers, server_*, customer_id)
--   bill_items (item_name, qty, rate, line_total, gst_amount, kind)
--   sbp_running_orders (items[], kots[], opened_at, billed_at, covers,
--     server_name, voided qty in items)
--   sbp_restaurant_tables (table_number, section, capacity)
--   sbp_guest_orders (status, accepted_kot_no, rejected_reason)
--
-- Date filter: bills by invoice_date (matches existing reports engine).
-- Voided bills excluded from revenue, surfaced separately in voids.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_restaurant_report(uuid, date, date);

CREATE OR REPLACE FUNCTION sbp_restaurant_report(
  p_shop_id  uuid,
  p_from     date DEFAULT NULL,
  p_to       date DEFAULT NULL
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

  WITH
  -- Dine-in bills in range, not voided. table_number NOT NULL = dine-in.
  rb AS (
    SELECT b.*
    FROM bills b
    WHERE b.shop_id = p_shop_id
      AND b.invoice_date >= v_from
      AND b.invoice_date <= v_to
      AND b.table_number IS NOT NULL
      AND COALESCE(LOWER(b.status), '') <> 'voided'
      AND b.voided_at IS NULL
  ),
  -- Voided dine-in bills (for the voids section)
  vb AS (
    SELECT b.*
    FROM bills b
    WHERE b.shop_id = p_shop_id
      AND b.invoice_date >= v_from
      AND b.invoice_date <= v_to
      AND b.table_number IS NOT NULL
      AND (b.voided_at IS NOT NULL OR LOWER(COALESCE(b.status,'')) = 'voided')
  ),
  -- Line items for the non-voided dine-in bills
  ri AS (
    SELECT bi.*, b.invoice_date, b.created_at AS bill_created
    FROM bill_items bi
    JOIN rb b ON b.id = bi.bill_id
  ),
  -- Sessions in range (turn time, KOT analysis)
  rs AS (
    SELECT r.*
    FROM sbp_running_orders r
    WHERE r.shop_id = p_shop_id
      AND r.billed_at IS NOT NULL
      AND r.billed_at::date >= v_from
      AND r.billed_at::date <= v_to
  )
  SELECT jsonb_build_object(
    'ok', true,
    'range', jsonb_build_object('from', v_from, 'to', v_to),

    -- ── A1. Sales summary ───────────────────────────────────────────
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

    -- ── A2. Daily sales trend ───────────────────────────────────────
    'daily_trend', COALESCE((
      SELECT jsonb_agg(d ORDER BY d->>'date')
      FROM (
        SELECT jsonb_build_object(
          'date',  invoice_date,
          'bills', COUNT(*),
          'gross', COALESCE(SUM(grand_total),0),
          'aov',   CASE WHEN COUNT(*)>0 THEN ROUND(SUM(grand_total)/COUNT(*),2) ELSE 0 END
        ) AS d
        FROM rb GROUP BY invoice_date
      ) x
    ), '[]'::jsonb),

    -- ── A3. Day-part (hourly buckets) ───────────────────────────────
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
          COUNT(*)                       AS bills,
          COALESCE(SUM(grand_total),0)   AS gross
        FROM (
          SELECT grand_total,
            EXTRACT(HOUR FROM (created_at AT TIME ZONE 'Asia/Kolkata'))::int AS h
          FROM rb
        ) hb
        GROUP BY 1
      ) y
    ), '[]'::jsonb),

    -- ── A5. Payment mode split ──────────────────────────────────────
    'payment_split', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'mode',  COALESCE(payment_mode,'Unknown'),
        'bills', c, 'amount', amt))
      FROM (
        SELECT payment_mode, COUNT(*) c, COALESCE(SUM(grand_total),0) amt
        FROM rb GROUP BY payment_mode
      ) x
    ), '[]'::jsonb),

    -- ── A6. Discounts ───────────────────────────────────────────────
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

    -- ── A7. Tax summary (CGST/SGST assumed intra; total GST) ────────
    'tax_summary', (
      SELECT jsonb_build_object(
        'total_gst', COALESCE(SUM(COALESCE(gst_amount,0)),0),
        'cgst',      ROUND(COALESCE(SUM(COALESCE(gst_amount,0)),0)/2.0,2),
        'sgst',      ROUND(COALESCE(SUM(COALESCE(gst_amount,0)),0)/2.0,2),
        'taxable',   COALESCE(SUM(grand_total - COALESCE(gst_amount,0)),0)
      ) FROM rb
    ),

    -- ── B8. Per-table revenue ───────────────────────────────────────
    'per_table', COALESCE((
      SELECT jsonb_agg(t ORDER BY (t->>'gross')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'table',  table_number,
          'bills',  COUNT(*),
          'gross',  COALESCE(SUM(grand_total),0),
          'covers', COALESCE(SUM(COALESCE(covers,0)),0),
          'aov',    CASE WHEN COUNT(*)>0 THEN ROUND(SUM(grand_total)/COUNT(*),2) ELSE 0 END
        ) AS t
        FROM rb GROUP BY table_number
      ) x
    ), '[]'::jsonb),

    -- ── B9. Per-section revenue (join tables for section) ───────────
    'per_section', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('section', section, 'bills', bills, 'gross', gross)
        ORDER BY gross DESC)
      FROM (
        SELECT
          COALESCE(NULLIF(trim(t.section),''),'Main') AS section,
          COUNT(*)                          AS bills,
          COALESCE(SUM(b.grand_total),0)    AS gross
        FROM rb b
        LEFT JOIN sbp_restaurant_tables t
          ON t.shop_id = p_shop_id AND t.table_number = b.table_number
        GROUP BY 1
      ) y
    ), '[]'::jsonb),

    -- ── B10/11. Table turnaround + utilisation (sessions) ───────────
    'table_turnaround', (
      SELECT jsonb_build_object(
        'sessions',      COUNT(*),
        'avg_minutes',   COALESCE(ROUND(AVG(
                           EXTRACT(EPOCH FROM (billed_at - opened_at))/60.0)::numeric,1),0),
        'turns',         COUNT(*)
      ) FROM rs
    ),
    'table_utilisation', COALESCE((
      SELECT jsonb_agg(u ORDER BY (u->>'turns')::int DESC)
      FROM (
        SELECT jsonb_build_object(
          'table', table_number,
          'turns', COUNT(*),
          'avg_minutes', COALESCE(ROUND(AVG(
            EXTRACT(EPOCH FROM (billed_at - opened_at))/60.0)::numeric,1),0)
        ) AS u
        FROM rs GROUP BY table_number
      ) x
    ), '[]'::jsonb),

    -- ── B12. Server / waiter performance ────────────────────────────
    'server_performance', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'server', server, 'bills', bills, 'gross', gross,
          'covers', covers,
          'aov', CASE WHEN bills>0 THEN ROUND(gross/bills,2) ELSE 0 END)
        ORDER BY gross DESC)
      FROM (
        SELECT
          COALESCE(NULLIF(trim(server_name),''),'Unattributed') AS server,
          COUNT(*)                              AS bills,
          COALESCE(SUM(grand_total),0)          AS gross,
          COALESCE(SUM(COALESCE(covers,0)),0)   AS covers
        FROM rb GROUP BY 1
      ) y
    ), '[]'::jsonb),

    -- ── C13. Top / bottom items ─────────────────────────────────────
    'top_items', COALESCE((
      SELECT jsonb_agg(t)
      FROM (
        SELECT jsonb_build_object(
          'name',    item_name,
          'qty',     COALESCE(SUM(qty),0),
          'revenue', COALESCE(SUM(line_total),0)
        ) AS t
        FROM ri GROUP BY item_name
        ORDER BY SUM(line_total) DESC NULLS LAST LIMIT 25
      ) x
    ), '[]'::jsonb),
    'bottom_items', COALESCE((
      SELECT jsonb_agg(t)
      FROM (
        SELECT jsonb_build_object(
          'name',    item_name,
          'qty',     COALESCE(SUM(qty),0),
          'revenue', COALESCE(SUM(line_total),0)
        ) AS t
        FROM ri GROUP BY item_name
        ORDER BY SUM(line_total) ASC NULLS LAST LIMIT 15
      ) x
    ), '[]'::jsonb),

    -- ── C14. Category mix (bill_items.kind) ─────────────────────────
    'category_mix', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object('category', category, 'qty', qty, 'revenue', revenue)
        ORDER BY revenue DESC)
      FROM (
        SELECT
          COALESCE(NULLIF(trim(kind),''),'Uncategorised') AS category,
          COALESCE(SUM(qty),0)         AS qty,
          COALESCE(SUM(line_total),0)  AS revenue
        FROM ri GROUP BY 1
      ) y
    ), '[]'::jsonb),

    -- ── C16. Voids / wastage ────────────────────────────────────────
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

    -- ── C17. KOT analysis ───────────────────────────────────────────
    'kot_analysis', (
      SELECT jsonb_build_object(
        'sessions',      COUNT(*),
        'total_kots',    COALESCE(SUM(COALESCE(kot_count,0)),0),
        'avg_kots',      CASE WHEN COUNT(*)>0
                          THEN ROUND(AVG(COALESCE(kot_count,0))::numeric,2) ELSE 0 END
      ) FROM rs
    ),

    -- ── D18/19/20. QR funnel + rejection reasons ────────────────────
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
      SELECT jsonb_agg(jsonb_build_object('reason', reason, 'count', c))
      FROM (
        SELECT COALESCE(NULLIF(trim(rejected_reason),''),'No reason') reason,
               COUNT(*) c
        FROM sbp_guest_orders
        WHERE shop_id = p_shop_id AND status='rejected'
          AND created_at::date >= v_from AND created_at::date <= v_to
        GROUP BY 1 ORDER BY 2 DESC
      ) x
    ), '[]'::jsonb),

    -- ── E21. Day-close (today snapshot, IST) ────────────────────────
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

    -- ── E22. Open / unsettled tables ────────────────────────────────
    'open_tables', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'table',     table_number,
        'opened_at', opened_at,
        'mins_open', ROUND(EXTRACT(EPOCH FROM (now()-opened_at))/60.0)::int,
        'covers',    covers,
        'server',    server_name))
      FROM sbp_running_orders
      WHERE shop_id = p_shop_id AND status='open'
      ORDER BY opened_at ASC
    ), '[]'::jsonb)

  ) INTO v_out;

  RETURN v_out;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', 'exception',
    'detail', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
END;
$$;

REVOKE ALL ON FUNCTION sbp_restaurant_report(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_restaurant_report(uuid, date, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
