-- ════════════════════════════════════════════════════════════════════
-- 029_unified_payment_architecture.sql
-- Batch 022B — Unified Payment Architecture (9 May 2026)
--
-- Problem this fixes:
--   Two parallel payment systems lived side-by-side:
--     (a) bookings.advance_amount + advance_payment_mode (single value)
--     (b) sbp_folio_payments ledger (multi-row, mode-tagged) — added in 028
--
--   When checkout fired and a bill was generated, the bill flow only
--   knew about (a). Any mid-stay payments recorded via folio.html were
--   silently lost from the bill's "paid" tally. Mode splits across
--   advance + balance were never preserved.
--
-- This migration:
--   1. Backfills sbp_folio_payments from legacy bookings.advance_amount
--      (idempotent — only inserts if no advance row exists yet)
--   2. Adds sbp_folio_payment_summary(booking_id) RPC — single round-trip
--      view of all payments for a booking, grouped by mode
--   3. Adds sbp_bill_settle_with_history RPC — atomically records the
--      final balance payment to the ledger AND updates the bill totals
--      in one transaction (no orphan states possible)
--
-- Idempotent. Safe to re-run.
-- Prerequisites: 028_folio_management.sql must have run.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. Backfill legacy advance_amount → sbp_folio_payments
-- ──────────────────────────────────────────────────────────────────
--
-- For every booking with advance_amount > 0 that does NOT already
-- have an `is_advance=true` row in sbp_folio_payments, insert one.
-- The folio.html UI already shows the legacy advance as a synthetic
-- row when no real row exists, but persisting the real row lets the
-- bill settlement flow read everything from one place.

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
-- 2. RPC: sbp_folio_payment_summary(booking_id)
-- ──────────────────────────────────────────────────────────────────
--
-- Returns:
-- {
--   ok: true,
--   total_paid: numeric,
--   by_mode: [{ mode, amount, count }],   -- aggregated per mode
--   rows:    [ ... full payment rows ... ] -- detail for audit display
-- }
--
-- Used by billing.html when ?booking_id=X is in the URL to render
-- the "Payment history" panel above the Settlement section.

