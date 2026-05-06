-- ════════════════════════════════════════════════════════════════════
-- 013_customer_history.sql
-- Batch 013 — Customer History (6 May 2026)
--
-- Closes the universal "📋 History SOON" gap that was blocking 4 Tier 1
-- verticals from strict 100% completion (kirana, healthcare, education,
-- food/FMCG). Salon goes from 90% → 95% (still missing Stylists deeper).
--
-- DELIVERABLES:
--   1. RPC: sbp_get_customer_timeline(p_customer_id) — aggregates bills +
--      appointments + loyalty txns + customer record into a unified timeline
--      with summary stats. Read-only, no writes.
--   2. UPDATE sbp_module_profiles — flip customer_history to 'active' with
--      'NEW' badge across 11 retail/service profiles where it makes sense.
--
-- ARCHITECTURE NOTES:
--   - API-first per locked rule (5 May 2026): logic in PLpgSQL, jsonb envelope,
--     auth.uid() + ownership check, idempotent (no writes).
--   - One RPC roundtrip returns everything the page needs (customer + stats +
--     timeline) — no N+1, no chained client calls.
--   - Timeline is sorted DESC (newest first) and capped at 500 events to
--     prevent runaway responses for very-active customers (8+ year shops).
--     Pagination can be added later via p_before_at parameter.
--
-- IDEMPOTENT — safe to re-run.
-- Prerequisites: 003 + 009 + 011 must have run.
-- ════════════════════════════════════════════════════════════════════


-- ── RPC: sbp_get_customer_timeline ──────────────────────────────────
-- Args: p_customer_id uuid
-- Returns: jsonb {
--   ok: bool,
--   error?: text,
--   customer: {...},      -- full customer record
--   stats: {              -- aggregated metrics
--     total_bills, voided_bills, total_spent, total_paid, balance_due,
--     first_bill_at, last_bill_at, avg_ticket,
--     appointments_total, appointments_completed, appointments_cancelled,
--     loyalty_balance
--   },
--   timeline: [           -- DESC by event_at, max 500
--     { type: 'bill'|'appointment'|'loyalty'|'registered', at, payload }
--   ]
-- }

