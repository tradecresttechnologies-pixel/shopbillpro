-- ════════════════════════════════════════════════════════════════════
-- 009_loyalty.sql
-- Customer Loyalty / Reward Points module
--
-- Master Plan v1.1 reference:
--   Section 5.1 — Retail vertical (loyalty is industry-standard expectation)
--   Section 4.3 — Plan gating: Pro/Business only (not Free)
--
-- Design choices (locked May 5 2026):
--   - Points-based (industry standard, not tier or visit-based)
--   - Earn rate: ₹100 of TAXABLE_TOTAL = 1 point (configurable per shop)
--   - Redeem rate: 100 points = ₹10 discount (configurable per shop)
--   - Redemption applied as POST-GST final discount (loyalty acts as
--     final price adjustment — GSTR-1 stays accurate, ₹50 reduction is
--     shop's marketing cost, not a price reduction). Same as Croma/FabIndia.
--   - Plan gating: Free=disabled. Pro/Business=enabled.
--   - Voiding a bill auto-reverses earn AND restores redeemed points.
--
-- ACTUAL columns used from existing tables:
--   shops (id, plan, plan_expires_at)
--   customers (id, shop_id, name, balance)
--   bills (id, shop_id, customer_id, customer_name, customer_wa,
--          subtotal, gst_amount, discount, grand_total, status,
--          voided_at, reopened_at, audit_log)
--   bill_items (bill_id, line_total)
--
-- Deploy after: 008_public_shop_page.sql
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Add columns to existing tables ──────────────────────────────────

-- Allow bills to record a loyalty redemption (separate from regular discount)
ALTER TABLE bills ADD COLUMN IF NOT EXISTS loyalty_redemption_amount numeric DEFAULT 0;
ALTER TABLE bills ADD COLUMN IF NOT EXISTS loyalty_points_redeemed int DEFAULT 0;
ALTER TABLE bills ADD COLUMN IF NOT EXISTS loyalty_points_earned int DEFAULT 0;

-- Optional birthday field on customers (used for birthday bonus, Business tier)
ALTER TABLE customers ADD COLUMN IF NOT EXISTS dob date;

-- ── 2. Tables ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sbp_loyalty_config (
  shop_id                   uuid PRIMARY KEY REFERENCES shops(id) ON DELETE CASCADE,
  enabled                   boolean NOT NULL DEFAULT false,
  earn_rate_amount          numeric NOT NULL DEFAULT 100   CHECK (earn_rate_amount > 0),
  earn_rate_points          int     NOT NULL DEFAULT 1     CHECK (earn_rate_points > 0),
  redeem_rate_points        int     NOT NULL DEFAULT 100   CHECK (redeem_rate_points > 0),
  redeem_rate_amount        numeric NOT NULL DEFAULT 10    CHECK (redeem_rate_amount > 0),
  min_redeem_points         int     NOT NULL DEFAULT 100   CHECK (min_redeem_points >= 0),
  expiry_months             int     NOT NULL DEFAULT 12    CHECK (expiry_months >= 0),  -- 0 = never expires
  earn_on_field             text    NOT NULL DEFAULT 'taxable_total'
                                    CHECK (earn_on_field IN ('grand_total','taxable_total')),
  birthday_bonus_points     int     NOT NULL DEFAULT 0     CHECK (birthday_bonus_points >= 0),
  welcome_bonus_points      int     NOT NULL DEFAULT 0     CHECK (welcome_bonus_points >= 0),
  display_message           text    NOT NULL DEFAULT 'You earned {points} points! Total balance: {balance}',
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

-- Per-customer balance (denormalized for fast read)
CREATE TABLE IF NOT EXISTS sbp_customer_loyalty (
  shop_id          uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  customer_id      uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  points_earned    bigint NOT NULL DEFAULT 0,
  points_redeemed  bigint NOT NULL DEFAULT 0,
  points_expired   bigint NOT NULL DEFAULT 0,
  last_earned_at   timestamptz,
  last_redeemed_at timestamptz,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (shop_id, customer_id)
);

-- Audit trail (every earn/redeem/expire/manual)
CREATE TABLE IF NOT EXISTS sbp_loyalty_transactions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  customer_id   uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  bill_id       uuid REFERENCES bills(id) ON DELETE SET NULL,
  txn_type      text NOT NULL CHECK (txn_type IN ('earn','redeem','expire','manual_adjust','birthday','welcome','void_reverse')),
  points        int  NOT NULL,            -- +ve for earn/welcome/birthday/void_reverse, -ve for redeem/expire
  description   text,
  expires_at    timestamptz,              -- only set for 'earn' rows; used by expire job
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid REFERENCES auth.users(id)
);

-- ── 3. Indexes ─────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_loyalty_txn_shop_customer
  ON sbp_loyalty_transactions(shop_id, customer_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_loyalty_txn_expiry
  ON sbp_loyalty_transactions(expires_at)
  WHERE expires_at IS NOT NULL AND txn_type = 'earn';

CREATE INDEX IF NOT EXISTS idx_loyalty_txn_bill
  ON sbp_loyalty_transactions(bill_id) WHERE bill_id IS NOT NULL;

-- ── 4. Updated_at trigger for config ───────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_loyalty_config_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sbp_loyalty_config_updated_at ON sbp_loyalty_config;
CREATE TRIGGER trg_sbp_loyalty_config_updated_at
  BEFORE UPDATE ON sbp_loyalty_config
  FOR EACH ROW EXECUTE FUNCTION sbp_loyalty_config_set_updated_at();

-- ── 5. RLS policies ────────────────────────────────────────────────────

ALTER TABLE sbp_loyalty_config        ENABLE ROW LEVEL SECURITY;
ALTER TABLE sbp_customer_loyalty      ENABLE ROW LEVEL SECURITY;
ALTER TABLE sbp_loyalty_transactions  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_loyalty_config_owner ON sbp_loyalty_config;
CREATE POLICY p_loyalty_config_owner ON sbp_loyalty_config
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

DROP POLICY IF EXISTS p_loyalty_balance_owner ON sbp_customer_loyalty;
CREATE POLICY p_loyalty_balance_owner ON sbp_customer_loyalty
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

DROP POLICY IF EXISTS p_loyalty_txn_owner ON sbp_loyalty_transactions;
CREATE POLICY p_loyalty_txn_owner ON sbp_loyalty_transactions
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

-- ── 6. Helper: current balance ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_loyalty_balance(p_shop_id uuid, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_balance record;
  v_expiring_count int;
BEGIN
  -- Verify caller owns the shop
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  SELECT
    COALESCE(points_earned, 0)   AS earned,
    COALESCE(points_redeemed, 0) AS redeemed,
    COALESCE(points_expired, 0)  AS expired,
    COALESCE(points_earned - points_redeemed - points_expired, 0) AS balance,
    last_earned_at,
    last_redeemed_at
  INTO v_balance
  FROM sbp_customer_loyalty
  WHERE shop_id = p_shop_id AND customer_id = p_customer_id;

  -- Count points expiring in next 30 days
  SELECT COALESCE(SUM(points), 0) INTO v_expiring_count
  FROM sbp_loyalty_transactions
  WHERE shop_id = p_shop_id
    AND customer_id = p_customer_id
    AND txn_type = 'earn'
    AND expires_at IS NOT NULL
    AND expires_at > now()
    AND expires_at <= (now() + interval '30 days');

  RETURN jsonb_build_object(
    'ok', true,
    'balance', COALESCE(v_balance.balance, 0),
    'earned', COALESCE(v_balance.earned, 0),
    'redeemed', COALESCE(v_balance.redeemed, 0),
    'expired', COALESCE(v_balance.expired, 0),
    'last_earned_at', v_balance.last_earned_at,
    'last_redeemed_at', v_balance.last_redeemed_at,
    'expiring_30d', COALESCE(v_expiring_count, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_loyalty_balance(uuid, uuid) TO authenticated;

-- ── 7. Earn points on bill save ────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_loyalty_earn_on_bill(p_bill_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_bill record;
  v_config record;
  v_earn_base numeric;
  v_points int;
  v_expires_at timestamptz;
  v_new_balance bigint;
BEGIN
  -- Read bill (must exist + caller must own the shop)
  SELECT b.*, s.owner_id, s.plan
  INTO v_bill
  FROM bills b
  JOIN shops s ON s.id = b.shop_id
  WHERE b.id = p_bill_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  IF v_bill.owner_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Skip if no customer linked
  IF v_bill.customer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_customer', 'points', 0);
  END IF;

  -- Skip if bill is voided
  IF v_bill.voided_at IS NOT NULL OR v_bill.status = 'voided' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_voided', 'points', 0);
  END IF;

  -- Skip if already earned for this bill (idempotent)
  IF EXISTS (
    SELECT 1 FROM sbp_loyalty_transactions
    WHERE bill_id = p_bill_id AND txn_type = 'earn'
  ) THEN
    RETURN jsonb_build_object('ok', true, 'already_earned', true, 'points', v_bill.loyalty_points_earned);
  END IF;

  -- Read config (must be enabled + plan must be Pro/Business)
  SELECT * INTO v_config FROM sbp_loyalty_config WHERE shop_id = v_bill.shop_id;
  IF NOT FOUND OR NOT v_config.enabled THEN
    RETURN jsonb_build_object('ok', false, 'error', 'loyalty_disabled', 'points', 0);
  END IF;

  IF v_bill.plan = 'free' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'free_plan_no_loyalty', 'points', 0);
  END IF;

  -- Compute earn base
  IF v_config.earn_on_field = 'taxable_total' THEN
    v_earn_base := COALESCE(v_bill.subtotal, 0) - COALESCE(v_bill.discount, 0);
  ELSE
    v_earn_base := COALESCE(v_bill.grand_total, 0);
  END IF;

  -- Calculate points (floor of base / earn_rate_amount * earn_rate_points)
  v_points := floor(v_earn_base / v_config.earn_rate_amount) * v_config.earn_rate_points;

  IF v_points <= 0 THEN
    RETURN jsonb_build_object('ok', true, 'points', 0, 'reason', 'amount_too_small');
  END IF;

  -- Compute expiry
  IF v_config.expiry_months > 0 THEN
    v_expires_at := now() + (v_config.expiry_months || ' months')::interval;
  ELSE
    v_expires_at := NULL;
  END IF;

  -- Insert transaction
  INSERT INTO sbp_loyalty_transactions(
    shop_id, customer_id, bill_id, txn_type, points, description, expires_at, created_by
  ) VALUES (
    v_bill.shop_id, v_bill.customer_id, p_bill_id, 'earn', v_points,
    'Earned on bill ' || COALESCE(v_bill.invoice_no, p_bill_id::text),
    v_expires_at, auth.uid()
  );

  -- Update or insert balance row
  INSERT INTO sbp_customer_loyalty(shop_id, customer_id, points_earned, last_earned_at)
  VALUES (v_bill.shop_id, v_bill.customer_id, v_points, now())
  ON CONFLICT (shop_id, customer_id) DO UPDATE
  SET points_earned = sbp_customer_loyalty.points_earned + v_points,
      last_earned_at = now(),
      updated_at = now()
  RETURNING (points_earned - points_redeemed - points_expired) INTO v_new_balance;

  -- Stamp earned points on the bill
  UPDATE bills SET loyalty_points_earned = v_points WHERE id = p_bill_id;

  RETURN jsonb_build_object(
    'ok', true,
    'points', v_points,
    'new_balance', v_new_balance,
    'expires_at', v_expires_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_loyalty_earn_on_bill(uuid) TO authenticated;

-- ── 8. Redeem points (called BEFORE bill save, returns redemption amount) ─

CREATE OR REPLACE FUNCTION sbp_loyalty_redeem(
  p_shop_id     uuid,
  p_customer_id uuid,
  p_bill_id     uuid,         -- nullable, can stamp later if bill not yet saved
  p_points      int
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_config record;
  v_balance int;
  v_amount numeric;
  v_new_balance bigint;
BEGIN
  -- Verify ownership
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Read config
  SELECT * INTO v_config FROM sbp_loyalty_config WHERE shop_id = p_shop_id;
  IF NOT FOUND OR NOT v_config.enabled THEN
    RETURN jsonb_build_object('ok', false, 'error', 'loyalty_disabled');
  END IF;

  -- Validate points
  IF p_points IS NULL OR p_points <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_points');
  END IF;

  IF p_points < v_config.min_redeem_points THEN
    RETURN jsonb_build_object('ok', false, 'error', 'below_min_redeem',
                              'min_required', v_config.min_redeem_points);
  END IF;

  -- Must redeem in multiples of redeem_rate_points
  IF p_points % v_config.redeem_rate_points <> 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_multiple_of_rate',
                              'multiple_of', v_config.redeem_rate_points);
  END IF;

  -- Check current balance
  SELECT COALESCE(points_earned - points_redeemed - points_expired, 0) INTO v_balance
  FROM sbp_customer_loyalty WHERE shop_id = p_shop_id AND customer_id = p_customer_id;

  IF v_balance IS NULL OR v_balance < p_points THEN
    RETURN jsonb_build_object('ok', false, 'error', 'insufficient_balance',
                              'current_balance', COALESCE(v_balance, 0));
  END IF;

  -- Compute discount amount
  v_amount := (p_points::numeric / v_config.redeem_rate_points) * v_config.redeem_rate_amount;

  -- Insert redeem transaction
  INSERT INTO sbp_loyalty_transactions(
    shop_id, customer_id, bill_id, txn_type, points, description, created_by
  ) VALUES (
    p_shop_id, p_customer_id, p_bill_id, 'redeem', -p_points,
    'Redeemed for ₹' || v_amount::text || ' discount' ||
      CASE WHEN p_bill_id IS NOT NULL THEN ' on bill' ELSE '' END,
    auth.uid()
  );

  -- Update balance
  INSERT INTO sbp_customer_loyalty(shop_id, customer_id, points_redeemed, last_redeemed_at)
  VALUES (p_shop_id, p_customer_id, p_points, now())
  ON CONFLICT (shop_id, customer_id) DO UPDATE
  SET points_redeemed = sbp_customer_loyalty.points_redeemed + p_points,
      last_redeemed_at = now(),
      updated_at = now()
  RETURNING (points_earned - points_redeemed - points_expired) INTO v_new_balance;

  -- If bill_id provided, stamp it
  IF p_bill_id IS NOT NULL THEN
    UPDATE bills
    SET loyalty_redemption_amount = v_amount,
        loyalty_points_redeemed = p_points
    WHERE id = p_bill_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'points_redeemed', p_points,
    'discount_amount', v_amount,
    'new_balance', v_new_balance
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_loyalty_redeem(uuid, uuid, uuid, int) TO authenticated;

-- ── 9. Reverse loyalty on bill void ────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_loyalty_reverse_bill(p_bill_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_bill record;
  v_earn_txn record;
  v_redeem_txn record;
  v_total_reversed int := 0;
BEGIN
  -- Verify ownership via bill
  SELECT b.*, s.owner_id INTO v_bill
  FROM bills b JOIN shops s ON s.id = b.shop_id
  WHERE b.id = p_bill_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  IF v_bill.owner_id <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Reverse the earn (subtract earned points back)
  SELECT * INTO v_earn_txn
  FROM sbp_loyalty_transactions
  WHERE bill_id = p_bill_id AND txn_type = 'earn'
  ORDER BY created_at DESC LIMIT 1;

  IF FOUND AND v_earn_txn.points > 0 THEN
    INSERT INTO sbp_loyalty_transactions(
      shop_id, customer_id, bill_id, txn_type, points, description, created_by
    ) VALUES (
      v_earn_txn.shop_id, v_earn_txn.customer_id, p_bill_id,
      'void_reverse', -v_earn_txn.points,
      'Reversed: bill voided',
      auth.uid()
    );

    UPDATE sbp_customer_loyalty
    SET points_earned = GREATEST(0, points_earned - v_earn_txn.points),
        updated_at = now()
    WHERE shop_id = v_earn_txn.shop_id AND customer_id = v_earn_txn.customer_id;

    v_total_reversed := v_total_reversed + v_earn_txn.points;
  END IF;

  -- Restore the redemption (add points back)
  SELECT * INTO v_redeem_txn
  FROM sbp_loyalty_transactions
  WHERE bill_id = p_bill_id AND txn_type = 'redeem'
  ORDER BY created_at DESC LIMIT 1;

  IF FOUND AND v_redeem_txn.points < 0 THEN
    INSERT INTO sbp_loyalty_transactions(
      shop_id, customer_id, bill_id, txn_type, points, description, created_by
    ) VALUES (
      v_redeem_txn.shop_id, v_redeem_txn.customer_id, p_bill_id,
      'void_reverse', -v_redeem_txn.points,  -- v_redeem_txn.points is negative, so this becomes positive
      'Reversed: bill voided, points restored',
      auth.uid()
    );

    UPDATE sbp_customer_loyalty
    SET points_redeemed = GREATEST(0, points_redeemed + v_redeem_txn.points),
        updated_at = now()
    WHERE shop_id = v_redeem_txn.shop_id AND customer_id = v_redeem_txn.customer_id;

    v_total_reversed := v_total_reversed + (-v_redeem_txn.points);
  END IF;

  -- Clear bill stamps
  UPDATE bills
  SET loyalty_points_earned = 0,
      loyalty_points_redeemed = 0,
      loyalty_redemption_amount = 0
  WHERE id = p_bill_id;

  RETURN jsonb_build_object('ok', true, 'reversed_total', v_total_reversed);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_loyalty_reverse_bill(uuid) TO authenticated;

-- ── 10. Manual adjustment (admin / shop owner) ─────────────────────────

CREATE OR REPLACE FUNCTION sbp_loyalty_adjust(
  p_shop_id     uuid,
  p_customer_id uuid,
  p_points      int,         -- positive to give, negative to take
  p_reason      text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_new_balance bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF p_points = 0 OR p_points IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_points');
  END IF;

  INSERT INTO sbp_loyalty_transactions(
    shop_id, customer_id, txn_type, points, description, created_by
  ) VALUES (
    p_shop_id, p_customer_id, 'manual_adjust', p_points,
    COALESCE(p_reason, 'Manual adjustment'), auth.uid()
  );

  -- Update balance: +ve goes to earned, -ve goes to redeemed
  IF p_points > 0 THEN
    INSERT INTO sbp_customer_loyalty(shop_id, customer_id, points_earned)
    VALUES (p_shop_id, p_customer_id, p_points)
    ON CONFLICT (shop_id, customer_id) DO UPDATE
    SET points_earned = sbp_customer_loyalty.points_earned + p_points,
        updated_at = now()
    RETURNING (points_earned - points_redeemed - points_expired) INTO v_new_balance;
  ELSE
    INSERT INTO sbp_customer_loyalty(shop_id, customer_id, points_redeemed)
    VALUES (p_shop_id, p_customer_id, -p_points)
    ON CONFLICT (shop_id, customer_id) DO UPDATE
    SET points_redeemed = sbp_customer_loyalty.points_redeemed + (-p_points),
        updated_at = now()
    RETURNING (points_earned - points_redeemed - points_expired) INTO v_new_balance;
  END IF;

  RETURN jsonb_build_object('ok', true, 'new_balance', v_new_balance);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_loyalty_adjust(uuid, uuid, int, text) TO authenticated;

-- ── 11. Expiry job (run via pg_cron daily) ─────────────────────────────

CREATE OR REPLACE FUNCTION sbp_loyalty_expire_due()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  r record;
  v_count int := 0;
BEGIN
  -- Find earn transactions that have expired but not yet been expired
  FOR r IN
    SELECT DISTINCT t.shop_id, t.customer_id, t.id AS earn_txn_id, t.points
    FROM sbp_loyalty_transactions t
    WHERE t.txn_type = 'earn'
      AND t.expires_at IS NOT NULL
      AND t.expires_at < now()
      AND NOT EXISTS (
        SELECT 1 FROM sbp_loyalty_transactions e
        WHERE e.shop_id = t.shop_id
          AND e.customer_id = t.customer_id
          AND e.txn_type = 'expire'
          AND e.description = 'Expired txn ' || t.id::text
      )
  LOOP
    INSERT INTO sbp_loyalty_transactions(
      shop_id, customer_id, txn_type, points, description
    ) VALUES (
      r.shop_id, r.customer_id, 'expire', -r.points,
      'Expired txn ' || r.earn_txn_id::text
    );

    UPDATE sbp_customer_loyalty
    SET points_expired = points_expired + r.points,
        updated_at = now()
    WHERE shop_id = r.shop_id AND customer_id = r.customer_id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- Optional: schedule daily via pg_cron (run once after deploy):
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   SELECT cron.schedule('loyalty-expire-daily', '30 1 * * *',
--     $$ SELECT public.sbp_loyalty_expire_due(); $$);

-- ── 12. List recent transactions (for customer detail page) ────────────

CREATE OR REPLACE FUNCTION sbp_loyalty_recent_txns(
  p_shop_id     uuid,
  p_customer_id uuid,
  p_limit       int DEFAULT 20
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, txn_type, points, description, bill_id, expires_at, created_at
    FROM sbp_loyalty_transactions
    WHERE shop_id = p_shop_id AND customer_id = p_customer_id
    ORDER BY created_at DESC
    LIMIT GREATEST(1, LEAST(p_limit, 100))
  ) r;

  RETURN jsonb_build_object('ok', true, 'txns', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_loyalty_recent_txns(uuid, uuid, int) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- Verification queries (run manually after deploy):
--
-- -- 1. Check tables exist
-- SELECT count(*) FROM sbp_loyalty_config;
-- SELECT count(*) FROM sbp_customer_loyalty;
-- SELECT count(*) FROM sbp_loyalty_transactions;
--
-- -- 2. Enable loyalty for a test shop
-- INSERT INTO sbp_loyalty_config(shop_id, enabled)
-- VALUES ('<shop-id>', true)
-- ON CONFLICT (shop_id) DO UPDATE SET enabled = true;
--
-- -- 3. Test balance check (returns 0 for new customer)
-- SELECT sbp_loyalty_balance('<shop-id>', '<customer-id>');
--
-- -- 4. Test manual adjust (give 500 points)
-- SELECT sbp_loyalty_adjust('<shop-id>', '<customer-id>', 500, 'Welcome bonus');
--
-- -- 5. Test redeem (200 points = ₹20 default)
-- SELECT sbp_loyalty_redeem('<shop-id>', '<customer-id>', NULL, 200);
-- ════════════════════════════════════════════════════════════════════
