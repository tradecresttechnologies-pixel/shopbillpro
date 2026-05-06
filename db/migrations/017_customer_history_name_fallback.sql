-- ════════════════════════════════════════════════════════════════════
-- 017_customer_history_name_fallback.sql
-- 6 May 2026 — Bug fix for sbp_get_customer_timeline
--
-- THE BUG:
--   013_customer_history.sql queries bills strictly by customer_id:
--     WHERE b.customer_id = p_customer_id
--   But many existing shops (especially those that started before the
--   ID-based linkage was added) have bills with customer_id = NULL and
--   only customer_name set. As a result, those customers' timelines
--   show 0 bills / ₹0 spent even when bills clearly exist.
--
-- THE FIX:
--   Match bills by EITHER customer_id OR (NULL id + name match).
--   Applied to both the bill_stats CTE and the bill_events CTE.
--   No schema changes — pure RPC body update.
--
-- Idempotent: re-running this just re-creates the function.
-- ════════════════════════════════════════════════════════════════════


CREATE OR REPLACE FUNCTION sbp_get_customer_timeline(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_user_id    uuid;
  v_customer   record;
  v_shop_id    uuid;
  v_cust_name  text;
  v_stats      jsonb;
  v_timeline   jsonb;
BEGIN
  -- ── Auth check
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_customer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_id_required');
  END IF;

  -- ── Load customer + verify ownership via shops.owner_id
  SELECT c.*
  INTO v_customer
  FROM customers c
  JOIN shops s ON s.id = c.shop_id
  WHERE c.id = p_customer_id
    AND s.owner_id = v_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_not_found_or_unauthorized');
  END IF;

  v_shop_id   := v_customer.shop_id;
  v_cust_name := v_customer.name;

  -- ── Stats: aggregate bills + appointments + loyalty
  -- BUGFIX 017: bills can be linked by customer_id OR by customer_name
  -- (when customer_id is NULL — older bills before ID linkage was added).
  WITH bill_stats AS (
    SELECT
      COUNT(*) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided')::int AS total_bills,
      COUNT(*) FILTER (WHERE b.voided_at IS NOT NULL OR b.status = 'voided')::int AS voided_bills,
      COALESCE(SUM(b.grand_total) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_spent,
      COALESCE(SUM(b.paid_amount) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_paid,
      COALESCE(SUM(b.balance_due) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS balance_due,
      MIN(b.created_at) AS first_bill_at,
      MAX(b.created_at) AS last_bill_at
    FROM bills b
    WHERE b.shop_id = v_shop_id
      AND (
        b.customer_id = p_customer_id
        OR (b.customer_id IS NULL AND v_cust_name IS NOT NULL AND b.customer_name = v_cust_name)
      )
  ),
  appt_stats AS (
    SELECT
      COUNT(*)::int                                                  AS appointments_total,
      COUNT(*) FILTER (WHERE status = 'completed')::int              AS appointments_completed,
      COUNT(*) FILTER (WHERE status IN ('cancelled','no_show'))::int AS appointments_cancelled
    FROM sbp_appointments
    WHERE shop_id = v_shop_id
      AND customer_id = p_customer_id
  ),
  loyalty_balance_calc AS (
    SELECT (points_earned - points_redeemed - points_expired)::int AS loyalty_balance
    FROM sbp_customer_loyalty
    WHERE shop_id = v_shop_id AND customer_id = p_customer_id
  )
  SELECT jsonb_build_object(
    'total_bills',            COALESCE(bs.total_bills, 0),
    'voided_bills',           COALESCE(bs.voided_bills, 0),
    'total_spent',            COALESCE(bs.total_spent, 0),
    'total_paid',             COALESCE(bs.total_paid, 0),
    'balance_due',            COALESCE(bs.balance_due, 0),
    'first_bill_at',          bs.first_bill_at,
    'last_bill_at',           bs.last_bill_at,
    'avg_ticket',             CASE WHEN COALESCE(bs.total_bills,0) > 0
                                   THEN ROUND(bs.total_spent / bs.total_bills, 2)
                                   ELSE 0 END,
    'appointments_total',     COALESCE(a.appointments_total, 0),
    'appointments_completed', COALESCE(a.appointments_completed, 0),
    'appointments_cancelled', COALESCE(a.appointments_cancelled, 0),
    'loyalty_balance',        COALESCE(lb.loyalty_balance, 0)
  )
  INTO v_stats
  FROM bill_stats bs
  CROSS JOIN appt_stats a
  LEFT JOIN loyalty_balance_calc lb ON true;

  -- ── Timeline: union of bill + appointment + loyalty + registered, DESC, limit 500
  -- BUGFIX 017: same name-fallback applies to the bill_events CTE.
  WITH bill_events AS (
    SELECT
      'bill'::text AS event_type,
      b.created_at AS event_at,
      jsonb_build_object(
        'id',            b.id,
        'invoice_no',    b.invoice_no,
        'invoice_date',  b.invoice_date,
        'grand_total',   b.grand_total,
        'paid_amount',   b.paid_amount,
        'balance_due',   b.balance_due,
        'status',        b.status,
        'voided',        (b.voided_at IS NOT NULL OR b.status = 'voided'),
        'voided_at',     b.voided_at,
        'payment_mode',  b.payment_mode,
        'items_count',   (SELECT COUNT(*)::int FROM bill_items bi WHERE bi.bill_id = b.id),
        'items_summary', (
          SELECT string_agg(item_name, ', ' ORDER BY id)
          FROM (SELECT bi.item_name, bi.id FROM bill_items bi WHERE bi.bill_id = b.id ORDER BY bi.id LIMIT 5) x
        )
      ) AS payload
    FROM bills b
    WHERE b.shop_id = v_shop_id
      AND (
        b.customer_id = p_customer_id
        OR (b.customer_id IS NULL AND v_cust_name IS NOT NULL AND b.customer_name = v_cust_name)
      )
  ),
  appt_events AS (
    SELECT
      'appointment'::text AS event_type,
      a.created_at        AS event_at,
      jsonb_build_object(
        'id',                   a.id,
        'starts_at',            a.starts_at,
        'ends_at',              a.ends_at,
        'duration_minutes',     a.duration_minutes,
        'status',               a.status,
        'service_name',         a.service_name_snapshot,
        'service_price',        a.service_price_snapshot,
        'source',               a.source,
        'notes',                a.notes,
        'bill_id',              a.bill_id,
        'cancelled_at',         a.cancelled_at,
        'cancelled_reason',     a.cancelled_reason,
        'provider_id',          a.provider_id,
        'provider_name',        (SELECT name FROM sbp_appointment_providers p WHERE p.id = a.provider_id)
      ) AS payload
    FROM sbp_appointments a
    WHERE a.customer_id = p_customer_id
      AND a.shop_id     = v_shop_id
  ),
  loyalty_events AS (
    SELECT
      'loyalty'::text  AS event_type,
      lt.created_at    AS event_at,
      jsonb_build_object(
        'id',          lt.id,
        'txn_type',    lt.txn_type,
        'points',      lt.points,
        'description', lt.description,
        'bill_id',     lt.bill_id
      ) AS payload
    FROM sbp_loyalty_transactions lt
    WHERE lt.customer_id = p_customer_id
      AND lt.shop_id     = v_shop_id
  ),
  registered_event AS (
    SELECT
      'registered'::text AS event_type,
      v_customer.joined_at AS event_at,
      jsonb_build_object(
        'note',          'Customer added to your shop',
        'customer_type', v_customer.customer_type
      ) AS payload
    WHERE v_customer.joined_at IS NOT NULL
  ),
  all_events AS (
    SELECT * FROM bill_events
    UNION ALL SELECT * FROM appt_events
    UNION ALL SELECT * FROM loyalty_events
    UNION ALL SELECT * FROM registered_event
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'type',    event_type,
    'at',      event_at,
    'payload', payload
  ) ORDER BY event_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_timeline
  FROM (
    SELECT * FROM all_events
    ORDER BY event_at DESC NULLS LAST
    LIMIT 500
  ) ranked;

  -- ── Return
  RETURN jsonb_build_object(
    'ok',       true,
    'customer', jsonb_build_object(
      'id',            v_customer.id,
      'name',          v_customer.name,
      'phone',         v_customer.phone,
      'whatsapp',      v_customer.whatsapp,
      'email',         v_customer.email,
      'address',       v_customer.address,
      'city',          v_customer.city,
      'gstin',         v_customer.gstin,
      'customer_type', v_customer.customer_type,
      'joined_at',     v_customer.joined_at
    ),
    'stats',    v_stats,
    'timeline', v_timeline
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_customer_timeline(uuid) TO authenticated;


-- ── Verification (paste in Supabase SQL Editor):
--
-- (1) Function recompiled (look at proowner / size — should be fresh):
--     SELECT pg_get_function_arguments(oid),
--            pg_get_functiondef(oid)
--       FROM pg_proc WHERE proname = 'sbp_get_customer_timeline';
--
-- (2) Smoke test on Jyoti's customer ID (replace with the real UUID):
--     SELECT sbp_get_customer_timeline('<jyoti-uuid>');
--     -- Expected: stats.total_bills = 6, total_spent = 4497,
--     --           timeline contains 6 bill events.


-- ════════════════════════════════════════════════════════════════════
-- DONE — RPC body updated. Customer history will now show legacy bills
-- linked only by name.
-- ════════════════════════════════════════════════════════════════════
