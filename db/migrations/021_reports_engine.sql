-- ════════════════════════════════════════════════════════════════════
-- 021_reports_engine.sql
-- Batch 020 — Reports Engine foundation (8 May 2026)
--
-- Server-side aggregation RPCs for shop reports. Each RPC:
--   - Validates that the caller owns the shop (auth.uid() = shops.owner_id)
--   - Defaults date range to last 30 days if NULL
--   - Returns a stable jsonb envelope { ok, error?, report_key, from_date,
--     to_date, summary, rows, groups }
--
-- 4 baseline reports (work for ALL shop types):
--   sbp_report_sales_summary        — bills/revenue/AOV + daily series
--   sbp_report_item_kind_breakdown  — split by product/service/room
--                                     (uses Batch 019's `kind` column)
--   sbp_report_top_customers        — top spenders & most frequent
--   sbp_report_payment_mode_mix     — Cash / UPI / Card / Credit %
--
-- DEFENSIVE: if Batch 019 wasn't deployed, this migration adds the
--   `kind` column itself (with default 'product') so reports work.
-- ════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- 0. Defensive: ensure bill_items.kind exists (so item-kind report works)
-- ──────────────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'bill_items'
      AND column_name = 'kind'
  ) THEN
    ALTER TABLE bill_items ADD COLUMN kind text NOT NULL DEFAULT 'product';
    UPDATE bill_items SET kind = 'product' WHERE kind IS NULL OR kind = '';
    RAISE NOTICE 'Added bill_items.kind column (Batch 019 not previously deployed)';
  END IF;
END $$;

-- ──────────────────────────────────────────────────────────────────
-- 1. Helper — owner check
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_report_check_owner(p_shop_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM shops
    WHERE id = p_shop_id
      AND owner_id = auth.uid()
  );
$$;

