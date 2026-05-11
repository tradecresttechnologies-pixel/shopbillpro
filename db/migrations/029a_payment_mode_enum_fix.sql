-- ════════════════════════════════════════════════════════════════════
-- 029a_payment_mode_enum_fix.sql
-- Batch 022B hotfix — payment_mode enum mismatch (9 May 2026)
--
-- Migration 029 failed with:
--   ERROR 23514: new row for relation "sbp_folio_payments" violates
--   check constraint "sbp_folio_payments_payment_mode_check"
--   DETAIL: Failing row contains (... ota_prepaid ...)
--
-- Root cause:
--   sbp_bookings.advance_payment_mode CHECK accepts:
--     'cash','upi','card','bank_transfer','ota_prepaid','other'
--   sbp_folio_payments.payment_mode CHECK accepts:
--     'cash','upi','card','bank_transfer','cheque','other'
--   ('ota_prepaid' is in booking schema but not in payments schema;
--    'cheque' is in payments but not in booking schema.)
--
--   The 029 backfill copied 'ota_prepaid' through unchanged → CHECK
--   constraint failure → migration aborted.
--
-- This migration:
--   1. EXPANDS sbp_folio_payments.payment_mode to also accept
--      'ota_prepaid' (semantic preservation — useful for OTA reporting)
--   2. Re-runs the backfill (idempotent — only inserts what was missed)
--   3. Updates the two new RPCs from 029 (settle_with_history)
--      to also accept 'ota_prepaid' in their input validation
--
-- Idempotent. Safe to re-run.
-- Prerequisites: 029 must have at least partially run (RPCs need to
-- exist). If 029 failed entirely, re-running it after this is safe.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. Expand the CHECK constraint
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE public.sbp_folio_payments
  DROP CONSTRAINT IF EXISTS sbp_folio_payments_payment_mode_check;

ALTER TABLE public.sbp_folio_payments
  ADD CONSTRAINT sbp_folio_payments_payment_mode_check
  CHECK (payment_mode IN ('cash','upi','card','bank_transfer','cheque','ota_prepaid','other'));


-- ──────────────────────────────────────────────────────────────────
-- 2. Re-run the backfill (only inserts what was missed last time)
-- ──────────────────────────────────────────────────────────────────

INSERT INTO public.sbp_folio_payments
  (shop_id, booking_id, amount, payment_mode, reference, note, is_advance, recorded_at)
SELECT
  b.shop_id,
  b.id,
  b.advance_amount,
  COALESCE(NULLIF(LOWER(b.advance_payment_mode), ''), 'cash'),
  NULLIF(b.advance_reference, ''),
  'Auto-migrated from booking advance',
  true,
  COALESCE(b.advance_paid_at, b.created_at)
FROM public.sbp_bookings b
WHERE COALESCE(b.advance_amount, 0) > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.sbp_folio_payments p
     WHERE p.booking_id = b.id
       AND p.is_advance = true
       AND p.is_voided  = false
  );


