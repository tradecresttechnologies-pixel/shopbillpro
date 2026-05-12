-- ════════════════════════════════════════════════════════════════════
-- Migration 039 — sbp_bill_void (Batch 022D-E)
--
-- Closes the last client-side PIN gate in bills.html. `voidBill` is a
-- SOFT-DELETE (status='Voided', voided_at=now()) that:
--   • Restores stock for non-voided product items
--   • Reverses customer ledger if credit was outstanding
--   • Keeps the bill row in the database (for audit trail)
--
-- Pattern matches the 5 RPCs added in migration 038:
--   • Owner check via _sbp_check_shop_owner
--   • Server-side PIN re-verify via sbp_verify_pin
--   • Audit log via sbp_audit_log_write
--   • jsonb {ok, error?, ...} envelope
--
-- Reuses helpers from 038:
--   • _sbp_bill_restore_stock(p_bill_id) — best-effort stock restore
-- ════════════════════════════════════════════════════════════════════


--
-- DEPLOY NOTE (Vinay's environment): a `sbp_bill_void(uuid, uuid, text, text)`
-- already exists in production with a different parameter name than the one
-- here. Postgres `CREATE OR REPLACE FUNCTION` cannot rename parameters — it
-- requires DROP first. This drop is idempotent (no-op if absent).
-- If anything else in the codebase was calling that earlier function with the
-- OLD parameter names, those callers must update to use the new names below.
-- ════════════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.sbp_bill_void(uuid, uuid, text, text);


CREATE OR REPLACE FUNCTION public.sbp_bill_void(
  p_shop_id   uuid,
  p_bill_id   uuid,
  p_auth_pin  text,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_pin           jsonb;
  v_user_id       uuid;
  v_user_name     text;
  v_bill          bills%ROWTYPE;
  v_old_status    text;
  v_old_grand     numeric;
  v_old_balance   numeric;
  v_was_credit    boolean;
  v_before        jsonb;
  v_after         jsonb;
BEGIN
  -- Ownership
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Server-side PIN verify
  v_pin := public.sbp_verify_pin(p_shop_id, p_auth_pin);
  IF NOT COALESCE((v_pin->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_invalid');
  END IF;
  v_user_id   := NULLIF(v_pin->>'user_id', '')::uuid;
  v_user_name := v_pin->>'user_name';

  -- Lock + load bill
  SELECT * INTO v_bill FROM bills
   WHERE id = p_bill_id AND shop_id = p_shop_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  -- Guard: already voided?
  IF COALESCE(v_bill.status, '') IN ('Voided', 'voided', 'Cancelled', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_voided');
  END IF;

  v_old_status  := v_bill.status;
  v_old_grand   := COALESCE(v_bill.grand_total, 0);
  v_old_balance := COALESCE(v_bill.balance_due, 0);
  v_was_credit  := COALESCE(v_old_status, '') IN ('Credit', 'Partial', 'Pending')
                   AND v_old_balance > 0;

  v_before := to_jsonb(v_bill);

  -- Restore stock for non-voided product items (best-effort)
  PERFORM public._sbp_bill_restore_stock(p_bill_id);

  -- Reverse customer ledger if credit was outstanding
  IF v_was_credit AND v_bill.customer_id IS NOT NULL THEN
    BEGIN
      UPDATE customers
         SET balance = GREATEST(0, COALESCE(balance, 0) - v_old_balance)
       WHERE id = v_bill.customer_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Ledger reversal skipped: %', SQLERRM;
    END;
  END IF;

  -- Soft-void: set status + voided_at + voided_by; zero out balance_due
  UPDATE bills SET
    status      = 'Voided',
    voided_at   = now(),
    voided_by   = COALESCE(v_user_name, 'Manager'),
    balance_due = 0
  WHERE id = p_bill_id;

  SELECT * INTO v_bill FROM bills WHERE id = p_bill_id;
  v_after := to_jsonb(v_bill);

  -- Audit log
  PERFORM public.sbp_audit_log_write(
    p_shop_id              => p_shop_id,
    p_action_code          => 'bill.void',
    p_target_table         => 'bills',
    p_target_id            => p_bill_id,
    p_before_json          => v_before,
    p_after_json           => v_after,
    p_reason               => p_reason,
    p_authorized_by_user_id=> v_user_id,
    p_authorized_by_name   => v_user_name,
    p_auth_method          => 'pin',
    p_actor_name           => v_user_name
  );

  RETURN jsonb_build_object(
    'ok',              true,
    'bill_id',         p_bill_id,
    'invoice_no',      v_bill.invoice_no,
    'old_status',      v_old_status,
    'new_status',      v_bill.status,
    'credit_reversed', v_was_credit,
    'verified_by',     v_user_name
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_bill_void(uuid, uuid, text, text) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- End of migration 039
-- ════════════════════════════════════════════════════════════════════