CREATE OR REPLACE FUNCTION sbp_get_customer_timeline(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_user_id   uuid;
  v_customer  record;
  v_shop_id   uuid;
  v_stats     jsonb;
  v_timeline  jsonb;
BEGIN
  -- ── Auth check
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- ── Validate input
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

  v_shop_id := v_customer.shop_id;

  -- ── Stats: aggregate bills + appointments + loyalty
  WITH bill_stats AS (
    SELECT
      COUNT(*) FILTER (WHERE COALESCE(b.voided_at, NULL) IS NULL AND COALESCE(b.status,'') <> 'voided')::int AS total_bills,
      COUNT(*) FILTER (WHERE b.voided_at IS NOT NULL OR b.status = 'voided')::int AS voided_bills,
      COALESCE(SUM(b.grand_total) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_spent,
      COALESCE(SUM(b.paid_amount) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_paid,
      COALESCE(SUM(b.balance_due) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS balance_due,
      MIN(b.created_at) AS first_bill_at,
      MAX(b.created_at) AS last_bill_at
    FROM bills b
    WHERE b.customer_id = p_customer_id
      AND b.shop_id    = v_shop_id
  ),
  appt_stats AS (
    SELECT
      COUNT(*)::int                                                         AS appointments_total,
      COUNT(*) FILTER (WHERE status = 'completed')::int                     AS appointments_completed,
      COUNT(*) FILTER (WHERE status IN ('cancelled','no_show'))::int        AS appointments_cancelled
    FROM sbp_appointments
    WHERE customer_id = p_customer_id
      AND shop_id     = v_shop_id
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
    WHERE b.customer_id = p_customer_id
      AND b.shop_id     = v_shop_id
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
      'loyalty'::text AS event_type,
      lt.created_at   AS event_at,
      jsonb_build_object(
        'id',          lt.id,
        'txn_type',    lt.txn_type,
        'points',      lt.points,
        'description', lt.description,
        'bill_id',     lt.bill_id,
        'expires_at',  lt.expires_at
      ) AS payload
    FROM sbp_loyalty_transactions lt
    WHERE lt.customer_id = p_customer_id
      AND lt.shop_id     = v_shop_id
  ),
  registered_event AS (
    -- Synthetic event: customer first joined the shop
    SELECT
      'registered'::text AS event_type,
      v_customer.joined_at AS event_at,
      jsonb_build_object(
        'name',          v_customer.name,
        'customer_type', COALESCE(v_customer.customer_type, 'Regular')
      ) AS payload
    WHERE v_customer.joined_at IS NOT NULL
  ),
  all_events AS (
    SELECT event_type, event_at, payload FROM bill_events
    UNION ALL
    SELECT event_type, event_at, payload FROM appt_events
    UNION ALL
    SELECT event_type, event_at, payload FROM loyalty_events
    UNION ALL
    SELECT event_type, event_at, payload FROM registered_event
  ),
  ordered_events AS (
    SELECT event_type, event_at, payload
    FROM all_events
    WHERE event_at IS NOT NULL
    ORDER BY event_at DESC
    LIMIT 500
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'type',    event_type,
    'at',      event_at,
    'payload', payload
  )), '[]'::jsonb)
  INTO v_timeline
  FROM ordered_events;

  -- ── Compose response
  RETURN jsonb_build_object(
    'ok',       true,
    'customer', to_jsonb(v_customer),
    'stats',    v_stats,
    'timeline', v_timeline
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_customer_timeline(uuid) TO authenticated;


-- ── Module profile updates: flip customer_history to active across
-- ── all retail/service profiles where customer relationships matter.
-- ──
-- Currently 003_business_categories.sql only seeds customer_history for
-- 'salon' profile (and 'service_history' — a different module — for 'auto').
-- Apply customer_history to the broader set of retail/service profiles.

-- Add to existing salon profile (already there as 'soon' → flip to active+NEW)
UPDATE sbp_module_profiles
SET status = 'active', badge = 'NEW'
WHERE module_code = 'customer_history';

-- Insert customer_history into 11 retail/service profiles where it adds value
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('standard',   'customer_history', 'active', 'NEW', 170),
  ('kirana',     'customer_history', 'active', 'NEW', 170),
  ('garments',   'customer_history', 'active', 'NEW', 170),
  ('mobile',     'customer_history', 'active', 'NEW', 170),
  ('jewellery',  'customer_history', 'active', 'NEW', 170),
  ('pharmacy',   'customer_history', 'active', 'NEW', 170),
  ('food',       'customer_history', 'active', 'NEW', 170),
  ('restaurant', 'customer_history', 'active', 'NEW', 170),
  ('healthcare', 'customer_history', 'active', 'NEW', 170),
  ('education',  'customer_history', 'active', 'NEW', 170),
  ('services',   'customer_history', 'active', 'NEW', 170)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status        = EXCLUDED.status,
  badge         = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;


-- ── Verification queries (paste in Supabase SQL Editor after running):
-- 
-- (1) Customer history active across 12 profiles:
--     SELECT profile, status, badge FROM sbp_module_profiles
--     WHERE module_code='customer_history' ORDER BY profile;
--     -- Expected: 12 rows (salon + 11 inserts), all active+NEW
-- 
-- (2) Smoke test the RPC (replace UUID with a real customer ID):
--     SELECT sbp_get_customer_timeline('xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx');
--     -- Expected: {ok:true, customer:{...}, stats:{...}, timeline:[...]}
-- 
-- (3) Permission check — should ERROR on anonymous:
--     SET ROLE anon; SELECT sbp_get_customer_timeline('xxx'::uuid);
--     -- Expected: permission denied for function sbp_get_customer_timeline


-- ════════════════════════════════════════════════════════════════════
-- DONE — Migration 013 complete.
-- ════════════════════════════════════════════════════════════════════