-- ──────────────────────────────────────────────────────────────────
-- 3. Update sbp_bill_settle_with_history to allow 'ota_prepaid'
--    in input validation (also widens the mode mapping logic so
--    any not-quite-matching input is normalized cleanly).
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_bill_settle_with_history(
  p_shop_id    uuid,
  p_bill_id    uuid,
  p_booking_id uuid,
  p_amount     numeric,
  p_mode       text,
  p_reference  text DEFAULT NULL,
  p_note       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check       jsonb;
  v_mode        text;
  v_amount      numeric;
  v_bill_grand  numeric;
  v_total_paid  numeric;
  v_balance     numeric;
  v_status      text;
  v_payment_id  uuid;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_amount := COALESCE(p_amount, 0);
  v_mode   := LOWER(COALESCE(p_mode, 'cash'));
  IF v_amount < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'negative_amount');
  END IF;

  -- Normalize common UI/legacy labels into our enum.
  -- ota_prepaid is now in the enum (after 029a) so it passes through.
  v_mode := CASE v_mode
    WHEN 'upi/qr'  THEN 'upi'
    WHEN 'bank'    THEN 'bank_transfer'
    WHEN 'credit'  THEN 'other'  -- Credit-sale → no payment row, but if forced map to 'other'
    ELSE v_mode
  END;

  -- Final guard
  IF v_mode NOT IN ('cash','upi','card','bank_transfer','cheque','ota_prepaid','other') THEN
    v_mode := 'other';
  END IF;

  SELECT grand_total INTO v_bill_grand
    FROM public.bills
   WHERE id = p_bill_id AND shop_id = p_shop_id;
  IF v_bill_grand IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  IF v_amount > 0 AND p_booking_id IS NOT NULL THEN
    INSERT INTO public.sbp_folio_payments
      (shop_id, booking_id, amount, payment_mode, reference, note, is_advance, recorded_by)
    VALUES (
      p_shop_id, p_booking_id, v_amount, v_mode,
      NULLIF(p_reference, ''),
      COALESCE(NULLIF(p_note,''), 'Bill settlement'),
      false,
      auth.uid()
    )
    RETURNING id INTO v_payment_id;
  END IF;

  v_total_paid := 0;
  IF p_booking_id IS NOT NULL THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_total_paid
      FROM public.sbp_folio_payments
     WHERE booking_id = p_booking_id
       AND shop_id    = p_shop_id
       AND is_voided  = false;
  ELSE
    v_total_paid := v_amount;
  END IF;

  v_balance := GREATEST(0, COALESCE(v_bill_grand, 0) - v_total_paid);

  v_status := CASE
    WHEN LOWER(COALESCE(p_mode,'')) = 'credit' AND v_total_paid = 0 THEN 'Credit'
    WHEN v_balance <= 0.005 THEN 'Paid'
    WHEN v_total_paid > 0   THEN 'Partial'
    ELSE 'Credit'
  END;

  UPDATE public.bills
     SET paid_amount  = v_total_paid,
         balance_due  = v_balance,
         status       = v_status,
         payment_mode = COALESCE(NULLIF(p_mode,''), payment_mode),
         updated_at   = now()
   WHERE id = p_bill_id AND shop_id = p_shop_id;

  IF p_booking_id IS NOT NULL THEN
    UPDATE public.sbp_bookings
       SET bill_id = p_bill_id
     WHERE id = p_booking_id
       AND shop_id = p_shop_id
       AND (bill_id IS NULL OR bill_id <> p_bill_id);
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'payment_id', v_payment_id,
    'bill',       jsonb_build_object(
      'paid_amount', v_total_paid,
      'balance_due', v_balance,
      'status',      v_status
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bill_settle_with_history(uuid, uuid, uuid, numeric, text, text, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 4. Also expand sbp_folio_payment_add (from 028) so manual entry
--    in folio.html can record OTA-prepaid mode too. Same normalization
--    pattern.
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_folio_payment_add(p_shop_id uuid, p_booking_id uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check    jsonb;
  v_amount   numeric;
  v_mode     text;
  v_id       uuid;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_amount := (p_data->>'amount')::numeric;
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'amount_required');
  END IF;

  v_mode := LOWER(COALESCE(p_data->>'payment_mode', 'cash'));
  -- Normalize UI labels
  v_mode := CASE v_mode
    WHEN 'upi/qr' THEN 'upi'
    WHEN 'bank'   THEN 'bank_transfer'
    ELSE v_mode
  END;
  IF v_mode NOT IN ('cash','upi','card','bank_transfer','cheque','ota_prepaid','other') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.sbp_bookings WHERE id = p_booking_id AND shop_id = p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;

  INSERT INTO public.sbp_folio_payments
    (shop_id, booking_id, amount, payment_mode, reference, note, is_advance, recorded_by)
  VALUES (
    p_shop_id, p_booking_id, v_amount, v_mode,
    NULLIF(p_data->>'reference',''),
    NULLIF(p_data->>'note',''),
    COALESCE((p_data->>'is_advance')::boolean, false),
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'payment_id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_payment_add(uuid, uuid, jsonb) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 5. Verification
-- ──────────────────────────────────────────────────────────────────

-- After re-running:
--   SELECT COUNT(*) FROM public.sbp_folio_payments
--    WHERE note = 'Auto-migrated from booking advance';
--   -- Should equal the number of bookings with advance_amount > 0.

--   SELECT payment_mode, COUNT(*)
--     FROM public.sbp_folio_payments
--    WHERE note = 'Auto-migrated from booking advance'
--    GROUP BY 1 ORDER BY 2 DESC;
--   -- Should now show 'ota_prepaid' rows alongside cash/card/upi/etc.

-- ──────────────── End of 029a_payment_mode_enum_fix.sql ─────────
