-- ════════════════════════════════════════════════════════════════
-- ShopBill Pro — Migration 005: Beta Plan Logic
-- ════════════════════════════════════════════════════════════════
-- Run AFTER migrations 003 and 004.
-- Idempotent — safe to re-run.
--
-- This migration adds the server-side helpers for the 60-day beta:
--   - Default new signups to 'business' plan with 60-day expiry
--   - Track grace period (Day 61–67 read-only)
--   - Auto-downgrade on grace expiry
--   - Beta-mode flag in admin_settings (single switch to turn beta on/off)
--   - Helper RPCs the client uses to know "are we in beta?"
-- ════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════
-- 1. Beta-mode flag in admin_settings
-- ══════════════════════════════════════════════════════════════
-- A single switch the admin can flip in the UI to enable/disable
-- new beta signups. Existing beta users are unaffected.

INSERT INTO admin_settings (key, value, is_secret, description) VALUES
  ('beta_mode_active',     'true',     false, 'true = new signups get 60-day Business beta. false = normal signup flow.'),
  ('beta_duration_days',   '60',       false, 'Number of days beta access lasts after signup'),
  ('beta_grace_days',      '7',        false, 'Days after beta ends during which data stays read-only (no auto-downgrade)'),
  ('beta_end_date',        '',         false, 'Optional hard end date (YYYY-MM-DD). If set, all beta users expire on this date regardless of signup date.'),
  ('beta_announcement',    'Free Beta — all features till {expiry_date}. No card needed.', false, 'Banner text shown to beta users. Use {expiry_date} placeholder.')
ON CONFLICT (key) DO NOTHING;


-- ══════════════════════════════════════════════════════════════
-- 2. Add beta-tracking columns to sbp_shop
-- ══════════════════════════════════════════════════════════════
-- Existing schema has plan + plan_expires_at. We add:
--   is_beta_signup (true if shop signed up during beta)
--   beta_grace_until (computed: plan_expires_at + grace days)
--   plan_pre_beta (the plan they had before beta — for downgrade target)

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'sbp_shop' AND column_name = 'is_beta_signup'
  ) THEN
    ALTER TABLE sbp_shop ADD COLUMN is_beta_signup boolean DEFAULT false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'sbp_shop' AND column_name = 'beta_grace_until'
  ) THEN
    ALTER TABLE sbp_shop ADD COLUMN beta_grace_until timestamptz;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'sbp_shop' AND column_name = 'plan_pre_beta'
  ) THEN
    ALTER TABLE sbp_shop ADD COLUMN plan_pre_beta text DEFAULT 'free';
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_shop_beta_signup ON sbp_shop(is_beta_signup) WHERE is_beta_signup = true;
CREATE INDEX IF NOT EXISTS idx_shop_grace_until ON sbp_shop(beta_grace_until) WHERE beta_grace_until IS NOT NULL;


-- ══════════════════════════════════════════════════════════════
-- 3. Helper: is beta mode currently active?
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.is_beta_mode_active()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT COALESCE((SELECT value FROM admin_settings WHERE key = 'beta_mode_active'), 'false') = 'true';
$$;

GRANT EXECUTE ON FUNCTION public.is_beta_mode_active() TO authenticated, anon;


