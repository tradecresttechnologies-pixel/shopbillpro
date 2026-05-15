-- ════════════════════════════════════════════════════════════════
-- ShopBill Pro — Admin Panel Full Build
-- Run this AFTER audit_round_db_patch.sql in Supabase SQL Editor.
-- ════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────
-- 1. admin_settings — encrypted config storage
-- ──────────────────────────────────────────────
-- Stores Razorpay keys, UPI IDs, plan prices, etc.
-- Secrets are stored AES-encrypted via pgcrypto.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS admin_settings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key           text UNIQUE NOT NULL,
  value         text,                    -- plain values (not secrets)
  value_encrypted bytea,                 -- encrypted secret values
  is_secret     boolean DEFAULT false,
  description   text,
  updated_at    timestamptz DEFAULT now(),
  updated_by    text
);

-- Seed default rows so admin UI has something to edit
INSERT INTO admin_settings (key, value, is_secret, description) VALUES
  ('razorpay_key_id',        '',          false, 'Razorpay Key ID (rzp_test_... or rzp_live_...)'),
  ('razorpay_mode',          'test',      false, 'test or live — must match key'),
  ('razorpay_webhook_secret','',          false, 'Optional separate webhook secret (else key_secret used)'),
  ('upi_receiving_id',       '',          false, 'Your UPI ID for direct UPI payments'),
  ('admin_whatsapp',         '',          false, 'Your 10-digit number with country code (no +)'),
  ('plan_pro_monthly',       '99',        false, 'Pro plan monthly price (₹)'),
  ('plan_pro_yearly',        '999',       false, 'Pro plan yearly price (₹)'),
  ('plan_business_monthly',  '199',       false, 'Business plan monthly price (₹)'),
  ('plan_business_yearly',   '1999',      false, 'Business plan yearly price (₹)'),
  ('free_bills_per_month',   '999999',    false, 'Bills allowed per month on free plan')
ON CONFLICT (key) DO NOTHING;

-- Encryption key — pulled from a Postgres setting named app.encryption_key
-- You set this once via:
--   ALTER DATABASE postgres SET app.encryption_key = 'your-32-char-random-string-here';
-- Then reload Supabase for it to take effect.

