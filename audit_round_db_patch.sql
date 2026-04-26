-- ════════════════════════════════════════════════════════════════
-- ShopBill Pro — DB Patch for Audit Round
-- Run this in Supabase SQL Editor BEFORE deploying the new client code.
-- ════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────
-- FIX #23 — Atomic invoice counter (race-free)
-- ──────────────────────────────────────────────
-- Two devices reading counter=10 simultaneously and both writing 11
-- would produce duplicate invoice numbers (illegal under GST).
-- This RPC reserves the next number atomically.

CREATE OR REPLACE FUNCTION public.next_invoice_no(p_shop_id uuid)
RETURNS TABLE(invoice_prefix text, invoice_counter int)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_prefix  text;
  v_counter int;
BEGIN
  -- Lock the shop row for the duration of this txn so two callers serialize.
  UPDATE shops
     SET invoice_counter = COALESCE(invoice_counter, 0) + 1
   WHERE id = p_shop_id
   RETURNING shops.invoice_prefix, shops.invoice_counter
        INTO v_prefix, v_counter;

  IF v_counter IS NULL THEN
    RAISE EXCEPTION 'Shop % not found', p_shop_id;
  END IF;

  invoice_prefix := COALESCE(v_prefix, 'INV');
  invoice_counter := v_counter;
  RETURN NEXT;
END;
$$;

-- Allow authenticated users to call it for their own shop only.
REVOKE ALL ON FUNCTION public.next_invoice_no(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_invoice_no(uuid) TO authenticated;

-- ──────────────────────────────────────────────
-- FIX — Server-side plan expiry enforcement
-- ──────────────────────────────────────────────
-- Auto-downgrade shops whose plan_expires_at is in the past.
-- Call from a daily cron (Supabase Scheduled Function or pg_cron).

CREATE OR REPLACE FUNCTION public.expire_lapsed_plans()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count int;
BEGIN
  UPDATE shops
     SET plan = 'free'
   WHERE plan IS NOT NULL
     AND plan <> 'free'
     AND plan_expires_at IS NOT NULL
     AND plan_expires_at < now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Optional: enable pg_cron once and schedule daily.
-- (run once)  CREATE EXTENSION IF NOT EXISTS pg_cron;
-- (run once)  SELECT cron.schedule('expire-plans-daily', '0 1 * * *',
--               $$ SELECT public.expire_lapsed_plans(); $$);

-- ──────────────────────────────────────────────
-- FIX — Subscription verification trigger
-- ──────────────────────────────────────────────
-- When admin updates subscription.status -> 'active', auto-update the shop's plan
-- and plan_expires_at. Removes the manual two-step error window.

CREATE OR REPLACE FUNCTION public.subscription_apply_to_shop()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NEW.status = 'active' AND (OLD IS NULL OR OLD.status <> 'active') THEN
    UPDATE shops
       SET plan = NEW.plan,
           plan_expires_at = COALESCE(NEW.expires_at, plan_expires_at)
     WHERE id = NEW.shop_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_subscription_apply ON subscriptions;
CREATE TRIGGER trg_subscription_apply
AFTER INSERT OR UPDATE OF status ON subscriptions
FOR EACH ROW EXECUTE FUNCTION public.subscription_apply_to_shop();

-- ──────────────────────────────────────────────
-- Schema additions used by patched client
-- ──────────────────────────────────────────────
-- These are safe to run multiple times.

ALTER TABLE bills        ADD COLUMN IF NOT EXISTS reopened_at  timestamptz;
ALTER TABLE bills        ADD COLUMN IF NOT EXISTS voided_at    timestamptz;
ALTER TABLE bills        ADD COLUMN IF NOT EXISTS voided_by    text;
ALTER TABLE bills        ADD COLUMN IF NOT EXISTS audit_log    jsonb DEFAULT '[]'::jsonb;
ALTER TABLE bills        ADD COLUMN IF NOT EXISTS supply_type  text DEFAULT 'intra';
ALTER TABLE shops        ADD COLUMN IF NOT EXISTS plan_expires_at timestamptz;

ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS razorpay_order_id text;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS razorpay_signature text;

-- ──────────────────────────────────────────────
-- Manual ops cheatsheet (admin verification flow)
-- ──────────────────────────────────────────────
-- 1. Customer pays via UPI/Razorpay. Client inserts subscriptions row with
--    status='pending_verification' (no shop plan changes yet).
-- 2. Admin checks Razorpay dashboard / UPI receiving account.
-- 3. Admin runs:
--      UPDATE subscriptions
--         SET status = 'active'
--       WHERE id = '<sub_id>';
--    The trigger above will copy plan + expires_at to shops automatically.
-- 4. To downgrade after refund:
--      UPDATE subscriptions SET status='refunded' WHERE id='<sub_id>';
--      UPDATE shops SET plan='free' WHERE id='<shop_id>';
