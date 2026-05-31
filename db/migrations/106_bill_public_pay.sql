-- ════════════════════════════════════════════════════════════════════
-- 106_bill_public_pay.sql
-- ShopBill Pro v9 — Payments Phase 1 (NO gateway)
-- Public bill link + PDF view + UPI-intent pay. ALL tiers (Free = watermark).
--
-- AUDITED AGAINST LIVE REPO (shopbillpro17):
--   * bills total column        = grand_total           (NOT total)
--   * bills invoice column       = invoice_no
--   * bills date column          = invoice_date          (NOT created_at)
--   * bills denormalized name     = customer_name
--   * bills existing status        = status ('Paid'/'Partial'/'Pending'/'voided')
--   * bills existing payment field = payment_mode
--   * shop UPI field              = shops.upi             (NOT upi_vpa)
--   * bill_items fields            = item_name, qty, rate, line_total, gst_amount, bill_id
--   * shops has owner_id, plan, plan_expires_at
--   * slug lives in sbp_shop_websites (from migration 008), not on shops
--
-- DESIGN: we DO NOT invent a parallel paid flag. We add only a public
-- share token + read RPC. "Paid" continues to use the existing
-- bills.status='Paid' set by the app's Settle flow. Phase 2 (gateway)
-- will flip that same status, so reports/COGS stay consistent.
--
-- SQL RULES: DROP FUNCTION before CREATE OR REPLACE; {ok,error} envelope;
-- owner check (except public read); defensive accessors; bill_items always
-- selected; NOTIFY pgrst at end.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- for gen_random_bytes (token)

-- ── 1. Share token on bills (additive, safe) ─────────────────────────
ALTER TABLE bills ADD COLUMN IF NOT EXISTS pay_token text;
CREATE INDEX IF NOT EXISTS idx_bills_pay_token ON bills (pay_token);

-- ── 2. Paid-plan helper (mirrors JS isPro: enterprise->business) ─────
DROP FUNCTION IF EXISTS sbp_is_paid_plan(uuid);
CREATE OR REPLACE FUNCTION sbp_is_paid_plan(p_shop_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM shops s
    WHERE s.id = p_shop_id
      AND lower(coalesce(s.plan,'free')) IN ('pro','business','enterprise')
      AND (s.plan_expires_at IS NULL OR s.plan_expires_at > now())
  );
$$;

-- ── 3. Owner: get/create the share token for a bill ──────────────────
DROP FUNCTION IF EXISTS sbp_get_bill_pay_token(uuid);
CREATE OR REPLACE FUNCTION sbp_get_bill_pay_token(p_bill_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_rec   bills%ROWTYPE;
  v_owner uuid;
  v_token text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_rec FROM bills WHERE id = p_bill_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  SELECT owner_id INTO v_owner FROM shops
   WHERE id = (to_jsonb(v_rec)->>'shop_id')::uuid;
  IF v_owner IS DISTINCT FROM v_uid THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  v_token := (to_jsonb(v_rec)->>'pay_token');
  IF v_token IS NULL OR length(v_token) < 16 THEN
    v_token := encode(gen_random_bytes(16), 'hex');
    UPDATE bills SET pay_token = v_token WHERE id = p_bill_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'bill_id', p_bill_id,
    'token', v_token,
    'invoice_no', (to_jsonb(v_rec)->>'invoice_no')
  );
END;
$$;

-- ── 4. PUBLIC bill read (no auth, token-gated) ───────────────────────
DROP FUNCTION IF EXISTS sbp_get_bill_public(uuid, text);
CREATE OR REPLACE FUNCTION sbp_get_bill_public(p_bill_id uuid, p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_rec    bills%ROWTYPE;
  v_shopid uuid;
  v_items  jsonb;
  v_shop   jsonb;
  v_status text;
  v_paid   boolean;
BEGIN
  IF p_token IS NULL OR length(p_token) < 16 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT * INTO v_rec FROM bills WHERE id = p_bill_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  IF (to_jsonb(v_rec)->>'pay_token') IS DISTINCT FROM p_token THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  v_shopid := (to_jsonb(v_rec)->>'shop_id')::uuid;
  v_status := coalesce(to_jsonb(v_rec)->>'status','Pending');
  v_paid   := lower(v_status) = 'paid';

  SELECT COALESCE(jsonb_agg(to_jsonb(bi) ORDER BY bi.id), '[]'::jsonb)
    INTO v_items FROM bill_items bi WHERE bi.bill_id = p_bill_id;

  SELECT jsonb_build_object(
           'name', s.name,
           'upi',  s.upi,
           'is_paid_plan', sbp_is_paid_plan(s.id)
         )
    INTO v_shop FROM shops s WHERE s.id = v_shopid;

  RETURN jsonb_build_object(
    'ok', true,
    'bill', jsonb_build_object(
      'id',          p_bill_id,
      'invoice_no',  (to_jsonb(v_rec)->>'invoice_no'),
      'invoice_date',(to_jsonb(v_rec)->>'invoice_date'),
      'customer_name',(to_jsonb(v_rec)->>'customer_name'),
      'grand_total', coalesce((to_jsonb(v_rec)->>'grand_total')::numeric, 0),
      'status',      v_status,
      'paid',        v_paid
    ),
    'items', v_items,
    'shop',  v_shop,
    'watermark', NOT (v_shop->>'is_paid_plan')::boolean
  );
END;
$$;

-- ── 5. Grants ────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION sbp_get_bill_public(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION sbp_get_bill_pay_token(uuid)     TO authenticated;
GRANT EXECUTE ON FUNCTION sbp_is_paid_plan(uuid)           TO anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
