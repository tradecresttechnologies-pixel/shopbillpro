-- ════════════════════════════════════════════════════════════════════
-- Migration 032 — Wire PIN authorization + audit log into high-risk RPCs
-- Batch 022D-B Stage 1
--
-- Builds on the foundation from migration 031:
--   • sbp_authorized_users table + bcrypt pin verification
--   • sbp_audit_log table + sbp_audit_log_write helper
--   • shops.require_auth_for_high_risk boolean (default false)
--
-- This migration:
--   • Adds two private helpers (_sbp_verify_auth_for_high_risk,
--     _sbp_actor_name) used by all high-risk RPCs.
--   • Extends sbp_bookings_cancel (adds p_auth_pin + audit logging).
--   • Extends sbp_booking_extras_remove (adds p_auth_pin + audit logging).
--   • Creates new sbp_bill_void RPC.
--
-- IMPORTANT — Backward compatibility:
--   All three RPCs accept p_auth_pin AS DEFAULT NULL. With the shop's
--   require_auth_for_high_risk = false (default), existing call sites
--   that DON'T pass p_auth_pin continue to work exactly as before.
--   Audit log entries are still written, with auth_method='none'.
--
-- Deferred to Stage B-2:
--   sbp_folio_payment_void  — need live signature from production
--   (was deployed in migration 028/029 which isn't in the local repo).
-- ════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- Helper 1: Verify whether the current call passes high-risk auth
-- Returns:
--   { ok:true,  method:'none', authorized_id:null, authorized_name:null }
--     when shop's require_auth_for_high_risk is false (no PIN needed)
--   { ok:true,  method:'pin',  authorized_id:<uuid>, authorized_name:<text> }
--     when PIN provided and matched
--   { ok:false, error:'requires_authorization' }
--     when require_auth is true but no/short PIN
--   { ok:false, error:'invalid_pin' }
--     when PIN provided but didn't match any active authorized user
-- ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sbp_verify_auth_for_high_risk(
  p_shop_id  uuid,
  p_auth_pin text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_require_auth boolean;
  v_u            record;
BEGIN
  SELECT COALESCE(require_auth_for_high_risk, false)
    INTO v_require_auth
    FROM public.shops
   WHERE id = p_shop_id;

  -- Shop doesn't require auth → pass through
  IF NOT v_require_auth THEN
    RETURN jsonb_build_object(
      'ok', true, 'method', 'none',
      'authorized_id', NULL, 'authorized_name', NULL
    );
  END IF;

  -- Auth required but no usable PIN
  IF p_auth_pin IS NULL OR length(p_auth_pin) < 4 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'requires_authorization');
  END IF;

  -- Verify PIN against authorized users (bcrypt via pgcrypto)
  SELECT id, user_name
    INTO v_u
    FROM public.sbp_authorized_users
   WHERE shop_id = p_shop_id
     AND active = true
     AND crypt(p_auth_pin, pin_hash) = pin_hash
   LIMIT 1;

  IF v_u.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_pin');
  END IF;

  -- Update last_used_at
  UPDATE public.sbp_authorized_users
     SET last_used_at = now()
   WHERE id = v_u.id;

  RETURN jsonb_build_object(
    'ok', true, 'method', 'pin',
    'authorized_id', v_u.id, 'authorized_name', v_u.user_name
  );
END;
$$;

-- Don't expose this helper to client-side callers; it's only called
-- by other SECURITY DEFINER functions in this file.
REVOKE EXECUTE ON FUNCTION public._sbp_verify_auth_for_high_risk(uuid, text) FROM PUBLIC, authenticated;


-- ──────────────────────────────────────────────────────────────────
-- Helper 2: Resolve the human-readable name of the auth.uid() caller
-- Order of preference: raw_user_meta_data.name → .full_name → email
-- ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sbp_actor_name()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(
           raw_user_meta_data->>'name',
           raw_user_meta_data->>'full_name',
           email,
           'unknown'
         )
    FROM auth.users
   WHERE id = auth.uid()
   LIMIT 1;
$$;

REVOKE EXECUTE ON FUNCTION public._sbp_actor_name() FROM PUBLIC, authenticated;


-- ══════════════════════════════════════════════════════════════════
-- RPC 1: sbp_bookings_cancel  (extended)
-- New params at end: p_auth_pin
-- Existing params (p_shop_id, p_booking_id, p_reason) unchanged.
-- Adds: PIN gate + audit log capture (before/after) of booking row.
-- ══════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.sbp_bookings_cancel(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.sbp_bookings_cancel(uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION public.sbp_bookings_cancel(
  p_shop_id    uuid,
  p_booking_id uuid,
  p_reason     text DEFAULT NULL,
  p_auth_pin   text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check  jsonb;
  v_auth   jsonb;
  v_b      public.sbp_bookings%ROWTYPE;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  -- 1. Ownership
  v_check := public.sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- 2. Fetch booking & validate state
  SELECT * INTO v_b FROM public.sbp_bookings
   WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;
  IF v_b.status IN ('checked_out','cancelled') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'cannot_cancel_in_status',
      'current_status', v_b.status
    );
  END IF;

  -- 3. PIN gate
  v_auth := public._sbp_verify_auth_for_high_risk(p_shop_id, p_auth_pin);
  IF NOT (v_auth->>'ok')::boolean THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', v_auth->>'error',
      'action_code', 'booking.cancel'
    );
  END IF;

  -- 4. Capture BEFORE
  v_before := to_jsonb(v_b);

  -- 5. Perform cancel (preserves the existing behavior exactly)
  UPDATE public.sbp_bookings SET
    status           = 'cancelled',
    cancelled_at     = now(),
    cancelled_reason = p_reason,
    updated_at       = now()
   WHERE id = p_booking_id;

  IF v_b.status = 'checked_in' AND v_b.room_id IS NOT NULL THEN
    UPDATE public.sbp_rooms
       SET status = 'available', updated_at = now()
     WHERE id = v_b.room_id;
  END IF;

  -- 6. Capture AFTER
  SELECT to_jsonb(t) INTO v_after FROM public.sbp_bookings t
   WHERE id = p_booking_id;

  -- 7. Audit log
  PERFORM public.sbp_audit_log_write(
    p_shop_id,
    'booking.cancel',
    'sbp_bookings',
    p_booking_id,
    v_before,
    v_after,
    p_reason,
    (v_auth->>'authorized_id')::uuid,
    v_auth->>'authorized_name',
    v_auth->>'method',
    public._sbp_actor_name()
  );

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bookings_cancel(uuid, uuid, text, text)
  TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- RPC 2: sbp_booking_extras_remove  (extended)
-- ══════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.sbp_booking_extras_remove(uuid, uuid);
DROP FUNCTION IF EXISTS public.sbp_booking_extras_remove(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.sbp_booking_extras_remove(uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION public.sbp_booking_extras_remove(
  p_shop_id  uuid,
  p_extra_id uuid,
  p_reason   text DEFAULT NULL,
  p_auth_pin text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check  jsonb;
  v_auth   jsonb;
  v_b_id   uuid;
  v_before jsonb;
BEGIN
  -- 1. Ownership
  v_check := public.sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- 2. Fetch extra & validate existence
  SELECT to_jsonb(t.*), t.booking_id
    INTO v_before, v_b_id
    FROM public.sbp_booking_extras t
   WHERE t.id = p_extra_id AND t.shop_id = p_shop_id;
  IF v_b_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found');
  END IF;

  -- 3. PIN gate
  v_auth := public._sbp_verify_auth_for_high_risk(p_shop_id, p_auth_pin);
  IF NOT (v_auth->>'ok')::boolean THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', v_auth->>'error',
      'action_code', 'extras.remove'
    );
  END IF;

  -- 4. Delete & recompute totals (preserves existing behavior)
  DELETE FROM public.sbp_booking_extras
   WHERE id = p_extra_id AND shop_id = p_shop_id;

  UPDATE public.sbp_bookings SET
    extras_total = (SELECT COALESCE(SUM(amount),0)
                      FROM public.sbp_booking_extras WHERE booking_id = v_b_id),
    grand_total  = room_total
                   + (SELECT COALESCE(SUM(amount),0)
                        FROM public.sbp_booking_extras WHERE booking_id = v_b_id)
                   + tax_amount - discount_amount,
    updated_at   = now()
   WHERE id = v_b_id;

  -- 5. Audit log (after = NULL since row is deleted)
  PERFORM public.sbp_audit_log_write(
    p_shop_id,
    'extras.remove',
    'sbp_booking_extras',
    p_extra_id,
    v_before,
    NULL,
    p_reason,
    (v_auth->>'authorized_id')::uuid,
    v_auth->>'authorized_name',
    v_auth->>'method',
    public._sbp_actor_name()
  );

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_booking_extras_remove(uuid, uuid, text, text)
  TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- RPC 3: sbp_bill_void  (NEW)
-- Marks a bill as voided. Uses bills.voided_at + bills.status='voided'
-- pattern already used by all reports/customer-history.
-- Stock restoration and ledger reversal remain client-side for now
-- (handled by bills.html._doVoidBill) — those can move to RPCs later.
-- ══════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.sbp_bill_void(uuid, uuid);
DROP FUNCTION IF EXISTS public.sbp_bill_void(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.sbp_bill_void(uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION public.sbp_bill_void(
  p_shop_id  uuid,
  p_bill_id  uuid,
  p_reason   text DEFAULT NULL,
  p_auth_pin text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check  jsonb;
  v_auth   jsonb;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  -- 1. Ownership  (bills are not hospitality-specific, use shop_owner)
  v_check := public.sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- 2. Fetch bill & validate
  SELECT to_jsonb(b.*) INTO v_before
    FROM public.bills b
   WHERE b.id = p_bill_id AND b.shop_id = p_shop_id;
  IF v_before IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  -- Already-voided guard (idempotent)
  IF (v_before->>'voided_at') IS NOT NULL
     OR COALESCE(v_before->>'status','') = 'voided' THEN
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
      'action_code', 'bill.void'
    );
  END IF;

  -- 4. Void the bill
  UPDATE public.bills SET
    voided_at = now(),
    status    = 'voided',
    updated_at = now()
   WHERE id = p_bill_id AND shop_id = p_shop_id;

  -- 5. Capture AFTER
  SELECT to_jsonb(b.*) INTO v_after
    FROM public.bills b
   WHERE b.id = p_bill_id;

  -- 6. Audit log
  PERFORM public.sbp_audit_log_write(
    p_shop_id,
    'bill.void',
    'bills',
    p_bill_id,
    v_before,
    v_after,
    p_reason,
    (v_auth->>'authorized_id')::uuid,
    v_auth->>'authorized_name',
    v_auth->>'method',
    public._sbp_actor_name()
  );

  RETURN jsonb_build_object('ok', true, 'voided_at', v_after->>'voided_at');
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bill_void(uuid, uuid, text, text)
  TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- Done. Three high-risk RPCs now PIN-gated when
-- shops.require_auth_for_high_risk = true.
-- Default (false) preserves all existing behavior.
-- ══════════════════════════════════════════════════════════════════