CREATE OR REPLACE FUNCTION public.sbp_folio_payment_summary(
  p_shop_id    uuid,
  p_booking_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check    jsonb;
  v_total    numeric := 0;
  v_by_mode  jsonb;
  v_rows     jsonb;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Total (non-voided only)
  SELECT COALESCE(SUM(amount), 0) INTO v_total
    FROM public.sbp_folio_payments
   WHERE booking_id = p_booking_id
     AND shop_id    = p_shop_id
     AND is_voided  = false;

  -- Per-mode aggregation
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'mode',   sub.payment_mode,
      'amount', sub.total,
      'count',  sub.cnt
    ) ORDER BY sub.total DESC), '[]'::jsonb)
    INTO v_by_mode
    FROM (
      SELECT payment_mode, SUM(amount) AS total, COUNT(*) AS cnt
        FROM public.sbp_folio_payments
       WHERE booking_id = p_booking_id
         AND shop_id    = p_shop_id
         AND is_voided  = false
       GROUP BY payment_mode
    ) sub;

  -- Full row detail (newest first)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',           p.id,
      'amount',       p.amount,
      'payment_mode', p.payment_mode,
      'reference',    p.reference,
      'note',         p.note,
      'is_advance',   p.is_advance,
      'is_voided',    p.is_voided,
      'recorded_at',  p.recorded_at
    ) ORDER BY p.recorded_at DESC), '[]'::jsonb)
    INTO v_rows
    FROM public.sbp_folio_payments p
   WHERE p.booking_id = p_booking_id
     AND p.shop_id    = p_shop_id;

  RETURN jsonb_build_object(
    'ok',         true,
    'total_paid', v_total,
    'by_mode',    v_by_mode,
    'rows',       v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_payment_summary(uuid, uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 3. RPC: sbp_bill_settle_with_history
-- ──────────────────────────────────────────────────────────────────
--
-- Atomically:
--   1. Records the final balance payment to sbp_folio_payments
--      (with is_advance=false, since this is the closing payment)
--   2. Updates the bill row: paid_amount, balance_due, status,
--      payment_mode (recorded as the LAST mode used)
--   3. Updates the booking's bill_id link if not set
--
-- Args:
--   p_shop_id      uuid
--   p_bill_id      uuid          — the bill record to settle
--   p_booking_id   uuid          — source booking (for ledger link)
--   p_amount       numeric       — amount being paid NOW (0 if Credit)
--   p_mode         text          — payment mode of the balance
--   p_reference    text nullable
--   p_note         text nullable
--
-- Returns:
--   { ok: true, payment_id, bill: { paid_amount, balance_due, status } }
--
-- If p_amount = 0 (Credit), no folio payment row is inserted, but the
-- bill is still marked with the appropriate status.

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
  -- Ownership check
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_amount := COALESCE(p_amount, 0);
  v_mode   := LOWER(COALESCE(p_mode, 'cash'));
  IF v_amount < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'negative_amount');
  END IF;

  -- Verify bill belongs to this shop, get its grand total
  SELECT grand_total INTO v_bill_grand
    FROM public.bills
   WHERE id = p_bill_id AND shop_id = p_shop_id;
  IF v_bill_grand IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  -- Insert the closing payment if amount > 0 (Credit means 0 collected now)
  IF v_amount > 0 THEN
    IF v_mode NOT IN ('cash','upi','card','bank_transfer','cheque','other') THEN
      -- Map common UI labels into our enum
      v_mode := CASE LOWER(v_mode)
        WHEN 'upi/qr'  THEN 'upi'
        WHEN 'bank'    THEN 'bank_transfer'
        WHEN 'credit'  THEN 'other'  -- shouldn't happen (Credit = no payment) but safe
        ELSE 'other'
      END;
    END IF;

    IF p_booking_id IS NOT NULL THEN
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
  END IF;

  -- Compute total paid across ALL non-voided payments for this booking
  v_total_paid := 0;
  IF p_booking_id IS NOT NULL THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_total_paid
      FROM public.sbp_folio_payments
     WHERE booking_id = p_booking_id
       AND shop_id    = p_shop_id
       AND is_voided  = false;
  ELSE
    v_total_paid := v_amount;  -- no booking link, just record what's paid now
  END IF;

  v_balance := GREATEST(0, COALESCE(v_bill_grand, 0) - v_total_paid);

  -- Bill status: Paid (balance 0) / Partial (some paid) / Credit (zero paid)
  v_status := CASE
    WHEN LOWER(COALESCE(p_mode,'')) = 'credit' AND v_total_paid = 0 THEN 'Credit'
    WHEN v_balance <= 0.005 THEN 'Paid'
    WHEN v_total_paid > 0   THEN 'Partial'
    ELSE 'Credit'
  END;

  -- Update bill totals + last-used mode
  UPDATE public.bills
     SET paid_amount  = v_total_paid,
         balance_due  = v_balance,
         status       = v_status,
         payment_mode = COALESCE(NULLIF(p_mode,''), payment_mode),
         updated_at   = now()
   WHERE id = p_bill_id AND shop_id = p_shop_id;

  -- Ensure booking ↔ bill link is set (idempotent)
  IF p_booking_id IS NOT NULL THEN
    UPDATE public.sbp_bookings
       SET bill_id = p_bill_id
     WHERE id = p_booking_id
       AND shop_id = p_shop_id
       AND (bill_id IS NULL OR bill_id <> p_bill_id);
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'payment_id',  v_payment_id,
    'bill',        jsonb_build_object(
      'paid_amount', v_total_paid,
      'balance_due', v_balance,
      'status',      v_status
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bill_settle_with_history(uuid, uuid, uuid, numeric, text, text, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 4. Verification
-- ──────────────────────────────────────────────────────────────────

-- (1) Check backfill ran:
--   SELECT COUNT(*) FROM sbp_folio_payments WHERE note = 'Auto-migrated from booking advance';

-- (2) Summary for a recent booking:
--   SELECT public.sbp_folio_payment_summary(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     (SELECT id FROM public.sbp_bookings ORDER BY created_at DESC LIMIT 1)
--   );

-- (3) Test settle (replace with real bill_id / booking_id):
--   SELECT public.sbp_bill_settle_with_history(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     '<bill-id>'::uuid,
--     '<booking-id>'::uuid,
--     1215,
--     'card',
--     'TXN-12345',
--     'Final settlement'
--   );

-- ──────────────── End of 029_unified_payment_architecture.sql ────