-- Public read function — returns NON-SECRET values only (anyone authenticated can read price/mode)
CREATE OR REPLACE FUNCTION public.get_admin_setting(p_key text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_val text;
  v_is_secret boolean;
BEGIN
  SELECT value, is_secret INTO v_val, v_is_secret
  FROM admin_settings WHERE key = p_key;
  IF v_is_secret THEN
    RETURN NULL;  -- never expose secrets via this function
  END IF;
  RETURN v_val;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_admin_setting(text) TO authenticated, anon;

-- Admin-only read function — returns ALL values including decrypted secrets
-- Caller must be in admin_session (we'll mark this via RLS context)
CREATE OR REPLACE FUNCTION public.admin_get_all_settings(p_admin_token text)
RETURNS TABLE(key text, value text, is_secret boolean, description text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Verify admin token matches a known hash (set via admin_set_master_token below)
  IF NOT EXISTS (
    SELECT 1 FROM admin_settings
    WHERE key = 'admin_token_hash'
      AND value = encode(digest(p_admin_token, 'sha256'), 'hex')
  ) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;

  RETURN QUERY
  SELECT s.key,
         CASE WHEN s.is_secret AND s.value_encrypted IS NOT NULL
              THEN convert_from(
                     pgp_sym_decrypt_bytea(s.value_encrypted, current_setting('app.encryption_key', true)),
                     'utf8')
              ELSE s.value
         END AS value,
         s.is_secret,
         s.description
  FROM admin_settings s
  WHERE s.key NOT IN ('admin_token_hash')  -- never return the token itself
  ORDER BY s.key;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_get_all_settings(text) TO authenticated, anon;

-- Admin-only write function — stores secret encrypted, plain otherwise
CREATE OR REPLACE FUNCTION public.admin_set_setting(
  p_admin_token text,
  p_key text,
  p_value text,
  p_is_secret boolean DEFAULT false
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM admin_settings
    WHERE key = 'admin_token_hash'
      AND value = encode(digest(p_admin_token, 'sha256'), 'hex')
  ) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;

  IF p_is_secret AND p_value IS NOT NULL AND p_value <> '' THEN
    INSERT INTO admin_settings (key, value_encrypted, is_secret, updated_at)
    VALUES (
      p_key,
      pgp_sym_encrypt_bytea(p_value::bytea, current_setting('app.encryption_key', true)),
      true,
      now()
    )
    ON CONFLICT (key) DO UPDATE
      SET value_encrypted = EXCLUDED.value_encrypted,
          is_secret = true,
          value = NULL,
          updated_at = now();
  ELSE
    INSERT INTO admin_settings (key, value, is_secret, updated_at)
    VALUES (p_key, p_value, COALESCE(p_is_secret, false), now())
    ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value,
          is_secret = EXCLUDED.is_secret,
          value_encrypted = NULL,
          updated_at = now();
  END IF;
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_set_setting(text, text, text, boolean) TO authenticated, anon;

-- One-time admin token setup — call this once with your chosen master password
-- The token is what the admin panel will pass to admin_get_all_settings/admin_set_setting.
CREATE OR REPLACE FUNCTION public.admin_set_master_token(p_new_token text, p_old_token text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_existing text;
BEGIN
  SELECT value INTO v_existing FROM admin_settings WHERE key = 'admin_token_hash';
  -- If a token already exists, require the old one to change it
  IF v_existing IS NOT NULL AND v_existing <> '' THEN
    IF p_old_token IS NULL OR encode(digest(p_old_token, 'sha256'), 'hex') <> v_existing THEN
      RAISE EXCEPTION 'Old token required to change master token';
    END IF;
  END IF;
  INSERT INTO admin_settings (key, value, is_secret, description)
  VALUES ('admin_token_hash', encode(digest(p_new_token, 'sha256'), 'hex'), false, 'SHA-256 of admin master password')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_set_master_token(text, text) TO authenticated, anon;

-- Verify token (used by admin login flow)
CREATE OR REPLACE FUNCTION public.admin_verify_token(p_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_hash text;
BEGIN
  SELECT value INTO v_hash FROM admin_settings WHERE key = 'admin_token_hash';
  IF v_hash IS NULL THEN
    -- No token set yet → bootstrap mode: accept default 'SBP_ADMIN_2024_SECURE'
    RETURN p_token = 'SBP_ADMIN_2024_SECURE';
  END IF;
  RETURN encode(digest(p_token, 'sha256'), 'hex') = v_hash;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_verify_token(text) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 2. webhook_events — Razorpay webhook log
-- ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS webhook_events (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source        text NOT NULL,            -- 'razorpay', 'paytm', etc.
  event_type    text,                     -- 'payment.captured', etc.
  payload       jsonb,
  signature_ok  boolean,
  processed     boolean DEFAULT false,
  process_error text,
  created_at    timestamptz DEFAULT now(),
  shop_id       uuid,
  subscription_id uuid
);

CREATE INDEX IF NOT EXISTS idx_webhook_events_created ON webhook_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_webhook_events_processed ON webhook_events(processed, created_at);

-- ──────────────────────────────────────────────
-- 3. admin_audit_log — track admin actions
-- ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS admin_audit_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action        text NOT NULL,            -- 'approve_subscription', 'change_plan', etc.
  target_type   text,                     -- 'shop', 'subscription', 'setting'
  target_id     text,
  before_data   jsonb,
  after_data    jsonb,
  notes         text,
  created_at    timestamptz DEFAULT now(),
  ip            text
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON admin_audit_log(created_at DESC);

CREATE OR REPLACE FUNCTION public.admin_log_action(
  p_admin_token text,
  p_action text,
  p_target_type text DEFAULT NULL,
  p_target_id text DEFAULT NULL,
  p_before jsonb DEFAULT NULL,
  p_after jsonb DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;
  INSERT INTO admin_audit_log (action, target_type, target_id, before_data, after_data, notes)
  VALUES (p_action, p_target_type, p_target_id, p_before, p_after, p_notes)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_log_action(text, text, text, text, jsonb, jsonb, text) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 4. Subscription approve/reject RPCs
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_approve_subscription(
  p_admin_token text,
  p_subscription_id uuid,
  p_notes text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sub record;
  v_expires timestamptz;
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;
  SELECT * INTO v_sub FROM subscriptions WHERE id = p_subscription_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription not found';
  END IF;

  -- Compute expiry
  v_expires := COALESCE(v_sub.expires_at,
                CASE WHEN v_sub.billing_cycle = 'yearly' THEN now() + interval '1 year'
                     ELSE now() + interval '1 month' END);

  -- Update subscription → trigger 'subscription_apply_to_shop' from earlier patch will activate the plan
  UPDATE subscriptions
     SET status = 'active', expires_at = v_expires
   WHERE id = p_subscription_id;

  -- Audit
  INSERT INTO admin_audit_log (action, target_type, target_id, before_data, after_data, notes)
  VALUES ('approve_subscription', 'subscription', p_subscription_id::text,
          jsonb_build_object('status', v_sub.status),
          jsonb_build_object('status', 'active', 'expires_at', v_expires),
          p_notes);
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_approve_subscription(text, uuid, text) TO authenticated, anon;

CREATE OR REPLACE FUNCTION public.admin_reject_subscription(
  p_admin_token text,
  p_subscription_id uuid,
  p_notes text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sub record;
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;
  SELECT * INTO v_sub FROM subscriptions WHERE id = p_subscription_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Subscription not found'; END IF;

  UPDATE subscriptions SET status = 'rejected', notes = COALESCE(p_notes, notes) WHERE id = p_subscription_id;

  INSERT INTO admin_audit_log (action, target_type, target_id, before_data, after_data, notes)
  VALUES ('reject_subscription', 'subscription', p_subscription_id::text,
          jsonb_build_object('status', v_sub.status),
          jsonb_build_object('status', 'rejected'), p_notes);
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_reject_subscription(text, uuid, text) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 5. Admin user management RPCs
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_change_plan(
  p_admin_token text,
  p_shop_id uuid,
  p_new_plan text,
  p_expires_at timestamptz DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_old record;
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;
  IF p_new_plan NOT IN ('free','pro','business') THEN
    RAISE EXCEPTION 'Invalid plan: %', p_new_plan;
  END IF;
  SELECT plan, plan_expires_at INTO v_old FROM shops WHERE id = p_shop_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Shop not found'; END IF;

  UPDATE shops SET plan = p_new_plan, plan_expires_at = p_expires_at WHERE id = p_shop_id;

  INSERT INTO admin_audit_log (action, target_type, target_id, before_data, after_data, notes)
  VALUES ('change_plan', 'shop', p_shop_id::text,
          jsonb_build_object('plan', v_old.plan, 'expires_at', v_old.plan_expires_at),
          jsonb_build_object('plan', p_new_plan, 'expires_at', p_expires_at),
          p_notes);
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_change_plan(text, uuid, text, timestamptz, text) TO authenticated, anon;

-- Shop suspend/unsuspend
ALTER TABLE shops ADD COLUMN IF NOT EXISTS suspended boolean DEFAULT false;
ALTER TABLE shops ADD COLUMN IF NOT EXISTS suspended_reason text;

CREATE OR REPLACE FUNCTION public.admin_suspend_shop(
  p_admin_token text,
  p_shop_id uuid,
  p_suspend boolean,
  p_reason text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;
  UPDATE shops SET suspended = p_suspend, suspended_reason = CASE WHEN p_suspend THEN p_reason ELSE NULL END WHERE id = p_shop_id;
  INSERT INTO admin_audit_log (action, target_type, target_id, after_data, notes)
  VALUES (CASE WHEN p_suspend THEN 'suspend_shop' ELSE 'unsuspend_shop' END,
          'shop', p_shop_id::text,
          jsonb_build_object('suspended', p_suspend),
          p_reason);
  RETURN true;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_suspend_shop(text, uuid, boolean, text) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 6. Metrics RPCs (real numbers, not mock)
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_metrics(p_admin_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total_shops int;
  v_pro_shops int;
  v_business_shops int;
  v_active_paid int;
  v_today_revenue numeric;
  v_week_revenue numeric;
  v_month_revenue numeric;
  v_mrr numeric;
  v_pending_subs int;
  v_total_bills int;
  v_today_signups int;
  v_week_signups int;
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;

  SELECT COUNT(*) INTO v_total_shops FROM shops;
  SELECT COUNT(*) INTO v_pro_shops FROM shops WHERE plan IN ('pro');
  SELECT COUNT(*) INTO v_business_shops FROM shops WHERE plan IN ('business','enterprise');
  SELECT COUNT(*) INTO v_active_paid FROM shops
    WHERE plan IN ('pro','business','enterprise')
      AND (plan_expires_at IS NULL OR plan_expires_at > now());

  SELECT COALESCE(SUM(amount),0) INTO v_today_revenue FROM subscriptions
    WHERE status = 'active' AND created_at >= date_trunc('day', now());
  SELECT COALESCE(SUM(amount),0) INTO v_week_revenue FROM subscriptions
    WHERE status = 'active' AND created_at >= now() - interval '7 days';
  SELECT COALESCE(SUM(amount),0) INTO v_month_revenue FROM subscriptions
    WHERE status = 'active' AND created_at >= date_trunc('month', now());

  -- MRR: active subs, monthly equivalent
  SELECT COALESCE(SUM(
    CASE WHEN billing_cycle = 'yearly' THEN amount / 12.0 ELSE amount END
  ),0) INTO v_mrr FROM subscriptions
   WHERE status = 'active'
     AND (expires_at IS NULL OR expires_at > now());

  SELECT COUNT(*) INTO v_pending_subs FROM subscriptions WHERE status = 'pending_verification';
  SELECT COUNT(*) INTO v_total_bills FROM bills WHERE status <> 'Voided';
  SELECT COUNT(*) INTO v_today_signups FROM shops WHERE created_at >= date_trunc('day', now());
  SELECT COUNT(*) INTO v_week_signups FROM shops WHERE created_at >= now() - interval '7 days';

  RETURN jsonb_build_object(
    'total_shops', v_total_shops,
    'pro_shops', v_pro_shops,
    'business_shops', v_business_shops,
    'free_shops', v_total_shops - v_pro_shops - v_business_shops,
    'active_paid', v_active_paid,
    'today_revenue', v_today_revenue,
    'week_revenue', v_week_revenue,
    'month_revenue', v_month_revenue,
    'mrr', v_mrr,
    'arr', v_mrr * 12,
    'pending_subscriptions', v_pending_subs,
    'total_bills', v_total_bills,
    'today_signups', v_today_signups,
    'week_signups', v_week_signups,
    'conversion_rate', CASE WHEN v_total_shops > 0 THEN ROUND(((v_pro_shops + v_business_shops)::numeric / v_total_shops::numeric) * 100, 2) ELSE 0 END
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_metrics(text) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 7. List shops for user management page
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_list_shops(
  p_admin_token text,
  p_search text DEFAULT NULL,
  p_plan_filter text DEFAULT NULL,
  p_limit int DEFAULT 100,
  p_offset int DEFAULT 0
) RETURNS TABLE(
  id uuid, name text, owner_name text, email text, phone text,
  plan text, plan_expires_at timestamptz, suspended boolean,
  created_at timestamptz, bill_count bigint, total_revenue numeric, last_activity timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;
  RETURN QUERY
  SELECT s.id, s.name, s.owner_name, s.email, s.phone,
         s.plan, s.plan_expires_at, s.suspended,
         s.created_at,
         (SELECT COUNT(*) FROM bills b WHERE b.shop_id = s.id AND b.status <> 'Voided') AS bill_count,
         COALESCE((SELECT SUM(grand_total) FROM bills b WHERE b.shop_id = s.id AND b.status <> 'Voided'),0) AS total_revenue,
         (SELECT MAX(created_at) FROM bills b WHERE b.shop_id = s.id) AS last_activity
    FROM shops s
   WHERE (p_search IS NULL OR p_search = '' OR
          s.name ILIKE '%' || p_search || '%' OR
          s.owner_name ILIKE '%' || p_search || '%' OR
          s.email ILIKE '%' || p_search || '%' OR
          s.phone ILIKE '%' || p_search || '%')
     AND (p_plan_filter IS NULL OR p_plan_filter = '' OR p_plan_filter = 'all'
          OR (p_plan_filter = 'free' AND (s.plan IS NULL OR s.plan = 'free'))
          OR (p_plan_filter = s.plan)
          OR (p_plan_filter = 'business' AND s.plan = 'enterprise'))
   ORDER BY s.created_at DESC
   LIMIT p_limit OFFSET p_offset;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_list_shops(text, text, text, int, int) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 8. List subscriptions for subscription management
-- ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_list_subscriptions(
  p_admin_token text,
  p_status_filter text DEFAULT NULL,
  p_limit int DEFAULT 100
) RETURNS TABLE(
  id uuid, shop_id uuid, shop_name text, owner_name text,
  plan text, billing_cycle text, amount numeric, status text,
  payment_method text, payment_ref text, expires_at timestamptz,
  created_at timestamptz, notes text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT public.admin_verify_token(p_admin_token) THEN
    RAISE EXCEPTION 'Invalid admin token';
  END IF;
  RETURN QUERY
  SELECT sub.id, sub.shop_id, s.name, s.owner_name,
         sub.plan, sub.billing_cycle, sub.amount, sub.status,
         sub.payment_method, sub.payment_ref, sub.expires_at,
         sub.created_at, sub.notes
    FROM subscriptions sub
    LEFT JOIN shops s ON s.id = sub.shop_id
   WHERE (p_status_filter IS NULL OR p_status_filter = '' OR p_status_filter = 'all'
          OR sub.status = p_status_filter)
   ORDER BY sub.created_at DESC
   LIMIT p_limit;
END;
$$;
GRANT EXECUTE ON FUNCTION public.admin_list_subscriptions(text, text, int) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 9. Razorpay webhook handler (called by Edge Function)
-- ──────────────────────────────────────────────
-- This RPC is called by the webhook Edge Function AFTER it has
-- verified the HMAC signature. It logs the event and activates the subscription.

CREATE OR REPLACE FUNCTION public.process_razorpay_webhook(
  p_payload jsonb,
  p_signature_ok boolean
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_event_id uuid;
  v_event_type text;
  v_payment_id text;
  v_order_id text;
  v_amount numeric;
  v_sub record;
BEGIN
  v_event_type := p_payload->>'event';
  v_payment_id := p_payload#>>'{payload,payment,entity,id}';
  v_order_id   := p_payload#>>'{payload,payment,entity,order_id}';
  v_amount     := (p_payload#>>'{payload,payment,entity,amount}')::numeric / 100; -- paise→rupees

  INSERT INTO webhook_events (source, event_type, payload, signature_ok, processed)
  VALUES ('razorpay', v_event_type, p_payload, p_signature_ok, false)
  RETURNING id INTO v_event_id;

  IF NOT p_signature_ok THEN
    UPDATE webhook_events SET process_error = 'signature verification failed' WHERE id = v_event_id;
    RETURN v_event_id;
  END IF;

  -- Only act on payment.captured events
  IF v_event_type = 'payment.captured' AND v_payment_id IS NOT NULL THEN
    -- Find matching subscription by payment_ref OR razorpay_order_id
    SELECT * INTO v_sub FROM subscriptions
     WHERE (payment_ref = v_payment_id OR razorpay_order_id = v_order_id)
       AND status = 'pending_verification'
     LIMIT 1;

    IF FOUND THEN
      -- Activate via existing trigger
      UPDATE subscriptions
         SET status = 'active',
             expires_at = COALESCE(expires_at,
                CASE WHEN billing_cycle = 'yearly' THEN now() + interval '1 year'
                     ELSE now() + interval '1 month' END)
       WHERE id = v_sub.id;
      UPDATE webhook_events
         SET processed = true, subscription_id = v_sub.id, shop_id = v_sub.shop_id
       WHERE id = v_event_id;
    ELSE
      UPDATE webhook_events
         SET processed = true, process_error = 'no matching pending subscription'
       WHERE id = v_event_id;
    END IF;
  ELSE
    UPDATE webhook_events SET processed = true WHERE id = v_event_id;
  END IF;
  RETURN v_event_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.process_razorpay_webhook(jsonb, boolean) TO authenticated, anon;

-- ──────────────────────────────────────────────
-- 10. Bootstrap message
-- ──────────────────────────────────────────────
-- After running this, do these manual steps:
-- 1. Set encryption key (one time, via Supabase Dashboard → SQL Editor):
--      ALTER DATABASE postgres SET app.encryption_key = 'change-this-to-32-random-chars-minimum';
--    Then RESTART the database (Supabase Dashboard → Settings → Database → Restart)
--
-- 2. Bootstrap admin token (replace YOUR_NEW_PASSWORD):
--      SELECT admin_set_master_token('YOUR_NEW_PASSWORD');
--    From now on, the admin panel logs in with this password (NOT the
--    hardcoded one in admin-auth.js).
--
-- 3. Open admin panel → Settings page → paste:
--      - Razorpay Key ID
--      - Razorpay Key Secret (stored encrypted)
--      - UPI receiving ID
--      - Admin WhatsApp number
--      - Plan prices (or leave defaults)
--
-- 4. Deploy Razorpay webhook Edge Function (see razorpay-webhook/README.md
--    in this package).