GRANT EXECUTE ON FUNCTION public.sbp_report_check_owner(uuid) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 2. RPC: sbp_report_sales_summary
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_report_sales_summary(
  p_shop_id   uuid,
  p_from_date date DEFAULT NULL,
  p_to_date   date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from   date;
  v_to     date;
  v_summary jsonb;
  v_daily   jsonb;
  v_status  jsonb;
BEGIN
  IF NOT sbp_report_check_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  v_from := COALESCE(p_from_date, (CURRENT_DATE - INTERVAL '30 days')::date);
  v_to   := COALESCE(p_to_date, CURRENT_DATE);

  -- Summary KPIs (excludes voided)
  SELECT jsonb_build_object(
    'total_bills',     COUNT(*),
    'total_revenue',   COALESCE(SUM(grand_total), 0),
    'total_paid',      COALESCE(SUM(paid_amount), 0),
    'total_due',       COALESCE(SUM(balance_due), 0),
    'total_gst',       COALESCE(SUM(gst_amount), 0),
    'total_discount',  COALESCE(SUM(discount), 0),
    'aov',             CASE WHEN COUNT(*) > 0
                            THEN ROUND(AVG(grand_total)::numeric, 2)
                            ELSE 0 END,
    'unique_customers', COUNT(DISTINCT COALESCE(customer_id::text, customer_name))
  ) INTO v_summary
  FROM bills
  WHERE shop_id = p_shop_id
    AND invoice_date >= v_from
    AND invoice_date <= v_to
    AND COALESCE(LOWER(status), '') <> 'voided';

  -- Daily breakdown
  SELECT COALESCE(jsonb_agg(d ORDER BY d->>'date'), '[]'::jsonb)
  INTO v_daily
  FROM (
    SELECT jsonb_build_object(
      'date',    invoice_date,
      'bills',   COUNT(*),
      'revenue', COALESCE(SUM(grand_total), 0),
      'paid',    COALESCE(SUM(paid_amount), 0)
    ) AS d
    FROM bills
    WHERE shop_id = p_shop_id
      AND invoice_date >= v_from
      AND invoice_date <= v_to
      AND COALESCE(LOWER(status), '') <> 'voided'
    GROUP BY invoice_date
  ) sub;

  -- By status
  SELECT COALESCE(jsonb_agg(s), '[]'::jsonb)
  INTO v_status
  FROM (
    SELECT jsonb_build_object(
      'status', status,
      'count',  COUNT(*),
      'total',  COALESCE(SUM(grand_total), 0)
    ) AS s
    FROM bills
    WHERE shop_id = p_shop_id
      AND invoice_date >= v_from
      AND invoice_date <= v_to
    GROUP BY status
    ORDER BY COUNT(*) DESC
  ) sub;

  RETURN jsonb_build_object(
    'ok',         true,
    'report_key', 'sales_summary',
    'from_date',  v_from,
    'to_date',    v_to,
    'summary',    v_summary,
    'rows',       v_daily,
    'groups',     v_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_report_sales_summary(uuid, date, date) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 3. RPC: sbp_report_item_kind_breakdown
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_report_item_kind_breakdown(
  p_shop_id   uuid,
  p_from_date date DEFAULT NULL,
  p_to_date   date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from   date;
  v_to     date;
  v_summary jsonb;
  v_by_kind jsonb;
  v_top     jsonb;
BEGIN
  IF NOT sbp_report_check_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  v_from := COALESCE(p_from_date, (CURRENT_DATE - INTERVAL '30 days')::date);
  v_to   := COALESCE(p_to_date, CURRENT_DATE);

  -- Aggregate join — filter bills by date and skip voided
  WITH joined AS (
    SELECT
      bi.kind,
      bi.item_name,
      bi.qty,
      bi.line_total,
      bi.gst_amount
    FROM bill_items bi
    JOIN bills b ON b.id = bi.bill_id
    WHERE b.shop_id = p_shop_id
      AND b.invoice_date >= v_from
      AND b.invoice_date <= v_to
      AND COALESCE(LOWER(b.status), '') <> 'voided'
  )
  SELECT
    jsonb_build_object(
      'total_lines',   COUNT(*),
      'total_qty',     COALESCE(SUM(qty), 0),
      'total_revenue', COALESCE(SUM(line_total), 0),
      'total_gst',     COALESCE(SUM(gst_amount), 0)
    ),
    -- by_kind groups
    COALESCE((
      SELECT jsonb_agg(g ORDER BY g->>'kind')
      FROM (
        SELECT jsonb_build_object(
          'kind',     COALESCE(j2.kind, 'product'),
          'lines',    COUNT(*),
          'qty_sum',  COALESCE(SUM(j2.qty), 0),
          'revenue',  COALESCE(SUM(j2.line_total), 0),
          'gst',      COALESCE(SUM(j2.gst_amount), 0)
        ) AS g
        FROM joined j2
        GROUP BY j2.kind
      ) sub
    ), '[]'::jsonb),
    -- top items overall
    COALESCE((
      SELECT jsonb_agg(t)
      FROM (
        SELECT jsonb_build_object(
          'kind',     COALESCE(j3.kind, 'product'),
          'name',     j3.item_name,
          'qty_sum',  SUM(j3.qty),
          'revenue',  SUM(j3.line_total)
        ) AS t
        FROM joined j3
        GROUP BY j3.kind, j3.item_name
        ORDER BY SUM(j3.line_total) DESC
        LIMIT 20
      ) sub
    ), '[]'::jsonb)
  INTO v_summary, v_by_kind, v_top
  FROM joined;

  RETURN jsonb_build_object(
    'ok',         true,
    'report_key', 'item_kind_breakdown',
    'from_date',  v_from,
    'to_date',    v_to,
    'summary',    COALESCE(v_summary, jsonb_build_object('total_lines',0,'total_qty',0,'total_revenue',0,'total_gst',0)),
    'rows',       COALESCE(v_top, '[]'::jsonb),
    'groups',     COALESCE(v_by_kind, '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_report_item_kind_breakdown(uuid, date, date) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 4. RPC: sbp_report_top_customers
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_report_top_customers(
  p_shop_id   uuid,
  p_from_date date DEFAULT NULL,
  p_to_date   date DEFAULT NULL,
  p_limit     int  DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from date;
  v_to   date;
  v_summary jsonb;
  v_rows    jsonb;
BEGIN
  IF NOT sbp_report_check_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  v_from := COALESCE(p_from_date, (CURRENT_DATE - INTERVAL '30 days')::date);
  v_to   := COALESCE(p_to_date, CURRENT_DATE);

  WITH grouped AS (
    SELECT
      COALESCE(customer_id::text, customer_name) AS group_key,
      MAX(customer_name) AS customer_name,
      MAX(customer_wa)   AS customer_wa,
      COUNT(*) AS visits,
      COALESCE(SUM(grand_total), 0) AS total_spend,
      COALESCE(SUM(balance_due), 0) AS total_due,
      MAX(invoice_date) AS last_visit
    FROM bills
    WHERE shop_id = p_shop_id
      AND invoice_date >= v_from
      AND invoice_date <= v_to
      AND COALESCE(LOWER(status), '') <> 'voided'
      AND COALESCE(customer_name, '') <> ''
      AND LOWER(customer_name) <> 'walk-in customer'
    GROUP BY COALESCE(customer_id::text, customer_name)
  )
  SELECT
    jsonb_build_object(
      'unique_customers', COUNT(*),
      'total_revenue',    COALESCE(SUM(total_spend), 0),
      'total_visits',     COALESCE(SUM(visits), 0),
      'total_outstanding', COALESCE(SUM(total_due), 0)
    ),
    COALESCE((
      SELECT jsonb_agg(c)
      FROM (
        SELECT jsonb_build_object(
          'customer_name', g2.customer_name,
          'customer_wa',   g2.customer_wa,
          'visits',        g2.visits,
          'total_spend',   g2.total_spend,
          'total_due',     g2.total_due,
          'last_visit',    g2.last_visit,
          'avg_spend',     ROUND((g2.total_spend / NULLIF(g2.visits, 0))::numeric, 2)
        ) AS c
        FROM grouped g2
        ORDER BY g2.total_spend DESC
        LIMIT p_limit
      ) sub
    ), '[]'::jsonb)
  INTO v_summary, v_rows
  FROM grouped;

  RETURN jsonb_build_object(
    'ok',         true,
    'report_key', 'top_customers',
    'from_date',  v_from,
    'to_date',    v_to,
    'summary',    COALESCE(v_summary, jsonb_build_object('unique_customers',0,'total_revenue',0,'total_visits',0,'total_outstanding',0)),
    'rows',       v_rows,
    'groups',     '[]'::jsonb
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_report_top_customers(uuid, date, date, int) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 5. RPC: sbp_report_payment_mode_mix
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_report_payment_mode_mix(
  p_shop_id   uuid,
  p_from_date date DEFAULT NULL,
  p_to_date   date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from date;
  v_to   date;
  v_total numeric;
  v_summary jsonb;
  v_rows    jsonb;
BEGIN
  IF NOT sbp_report_check_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  v_from := COALESCE(p_from_date, (CURRENT_DATE - INTERVAL '30 days')::date);
  v_to   := COALESCE(p_to_date, CURRENT_DATE);

  SELECT COALESCE(SUM(paid_amount), 0)
  INTO v_total
  FROM bills
  WHERE shop_id = p_shop_id
    AND invoice_date >= v_from
    AND invoice_date <= v_to
    AND COALESCE(LOWER(status), '') <> 'voided';

  SELECT
    jsonb_build_object(
      'total_paid',  v_total,
      'modes_count', COUNT(*)
    ),
    COALESCE((
      SELECT jsonb_agg(m ORDER BY (m->>'total')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'payment_mode', COALESCE(b2.payment_mode, 'Unknown'),
          'count',        COUNT(*),
          'total',        COALESCE(SUM(b2.paid_amount), 0),
          'pct',          CASE WHEN v_total > 0
                               THEN ROUND((SUM(b2.paid_amount) / v_total * 100)::numeric, 1)
                               ELSE 0 END
        ) AS m
        FROM bills b2
        WHERE b2.shop_id = p_shop_id
          AND b2.invoice_date >= v_from
          AND b2.invoice_date <= v_to
          AND COALESCE(LOWER(b2.status), '') <> 'voided'
        GROUP BY b2.payment_mode
      ) sub
    ), '[]'::jsonb)
  INTO v_summary, v_rows
  FROM bills b
  WHERE b.shop_id = p_shop_id
    AND b.invoice_date >= v_from
    AND b.invoice_date <= v_to
    AND COALESCE(LOWER(b.status), '') <> 'voided'
  GROUP BY ()
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok',         true,
    'report_key', 'payment_mode_mix',
    'from_date',  v_from,
    'to_date',    v_to,
    'summary',    COALESCE(v_summary, jsonb_build_object('total_paid',0,'modes_count',0)),
    'rows',       COALESCE(v_rows, '[]'::jsonb),
    'groups',     '[]'::jsonb
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_report_payment_mode_mix(uuid, date, date) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 6. Verification queries
-- ──────────────────────────────────────────────────────────────────

-- (1) Confirm new RPCs exist:
--   SELECT proname FROM pg_proc WHERE proname LIKE 'sbp_report_%';
--   Expected: 5 rows (4 reports + check_owner)
--
-- (2) Test as a logged-in shopkeeper (replace with real shop_id):
--   SELECT public.sbp_report_sales_summary(
--     'YOUR_SHOP_UUID'::uuid, NULL, NULL
--   );
--   Expected: { ok:true, summary:{total_bills,...}, rows:[...], groups:[...] }
--
-- (3) Test unauthorized access (should return ok:false):
--   SET ROLE anon;
--   SELECT public.sbp_report_sales_summary('00000000-0000-0000-0000-000000000000'::uuid, NULL, NULL);
--   RESET ROLE;

-- ────────────────────── End of 021_reports_engine.sql ──────────────────────
