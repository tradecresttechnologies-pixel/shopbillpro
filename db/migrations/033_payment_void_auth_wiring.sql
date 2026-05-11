-- ════════════════════════════════════════════════════════════════════
-- Migration 033 — Wire PIN authorization + audit log into
--                 sbp_folio_payment_void
-- Batch 022D-B Stage 2
--
-- Existing signature being replaced:
--   sbp_folio_payment_void(p_shop_id uuid, p_payment_id uuid,
--                          p_reason text)
--
-- New signature:
--   sbp_folio_payment_void(p_shop_id uuid, p_payment_id uuid,
--                          p_reason text DEFAULT NULL,
--                          p_auth_pin text DEFAULT NULL)
--
-- Backward-compatible: existing 3-arg callers continue to work
-- unchanged. p_auth_pin defaults to NULL → no PIN check when
-- shops.require_auth_for_high_risk = false.
--
-- Existing behavior preserved:
--   • sbp_check_hospitality_owner ownership
--   • Atomic UPDATE...WHERE is_voided=false (race-safe)
--   • voided_reason = NULLIF(p_reason, '')
--   • is_voided/voided_at columns (not voided_by_user_id — that lives
--     in the audit log now)
--
-- New behavior:
--   • Returns more specific errors: 'payment_not_found' vs
--     'already_voided' (was: 'payment_not_found_or_already_voided').
--     Existing callers checking ok=false still work.
--   • Captures before/after state for audit log.
--   • Writes one audit entry with action_code='payment.void'.
--
-- Note: booking total recomputation is NOT added here. Existing
-- function doesn't do it; preserving exact existing behavior. If
-- live_balance_due reporting has a bug related to voided payments,
-- that's a separate fix in a future migration.
-- ════════════════════════════════════════════════════════════════════

-- Drop all prior signatures (old + any half-deployed variants)
DROP FUNCTION IF EXISTS public.sbp_folio_payment_void(uuid, uuid);
DROP FUNCTION IF EXISTS public.sbp_folio_payment_void(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.sbp_folio_payment_void(uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION public.sbp_folio_payment_void(
  p_shop_id    uuid,
  p_payment_id uuid,
  p_reason     text DEFAULT NULL,
  p_auth_pin   text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check  jsonb;
  v_auth   jsonb;
  v_before jsonb;
  v_after  jsonb;
  v_count  int;
BEGIN
  -- 1. Ownership (preserved — same helper as before)
  v_check := public.sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- 2. Fetch existing payment
  SELECT to_jsonb(p.*) INTO v_before
    FROM public.sbp_folio_payments p
   WHERE p.id = p_payment_id AND p.shop_id = p_shop_id;

  IF v_before IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_found');
  END IF;

  -- Idempotency: already voided?
  IF COALESCE((v_before->>'is_voided')::boolean, false) = true THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'already_voided',
      'voided_at', v_before->>'voided_at'
    );
  END IF;

  -- 3. PIN gate
  v_auth := public._sbp_verify_auth_for_high_risk(p_shop_id, p_auth_pin);
  IF NOT (v_auth->>'ok')::boolean THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', v_auth->>'error',
      'action_code', 'payment.void'
    );
  END IF;

  -- 4. Atomic void (preserved race-safe pattern)
  UPDATE public.sbp_folio_payments
     SET is_voided     = true,
         voided_at     = now(),
         voided_reason = NULLIF(p_reason, '')
   WHERE id = p_payment_id
     AND shop_id = p_shop_id
     AND is_voided = false;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- 5. Handle race condition: another caller may have voided between
  --    our step-2 SELECT and step-4 UPDATE.
  IF v_count = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_voided');
  END IF;

  -- 6. Capture AFTER
  SELECT to_jsonb(p.*) INTO v_after
    FROM public.sbp_folio_payments p
   WHERE p.id = p_payment_id;

  -- 7. Audit log
  PERFORM public.sbp_audit_log_write(
    p_shop_id,
    'payment.void',
    'sbp_folio_payments',
    p_payment_id,
    v_before,
    v_after,
    p_reason,
    (v_auth->>'authorized_id')::uuid,
    v_auth->>'authorized_name',
    v_auth->>'method',
    public._sbp_actor_name()
  );

  -- 8. Return — keeps the historical 'voided' count field for any
  --    callers that may have depended on it.
  RETURN jsonb_build_object('ok', true, 'voided', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_payment_void(uuid, uuid, text, text)
  TO authenticated;

-- ══════════════════════════════════════════════════════════════════
-- Done. With this, all 4 high-risk operations are PIN-gated:
--   booking.cancel, extras.remove, bill.void, payment.void
-- ══════════════════════════════════════════════════════════════════
