-- ════════════════════════════════════════════════════════════════════
-- 014_loyalty_overview.sql
-- Batch 013 hotfix companion (6 May 2026)
--
-- Adds the admin-facing loyalty overview RPC needed by the new
-- loyalty.html page. The existing 009_loyalty.sql provides per-customer
-- balance + per-customer recent_txns RPCs, but no shop-wide aggregator.
-- This fills that gap.
--
-- DELIVERABLES:
--   1. RPC: sbp_loyalty_admin_overview(p_shop_id) — returns config +
--      shop-wide stats + recent transactions across all customers.
--
-- API-FIRST per locked rule. Read-only, idempotent.
-- ════════════════════════════════════════════════════════════════════


CREATE OR REPLACE FUNCTION sbp_loyalty_admin_overview(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_user_id uuid;
  v_config  jsonb;
  v_stats   jsonb;
  v_txns    jsonb;
BEGIN
  -- ── Auth + ownership check
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_id_required');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = v_user_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- ── Config (returns defaults if no row exists yet)
  SELECT to_jsonb(c) INTO v_config
  FROM sbp_loyalty_config c
  WHERE c.shop_id = p_shop_id;

  IF v_config IS NULL THEN
    v_config := jsonb_build_object(
      'shop_id',               p_shop_id,
      'enabled',               false,
      'earn_rate_amount',      100,
      'earn_rate_points',      1,
      'redeem_rate_points',    100,
      'redeem_rate_amount',    10,
      'min_redeem_points',     100,
      'expiry_months',         12,
      'earn_on_field',         'taxable_total',
      'birthday_bonus_points', 0,
      'welcome_bonus_points',  0,
      'display_message',       'You earned {points} points! Total balance: {balance}'
    );
  END IF;

  -- ── Stats: aggregate across all customers in this shop
  WITH balances AS (
    SELECT customer_id, (points_earned - points_redeemed - points_expired)::int AS balance,
           points_earned, points_redeemed, points_expired
    FROM sbp_customer_loyalty
    WHERE shop_id = p_shop_id
  ),
  txn_aggregates AS (
    SELECT
      COUNT(DISTINCT customer_id)::int AS members_with_txns,
      COALESCE(SUM(CASE WHEN txn_type = 'earn'           THEN points ELSE 0 END), 0)::int AS total_earned_lifetime,
      COALESCE(SUM(CASE WHEN txn_type = 'redeem'         THEN -points ELSE 0 END), 0)::int AS total_redeemed_lifetime,
      COALESCE(SUM(CASE WHEN txn_type = 'expire'         THEN -points ELSE 0 END), 0)::int AS total_expired_lifetime,
      COALESCE(SUM(CASE WHEN txn_type IN ('birthday','welcome') THEN points ELSE 0 END), 0)::int AS total_bonus_points,
      COUNT(*) FILTER (WHERE created_at > now() - interval '30 days')::int AS txns_last_30d
    FROM sbp_loyalty_transactions
    WHERE shop_id = p_shop_id
  ),
  expiring_soon AS (
    SELECT COALESCE(SUM(points), 0)::int AS expiring_30d
    FROM sbp_loyalty_transactions
    WHERE shop_id = p_shop_id
      AND txn_type = 'earn'
      AND expires_at IS NOT NULL
      AND expires_at <= now() + interval '30 days'
      AND expires_at > now()
  )
  SELECT jsonb_build_object(
    'active_members',          (SELECT COUNT(*) FROM balances WHERE balance > 0)::int,
    'total_members_ever',      (SELECT COUNT(*) FROM balances)::int,
    'total_outstanding',       COALESCE((SELECT SUM(balance) FROM balances WHERE balance > 0), 0)::int,
    'total_earned_lifetime',   ta.total_earned_lifetime,
    'total_redeemed_lifetime', ta.total_redeemed_lifetime,
    'total_expired_lifetime',  ta.total_expired_lifetime,
    'total_bonus_points',      ta.total_bonus_points,
    'txns_last_30d',           ta.txns_last_30d,
    'expiring_in_30d',         es.expiring_30d
  )
  INTO v_stats
  FROM txn_aggregates ta CROSS JOIN expiring_soon es;

  -- ── Recent transactions (last 30 across all customers, with customer name)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',            t.id,
    'customer_id',   t.customer_id,
    'customer_name', c.name,
    'txn_type',      t.txn_type,
    'points',        t.points,
    'description',   t.description,
    'bill_id',       t.bill_id,
    'created_at',    t.created_at
  ) ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_txns
  FROM (
    SELECT id, customer_id, txn_type, points, description, bill_id, created_at
    FROM sbp_loyalty_transactions
    WHERE shop_id = p_shop_id
    ORDER BY created_at DESC
    LIMIT 30
  ) t
  LEFT JOIN customers c ON c.id = t.customer_id;

  -- ── Compose response
  RETURN jsonb_build_object(
    'ok',          true,
    'config',      v_config,
    'stats',       v_stats,
    'recent_txns', v_txns
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_loyalty_admin_overview(uuid) TO authenticated;


-- ── Verification (paste in Supabase SQL Editor):
--
--   SELECT sbp_loyalty_admin_overview('<your-shop-uuid>');
--   -- Expected: {ok:true, config:{...}, stats:{...}, recent_txns:[...]}


-- ════════════════════════════════════════════════════════════════════
-- DONE
-- ════════════════════════════════════════════════════════════════════