-- ══════════════════════════════════════════════════════════════
-- 4. Helper: get beta config (used by client to render banner)
-- ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_beta_config()
RETURNS TABLE (
  is_active boolean,
  duration_days integer,
  grace_days integer,
  end_date date,
  announcement_template text
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT
    is_beta_mode_active() AS is_active,
    COALESCE(NULLIF((SELECT value FROM admin_settings WHERE key = 'beta_duration_days'), '')::int, 60) AS duration_days,
    COALESCE(NULLIF((SELECT value FROM admin_settings WHERE key = 'beta_grace_days'), '')::int, 7) AS grace_days,
    NULLIF((SELECT value FROM admin_settings WHERE key = 'beta_end_date'), '')::date AS end_date,
    COALESCE((SELECT value FROM admin_settings WHERE key = 'beta_announcement'), '') AS announcement_template;
$$;

GRANT EXECUTE ON FUNCTION public.get_beta_config() TO authenticated, anon;


-- ══════════════════════════════════════════════════════════════
-- 5. Apply beta plan to a shop (called from signup flow)
-- ══════════════════════════════════════════════════════════════
-- Called by client code (or signup trigger) right after a shop is created.
-- Sets plan='business', plan_expires_at = signup + duration, marks as beta.
-- Idempotent: re-calling doesn't extend an existing beta.
--
-- If beta_end_date is set in admin settings, that date is the hard expiry.
-- Otherwise, signup_date + beta_duration_days.

CREATE OR REPLACE FUNCTION public.apply_beta_plan(p_shop_id uuid)
RETURNS sbp_shop
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_shop sbp_shop;
  v_duration int;
  v_grace int;
  v_end_date date;
  v_signup timestamptz;
  v_expires timestamptz;
  v_grace_until timestamptz;
BEGIN
  -- Skip if beta mode is not active
  IF NOT is_beta_mode_active() THEN
    SELECT * INTO v_shop FROM sbp_shop WHERE id = p_shop_id;
    RETURN v_shop;
  END IF;

  -- Read current shop
  SELECT * INTO v_shop FROM sbp_shop WHERE id = p_shop_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shop not found: %', p_shop_id;
  END IF;

  -- Skip if already a beta signup (idempotent)
  IF v_shop.is_beta_signup THEN
    RETURN v_shop;
  END IF;

  -- Read beta config
  v_duration := COALESCE(NULLIF((SELECT value FROM admin_settings WHERE key = 'beta_duration_days'), '')::int, 60);
  v_grace    := COALESCE(NULLIF((SELECT value FROM admin_settings WHERE key = 'beta_grace_days'), '')::int, 7);
  v_end_date := NULLIF((SELECT value FROM admin_settings WHERE key = 'beta_end_date'), '')::date;

  -- Compute expiry: if hard end date set, use it; otherwise signup + duration
  v_signup := COALESCE(v_shop.created_at, now());
  IF v_end_date IS NOT NULL THEN
    v_expires := (v_end_date::timestamptz + interval '23 hours 59 minutes 59 seconds');
  ELSE
    v_expires := v_signup + (v_duration || ' days')::interval;
  END IF;

  v_grace_until := v_expires + (v_grace || ' days')::interval;

  -- Apply
  UPDATE sbp_shop SET
    plan_pre_beta    = COALESCE(plan, 'free'),
    plan             = 'business',
    plan_expires_at  = v_expires,
    is_beta_signup   = true,
    beta_grace_until = v_grace_until
  WHERE id = p_shop_id
  RETURNING * INTO v_shop;

  RETURN v_shop;
END $$;

GRANT EXECUTE ON FUNCTION public.apply_beta_plan(uuid) TO authenticated;


-- ══════════════════════════════════════════════════════════════
-- 6. Helper: shop's current beta status (used by client banner)
-- ══════════════════════════════════════════════════════════════
-- Returns days_left, is_in_grace, is_expired, etc.
CREATE OR REPLACE FUNCTION public.get_shop_beta_status(p_shop_id uuid)
RETURNS TABLE (
  is_beta_signup     boolean,
  plan               text,
  plan_expires_at    timestamptz,
  beta_grace_until   timestamptz,
  days_left          integer,
  hours_left         integer,
  is_in_grace        boolean,
  is_fully_expired   boolean,
  status_label       text
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_shop sbp_shop;
  v_now timestamptz := now();
BEGIN
  SELECT * INTO v_shop FROM sbp_shop WHERE id = p_shop_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  is_beta_signup    := v_shop.is_beta_signup;
  plan              := v_shop.plan;
  plan_expires_at   := v_shop.plan_expires_at;
  beta_grace_until  := v_shop.beta_grace_until;

  IF v_shop.plan_expires_at IS NOT NULL THEN
    days_left  := GREATEST(0, EXTRACT(EPOCH FROM (v_shop.plan_expires_at - v_now)) / 86400)::int;
    hours_left := GREATEST(0, EXTRACT(EPOCH FROM (v_shop.plan_expires_at - v_now)) / 3600)::int;
  ELSE
    days_left := NULL;
    hours_left := NULL;
  END IF;

  is_in_grace      := v_shop.is_beta_signup
                      AND v_shop.plan_expires_at IS NOT NULL
                      AND v_now > v_shop.plan_expires_at
                      AND v_shop.beta_grace_until IS NOT NULL
                      AND v_now <= v_shop.beta_grace_until;

  is_fully_expired := v_shop.is_beta_signup
                      AND v_shop.beta_grace_until IS NOT NULL
                      AND v_now > v_shop.beta_grace_until;

  status_label := CASE
    WHEN NOT v_shop.is_beta_signup THEN 'not_beta'
    WHEN is_fully_expired           THEN 'expired'
    WHEN is_in_grace                THEN 'grace'
    WHEN days_left IS NOT NULL AND days_left <= 1 THEN 'urgent'
    WHEN days_left IS NOT NULL AND days_left <= 3 THEN 'ending_soon'
    WHEN days_left IS NOT NULL AND days_left <= 7 THEN 'ending_week'
    ELSE 'active'
  END;

  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION public.get_shop_beta_status(uuid) TO authenticated;


-- ══════════════════════════════════════════════════════════════
-- 7. Cron-able function: process beta lifecycle transitions
-- ══════════════════════════════════════════════════════════════
-- Run nightly via Supabase pg_cron (or manually from admin):
--   - Shops past plan_expires_at but inside grace: status stays beta but
--     reads will show 'grace' (no plan change yet)
--   - Shops past beta_grace_until: revert plan to plan_pre_beta (default 'free')

CREATE OR REPLACE FUNCTION public.process_beta_transitions()
RETURNS TABLE (
  expired_count integer,
  graced_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_expired int := 0;
  v_graced int := 0;
BEGIN
  -- Auto-downgrade shops whose grace period has ended
  UPDATE sbp_shop SET
    plan = COALESCE(plan_pre_beta, 'free'),
    plan_expires_at = NULL
  WHERE is_beta_signup = true
    AND beta_grace_until IS NOT NULL
    AND now() > beta_grace_until
    AND plan = 'business';
  GET DIAGNOSTICS v_expired = ROW_COUNT;

  -- Count shops currently in grace (informational)
  SELECT COUNT(*) INTO v_graced FROM sbp_shop
  WHERE is_beta_signup = true
    AND plan_expires_at IS NOT NULL
    AND beta_grace_until IS NOT NULL
    AND now() > plan_expires_at
    AND now() <= beta_grace_until;

  expired_count := v_expired;
  graced_count := v_graced;
  RETURN NEXT;
END $$;

-- Admin-only invocation (no anon access)
GRANT EXECUTE ON FUNCTION public.process_beta_transitions() TO authenticated;


-- ══════════════════════════════════════════════════════════════
-- 8. Admin RPC: get beta dashboard stats
-- ══════════════════════════════════════════════════════════════
-- For admin-dashboard.html: how many shops are in beta, how many expiring,
-- conversion intent percentages.

CREATE OR REPLACE FUNCTION public.admin_get_beta_stats(p_token text)
RETURNS TABLE (
  total_beta_shops      integer,
  active_now            integer,    -- not yet expired
  ending_in_7_days      integer,
  ending_in_3_days      integer,
  in_grace              integer,
  fully_expired         integer
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  total_beta_shops := (SELECT COUNT(*) FROM sbp_shop WHERE is_beta_signup = true);

  active_now := (SELECT COUNT(*) FROM sbp_shop
                 WHERE is_beta_signup = true
                   AND plan = 'business'
                   AND (plan_expires_at IS NULL OR plan_expires_at > now()));

  ending_in_7_days := (SELECT COUNT(*) FROM sbp_shop
                       WHERE is_beta_signup = true
                         AND plan_expires_at IS NOT NULL
                         AND plan_expires_at > now()
                         AND plan_expires_at <= now() + interval '7 days');

  ending_in_3_days := (SELECT COUNT(*) FROM sbp_shop
                       WHERE is_beta_signup = true
                         AND plan_expires_at IS NOT NULL
                         AND plan_expires_at > now()
                         AND plan_expires_at <= now() + interval '3 days');

  in_grace := (SELECT COUNT(*) FROM sbp_shop
               WHERE is_beta_signup = true
                 AND plan_expires_at IS NOT NULL
                 AND now() > plan_expires_at
                 AND beta_grace_until IS NOT NULL
                 AND now() <= beta_grace_until);

  fully_expired := (SELECT COUNT(*) FROM sbp_shop
                    WHERE is_beta_signup = true
                      AND beta_grace_until IS NOT NULL
                      AND now() > beta_grace_until);

  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION public.admin_get_beta_stats(text) TO authenticated;


-- ══════════════════════════════════════════════════════════════
-- DONE — Migration 005 complete.
-- ══════════════════════════════════════════════════════════════
-- Verify with:
--   SELECT * FROM get_beta_config();
--   SELECT is_beta_mode_active();
--   SELECT * FROM admin_get_beta_stats('your_admin_token');
--
-- To turn beta mode off later (post-launch):
--   UPDATE admin_settings SET value = 'false' WHERE key = 'beta_mode_active';
--
-- To set a hard beta end date (override per-signup expiry):
--   UPDATE admin_settings SET value = '2026-09-01' WHERE key = 'beta_end_date';
-- ══════════════════════════════════════════════════════════════
