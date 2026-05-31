-- ════════════════════════════════════════════════════════════════════
-- 107_bill_payments_gateway.sql
-- ShopBill Pro v9 — Payments Phase 2 (Razorpay BYO + auto-confirm soundbox)
-- Pro + Business only. Flow B (shop collects from ITS OWN customers).
-- SEPARATE from the existing subscription webhook (Flow A / razorpay-webhook,
-- which forwards to process_razorpay_webhook). Do not mix.
--
-- ENCRYPTION — uses SUPABASE VAULT (same pattern as 047_ai_api_keys_vault),
-- because raw pgcrypto + app.encryption_key is BROKEN on managed Supabase
-- (see 046/047). Each shop's Razorpay key_secret + webhook_secret are stored
-- as Vault secrets named  rzp_secret_<shop_id>  and  rzp_whsec_<shop_id>.
-- key_id is not secret, stored plaintext in the table.
--
-- AUDITED: bills.status flips to 'Paid' on capture (reuses existing flow);
-- bills.grand_total is the amount; shops has owner_id/plan/plan_expires_at.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE EXTENSION IF NOT EXISTS supabase_vault WITH SCHEMA vault CASCADE;

-- ── 1. Per-shop Razorpay creds (key_id plaintext; secrets in Vault) ──
CREATE TABLE IF NOT EXISTS sbp_shop_payment_creds (
  shop_id     uuid PRIMARY KEY REFERENCES shops(id) ON DELETE CASCADE,
  provider    text NOT NULL DEFAULT 'razorpay',
  key_id      text,            -- public-ish (rzp_live_xxx / rzp_test_xxx)
  connected   boolean NOT NULL DEFAULT false,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE sbp_shop_payment_creds ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_creds_owner_select ON sbp_shop_payment_creds;
CREATE POLICY p_creds_owner_select ON sbp_shop_payment_creds
  FOR SELECT TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

-- ── 2. Recorded customer payments (idempotent on rzp_payment_id) ─────
CREATE TABLE IF NOT EXISTS sbp_bill_payments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id        uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  bill_id        uuid,
  rzp_entity_id  text,
  rzp_payment_id text UNIQUE,            -- idempotency key
  amount_paise   bigint NOT NULL DEFAULT 0,
  status         text NOT NULL DEFAULT 'captured',
  raw            jsonb,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_billpay_shop ON sbp_bill_payments (shop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_billpay_bill ON sbp_bill_payments (bill_id);
ALTER TABLE sbp_bill_payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_billpay_owner_select ON sbp_bill_payments;
CREATE POLICY p_billpay_owner_select ON sbp_bill_payments
  FOR SELECT TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

-- ── 3. Web Push subscriptions (app-closed alerts) ───────────────────
CREATE TABLE IF NOT EXISTS sbp_push_subscriptions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id    uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  endpoint   text UNIQUE NOT NULL,
  p256dh     text NOT NULL,
  auth       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_push_shop ON sbp_push_subscriptions (shop_id);
ALTER TABLE sbp_push_subscriptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_push_owner_all ON sbp_push_subscriptions;
CREATE POLICY p_push_owner_all ON sbp_push_subscriptions
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

-- ── 4. Owner saves Razorpay creds (Pro/Business) → Vault ────────────
DROP FUNCTION IF EXISTS sbp_save_payment_creds(uuid, text, text, text);
CREATE OR REPLACE FUNCTION sbp_save_payment_creds(
  p_shop_id uuid, p_key_id text, p_key_secret text, p_webhook_secret text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_sec_name  text := 'rzp_secret_' || p_shop_id::text;
  v_whs_name  text := 'rzp_whsec_'  || p_shop_id::text;
  v_existing  uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = v_uid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF NOT sbp_is_paid_plan(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan_required');
  END IF;
  IF coalesce(p_key_id,'') = '' OR coalesce(p_key_secret,'') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing_keys');
  END IF;

  -- key_secret → Vault
  SELECT id INTO v_existing FROM vault.secrets WHERE name = v_sec_name LIMIT 1;
  IF v_existing IS NULL THEN
    PERFORM vault.create_secret(p_key_secret, v_sec_name, 'Razorpay key_secret per shop');
  ELSE
    PERFORM vault.update_secret(v_existing, p_key_secret);
  END IF;

  -- webhook_secret → Vault (optional)
  IF coalesce(p_webhook_secret,'') <> '' THEN
    v_existing := NULL;
    SELECT id INTO v_existing FROM vault.secrets WHERE name = v_whs_name LIMIT 1;
    IF v_existing IS NULL THEN
      PERFORM vault.create_secret(p_webhook_secret, v_whs_name, 'Razorpay webhook secret per shop');
    ELSE
      PERFORM vault.update_secret(v_existing, p_webhook_secret);
    END IF;
  END IF;

  INSERT INTO sbp_shop_payment_creds (shop_id, key_id, connected, updated_at)
  VALUES (p_shop_id, p_key_id, true, now())
  ON CONFLICT (shop_id) DO UPDATE
    SET key_id = EXCLUDED.key_id, connected = true, updated_at = now();

  RETURN jsonb_build_object('ok', true, 'connected', true);
END;
$$;

-- ── 5. SERVICE-ROLE-ONLY: read decrypted creds for an edge function ─
DROP FUNCTION IF EXISTS sbp_fn_get_creds(uuid);
CREATE OR REPLACE FUNCTION sbp_fn_get_creds(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public
AS $$
DECLARE
  v_key_id text;
  v_secret text;
  v_whsec  text;
  v_conn   boolean;
BEGIN
  SELECT key_id, connected INTO v_key_id, v_conn
    FROM sbp_shop_payment_creds WHERE shop_id = p_shop_id;
  IF v_key_id IS NULL OR NOT coalesce(v_conn,false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_connected');
  END IF;

  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets
   WHERE name = 'rzp_secret_' || p_shop_id::text LIMIT 1;
  SELECT decrypted_secret INTO v_whsec  FROM vault.decrypted_secrets
   WHERE name = 'rzp_whsec_'  || p_shop_id::text LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true, 'key_id', v_key_id,
    'key_secret', v_secret, 'webhook_secret', v_whsec
  );
END;
$$;

-- ── 6. SERVICE-ROLE-ONLY: record payment (idempotent) + mark bill Paid
DROP FUNCTION IF EXISTS sbp_fn_record_payment(uuid, uuid, text, text, bigint, jsonb);
CREATE OR REPLACE FUNCTION sbp_fn_record_payment(
  p_shop_id uuid, p_bill_id uuid, p_rzp_entity_id text,
  p_rzp_payment_id text, p_amount_paise bigint, p_raw jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_existing int;
BEGIN
  SELECT count(*) INTO v_existing FROM sbp_bill_payments
   WHERE rzp_payment_id = p_rzp_payment_id;
  IF v_existing > 0 THEN
    RETURN jsonb_build_object('ok', true, 'already', true);
  END IF;

  INSERT INTO sbp_bill_payments
    (shop_id, bill_id, rzp_entity_id, rzp_payment_id, amount_paise, status, raw)
  VALUES (p_shop_id, p_bill_id, p_rzp_entity_id, p_rzp_payment_id,
          coalesce(p_amount_paise,0), 'captured', p_raw);

  -- reuse existing status flow: mark the bill Paid + set payment_mode
  IF p_bill_id IS NOT NULL THEN
    UPDATE bills
       SET status = 'Paid',
           payment_mode = COALESCE(payment_mode, 'upi')
     WHERE id = p_bill_id
       AND lower(coalesce(status,'')) <> 'voided';
  END IF;

  RETURN jsonb_build_object('ok', true, 'already', false,
                            'amount_paise', coalesce(p_amount_paise,0));
END;
$$;

-- ── 7. Owner: connection status (no secrets) ────────────────────────
DROP FUNCTION IF EXISTS sbp_payment_connection_status(uuid);
CREATE OR REPLACE FUNCTION sbp_payment_connection_status(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_uid uuid := auth.uid(); v_connected boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = v_uid) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  SELECT connected INTO v_connected FROM sbp_shop_payment_creds WHERE shop_id = p_shop_id;
  RETURN jsonb_build_object('ok', true,
    'connected', coalesce(v_connected,false),
    'can_connect', sbp_is_paid_plan(p_shop_id));
END;
$$;

-- ── 8. Grants ────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION sbp_fn_get_creds(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION sbp_fn_record_payment(uuid, uuid, text, text, bigint, jsonb)
                                              FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION sbp_fn_get_creds(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION sbp_fn_record_payment(uuid, uuid, text, text, bigint, jsonb)
                                              TO service_role;
GRANT EXECUTE ON FUNCTION sbp_save_payment_creds(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION sbp_payment_connection_status(uuid)            TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- AFTER DEPLOY (one-time): enable Realtime on the payments table so the
-- open app receives the soundbox event:
--   ALTER PUBLICATION supabase_realtime ADD TABLE sbp_bill_payments;
