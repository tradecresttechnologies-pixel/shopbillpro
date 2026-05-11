-- ════════════════════════════════════════════════════════════════════
-- 030c_bills_booking_id_and_final_fix.sql
-- Batch 022C third hotfix — bills.booking_id missing (11 May 2026)
--
-- Your error: column "booking_id" of relation "bills" does not exist
--
-- Root cause:
--   The bills table has no booking_id column. The bookings↔bills link
--   is one-way: sbp_bookings.bill_id points to the bill, but the bill
--   has no reverse reference. This is a genuine schema gap — my 022B
--   billing.html block (the hotel-payment-history hook) also assumes
--   bills.booking_id exists when it tries to find "the bill we just
--   created for booking X":
--
--     const newest = bills.find(b => b && b.id && b.booking_id === _bookingId);
--
--   Without this column that lookup silently falls back to bills[0]
--   (the newest bill, regardless of which booking it belongs to).
--   Fragile. Worth fixing properly.
--
-- This migration:
--   1. Adds booking_id uuid column to bills (nullable, FK with ON DELETE SET NULL)
--   2. Adds an index for the new column
--   3. Replaces sbp_folio_finalize_to_bill one more time with the
--      corrected INSERT (bill_mode='manual' for safety; the booking
--      linkage now lives in the new column properly)
--
-- Idempotent. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. Add the missing column + index
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE public.bills
  ADD COLUMN IF NOT EXISTS booking_id uuid REFERENCES public.sbp_bookings(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bills_booking_id ON public.bills(booking_id) WHERE booking_id IS NOT NULL;

COMMENT ON COLUMN public.bills.booking_id IS 'Optional FK to sbp_bookings for hotel checkout bills. Allows reverse lookup "find the bill for booking X" without scanning sbp_bookings.';


-- ──────────────────────────────────────────────────────────────────
-- 2. Replace sbp_folio_finalize_to_bill with the corrected version
--
-- Changes from 030b:
--   - bill_mode = 'manual'   (was 'hotel_checkout' — defensive; sticking
--                             to known-good values until we confirm any
--                             CHECK constraint on this column)
--   - notes now spell out the source so a "hotel_checkout" tag is still
--     searchable via notes LIKE '%Auto-finalized%' if needed
--   - booking_id column reference is now valid (added above)
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_folio_finalize_to_bill(
  p_shop_id    uuid,
  p_booking_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check          jsonb;
  v_b              record;
  v_room           record;
  v_inv            record;
  v_invoice_no     text;
  v_bill_id        uuid;
  v_room_subtotal  numeric := 0;
  v_room_gst_rate  numeric := 0;
  v_room_gst_amt   numeric := 0;
  v_extras_sub     numeric := 0;
  v_extras_gst_amt numeric := 0;
  v_subtotal       numeric := 0;
  v_gst_amount     numeric := 0;
  v_grand_total    numeric := 0;
  v_paid           numeric := 0;
  v_balance        numeric := 0;
  v_status         text;
  v_line_count     int     := 0;
  v_extra          record;
  v_today          date    := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_existing_bill  record;
  v_payment_mode   text    := 'Cash';
  v_supply_type    text    := 'intra';
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM public.sbp_bookings
   WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;

  -- Idempotency: existing bill linkage returns existing bill
  IF v_b.bill_id IS NOT NULL THEN
    SELECT id, invoice_no, grand_total, paid_amount, balance_due, status
      INTO v_existing_bill FROM public.bills
     WHERE id = v_b.bill_id AND shop_id = p_shop_id;
    IF v_existing_bill.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok',           true,
        'already_done', true,
        'bill_id',      v_existing_bill.id,
        'invoice_no',   v_existing_bill.invoice_no,
        'grand_total',  v_existing_bill.grand_total,
        'paid_amount',  v_existing_bill.paid_amount,
        'balance_due',  v_existing_bill.balance_due,
        'status',       v_existing_bill.status
      );
    END IF;
    UPDATE public.sbp_bookings SET bill_id = NULL WHERE id = p_booking_id;
  END IF;

  SELECT r.id, r.room_number, r.status, rt.name AS type_name
    INTO v_room FROM public.sbp_rooms r
    LEFT JOIN public.sbp_room_types rt ON rt.id = r.room_type_id
   WHERE r.id = v_b.room_id;

  v_room_subtotal := COALESCE(v_b.rate_per_night, 0) * COALESCE(v_b.num_nights, 1);
  IF v_b.rate_per_night IS NULL OR v_b.rate_per_night <= 1000 THEN
    v_room_gst_rate := 0;
  ELSIF v_b.rate_per_night <= 7500 THEN
    v_room_gst_rate := 5;
  ELSE
    v_room_gst_rate := 18;
  END IF;
  v_room_gst_amt := v_room_subtotal * v_room_gst_rate / 100;

  SELECT
    COALESCE(SUM(COALESCE(e.taxable_amount, e.amount, 0)), 0),
    COALESCE(SUM(
      CASE
        WHEN COALESCE(e.cgst_amount, 0) + COALESCE(e.sgst_amount, 0) > 0
          THEN COALESCE(e.cgst_amount, 0) + COALESCE(e.sgst_amount, 0)
        WHEN COALESCE(e.gst_rate, 0) > 0
          THEN COALESCE(e.taxable_amount, e.amount, 0) * COALESCE(e.gst_rate, 0) / 100
        ELSE COALESCE(e.taxable_amount, e.amount, 0) *
             CASE
               WHEN LOWER(e.category) IN ('food','transport') THEN 5
               WHEN LOWER(e.category) IN ('laundry','minibar','service','telephone','spa','other') THEN 18
               ELSE 18
             END / 100
      END
    ), 0)
    INTO v_extras_sub, v_extras_gst_amt
    FROM public.sbp_booking_extras e
   WHERE e.booking_id = p_booking_id;

  v_subtotal    := v_room_subtotal + v_extras_sub;
  v_gst_amount  := v_room_gst_amt  + v_extras_gst_amt;
  v_grand_total := v_subtotal + v_gst_amount;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.sbp_folio_payments
   WHERE booking_id = p_booking_id AND shop_id = p_shop_id AND is_voided = false;

  v_balance := GREATEST(0, v_grand_total - v_paid);
  v_status := CASE
    WHEN v_balance <= 0.005 THEN 'Paid'
    WHEN v_paid > 0         THEN 'Partial'
    ELSE 'Credit'
  END;

  SELECT INITCAP(payment_mode) INTO v_payment_mode
    FROM public.sbp_folio_payments
   WHERE booking_id = p_booking_id AND shop_id = p_shop_id AND is_voided = false
   ORDER BY recorded_at DESC LIMIT 1;
  IF v_payment_mode IS NULL THEN v_payment_mode := 'Cash'; END IF;
  v_payment_mode := CASE LOWER(v_payment_mode)
    WHEN 'upi'           THEN 'UPI'
    WHEN 'bank_transfer' THEN 'Bank'
    WHEN 'ota_prepaid'   THEN 'OTA'
    ELSE INITCAP(v_payment_mode)
  END;

  -- Reserve invoice number
  BEGIN
    SELECT * INTO v_inv FROM public.next_invoice_no(p_shop_id);
    v_invoice_no := COALESCE(v_inv.invoice_prefix, 'INV') || '-' || LPAD((v_inv.invoice_counter)::text, 4, '0');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invoice_no_failed', 'detail', SQLERRM, 'state', SQLSTATE);
  END;

  IF v_invoice_no IS NULL OR v_invoice_no = 'INV-' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invoice_no_failed', 'detail', 'RPC returned null/empty');
  END IF;

  -- ────────────────────────────────────────────────────────────────
  -- Insert bills row
  -- bill_mode='manual' is the safe default. The 'Auto-finalized from
  -- folio (Batch 022C)' string in notes is the audit trail; the new
  -- booking_id column is the actual data link.
  -- ────────────────────────────────────────────────────────────────
  BEGIN
    INSERT INTO public.bills (
      shop_id, invoice_no, invoice_date, due_date,
      customer_name, customer_wa, customer_gstin,
      payment_mode, status,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      is_gst_invoice, supply_type, bill_mode,
      place_of_supply, notes,
      booking_id
    ) VALUES (
      p_shop_id, v_invoice_no, v_today, NULL,
      v_b.customer_name,
      COALESCE(v_b.customer_wa, v_b.customer_phone),
      NULL,
      v_payment_mode, v_status,
      v_subtotal, v_gst_amount, 0, v_grand_total,
      v_paid, v_balance,
      (v_gst_amount > 0), v_supply_type, 'manual',
      NULL,
      'Auto-finalized from folio (Batch 022C) · booking ' || p_booking_id::text,
      p_booking_id
    )
    RETURNING id INTO v_bill_id;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bills_insert_failed', 'detail', SQLERRM, 'state', SQLSTATE);
  END;

  -- Room line
  IF v_room_subtotal > 0 THEN
    BEGIN
      INSERT INTO public.bill_items (
        bill_id, item_name, qty, rate,
        gst_rate, discount, line_total, gst_amount,
        kind, room_type_id, booking_id, unit, qty_unit_label
      ) VALUES (
        v_bill_id,
        'Room ' || COALESCE(v_room.room_number, 'TBD') ||
          CASE WHEN v_room.type_name IS NOT NULL THEN ' · ' || v_room.type_name ELSE '' END ||
          ' (' || COALESCE(v_b.check_in_date::text, '') || ' → ' || COALESCE(v_b.check_out_date::text, '') || ')',
        COALESCE(v_b.num_nights, 1),
        COALESCE(v_b.rate_per_night, 0),
        v_room_gst_rate, 0,
        v_room_subtotal, v_room_gst_amt,
        'room', v_b.room_type_id, p_booking_id,
        'night',
        COALESCE(v_b.num_nights, 1) || ' night' || CASE WHEN COALESCE(v_b.num_nights, 1) > 1 THEN 's' ELSE '' END
      );
      v_line_count := v_line_count + 1;
    EXCEPTION WHEN OTHERS THEN
      DELETE FROM public.bills WHERE id = v_bill_id;
      RETURN jsonb_build_object('ok', false, 'error', 'bill_items_room_insert_failed', 'detail', SQLERRM, 'state', SQLSTATE);
    END;
  END IF;

  -- Each extra
  FOR v_extra IN
    SELECT e.id, e.category, e.description, e.qty, e.unit_price,
           e.amount, e.taxable_amount, e.gst_rate,
           e.cgst_amount, e.sgst_amount
      FROM public.sbp_booking_extras e
     WHERE e.booking_id = p_booking_id
     ORDER BY e.added_at
  LOOP
    DECLARE
      v_taxable     numeric;
      v_line_total  numeric;
      v_line_gst    numeric;
      v_line_rate   numeric;
      v_kind        text;
      v_eff_gst_pct numeric;
    BEGIN
      v_taxable    := COALESCE(v_extra.taxable_amount, v_extra.amount, 0);
      v_line_total := v_taxable;

      v_line_gst := COALESCE(v_extra.cgst_amount, 0) + COALESCE(v_extra.sgst_amount, 0);
      IF v_line_gst = 0 AND COALESCE(v_extra.gst_rate, 0) > 0 THEN
        v_line_gst := v_taxable * v_extra.gst_rate / 100;
      ELSIF v_line_gst = 0 THEN
        v_eff_gst_pct := CASE
          WHEN LOWER(v_extra.category) IN ('food','transport') THEN 5
          WHEN LOWER(v_extra.category) IN ('laundry','minibar','service','telephone','spa','other') THEN 18
          ELSE 18
        END;
        v_line_gst := v_taxable * v_eff_gst_pct / 100;
      END IF;

      v_line_rate := CASE WHEN COALESCE(v_extra.qty, 0) > 0
                         THEN v_taxable / v_extra.qty
                         ELSE COALESCE(v_extra.unit_price, 0)
                    END;

      v_kind := CASE
        WHEN v_extra.category IN ('service','spa','laundry','transport','telephone') THEN 'service'
        WHEN v_extra.category IN ('food','minibar') THEN 'product'
        ELSE 'product'
      END;

      INSERT INTO public.bill_items (
        bill_id, item_name, qty, rate,
        gst_rate, discount, line_total, gst_amount,
        kind, booking_id
      ) VALUES (
        v_bill_id,
        COALESCE(v_extra.description, 'Extra') ||
          CASE WHEN v_extra.category IS NOT NULL THEN ' (' || v_extra.category || ')' ELSE '' END,
        COALESCE(v_extra.qty, 1),
        v_line_rate,
        COALESCE(v_extra.gst_rate, 18),
        0, v_line_total, v_line_gst,
        v_kind, p_booking_id
      );
      v_line_count := v_line_count + 1;
    EXCEPTION WHEN OTHERS THEN
      DELETE FROM public.bill_items WHERE bill_id = v_bill_id;
      DELETE FROM public.bills WHERE id = v_bill_id;
      RETURN jsonb_build_object('ok', false, 'error', 'bill_items_extra_insert_failed', 'detail', SQLERRM, 'state', SQLSTATE, 'extra_id', v_extra.id);
    END;
  END LOOP;

  IF v_line_count = 0 THEN
    DELETE FROM public.bills WHERE id = v_bill_id;
    RETURN jsonb_build_object('ok', false, 'error', 'no_line_items');
  END IF;

  -- Mark booking checked-out + linked
  UPDATE public.sbp_bookings
     SET bill_id        = v_bill_id,
         status         = CASE WHEN status IN ('checked_out','cancelled')
                              THEN status ELSE 'checked_out' END,
         checked_out_at = COALESCE(checked_out_at, now())
   WHERE id = p_booking_id AND shop_id = p_shop_id;

  -- Free the room
  IF v_b.room_id IS NOT NULL THEN
    UPDATE public.sbp_rooms SET status = 'vacant'
     WHERE id = v_b.room_id AND shop_id = p_shop_id AND status = 'occupied';
  END IF;

  RETURN jsonb_build_object(
    'ok',           true,
    'already_done', false,
    'bill_id',      v_bill_id,
    'invoice_no',   v_invoice_no,
    'grand_total',  v_grand_total,
    'paid_amount',  v_paid,
    'balance_due',  v_balance,
    'status',       v_status,
    'line_count',   v_line_count,
    'room_freed',   (v_b.room_id IS NOT NULL)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_finalize_to_bill(uuid, uuid) TO authenticated;


-- ──────────────── End of 030c_bills_booking_id_and_final_fix.sql ─
