-- ════════════════════════════════════════════════════════════════════
-- 030b_invoice_no_columns_fix.sql
-- Batch 022C second hotfix — next_invoice_no return shape (11 May 2026)
--
-- The 030a fix unblocked the column-existence error, but now Finalize
-- fails with `invoice_no_failed`. That's coming from the exception
-- block around the next_invoice_no call:
--
--   BEGIN
--     SELECT * INTO v_inv FROM public.next_invoice_no(p_shop_id);
--     v_invoice_no := v_inv.prefix || '-' || LPAD((v_inv.n)::text, 4, '0');
--   EXCEPTION WHEN OTHERS THEN
--     RETURN jsonb_build_object('ok', false, 'error', 'invoice_no_failed', ...);
--   END;
--
-- billing.html reveals the actual return columns:
--   const newNo = (row.invoice_prefix || 'INV') + '-' +
--                  String(row.invoice_counter).padStart(4, '0');
--
-- So the columns are `invoice_prefix` and `invoice_counter`, not
-- `prefix` and `n` as I assumed.
--
-- This migration:
--   1. Corrects the column references
--   2. Also raises the underlying SQLERRM so future failures are
--      diagnostic (the previous swallowed exception was useful to
--      catch this, but unhelpful for diagnosing further issues).
--
-- Idempotent. Safe to re-run.
-- Prerequisites: 030 + 030a must have been attempted.
-- ════════════════════════════════════════════════════════════════════


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

  SELECT * INTO v_b
    FROM public.sbp_bookings
   WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;

  IF v_b.bill_id IS NOT NULL THEN
    SELECT id, invoice_no, grand_total, paid_amount, balance_due, status
      INTO v_existing_bill
      FROM public.bills
     WHERE id = v_b.bill_id AND shop_id = p_shop_id;
    IF v_existing_bill.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok',            true,
        'already_done',  true,
        'bill_id',       v_existing_bill.id,
        'invoice_no',    v_existing_bill.invoice_no,
        'grand_total',   v_existing_bill.grand_total,
        'paid_amount',   v_existing_bill.paid_amount,
        'balance_due',   v_existing_bill.balance_due,
        'status',        v_existing_bill.status
      );
    END IF;
    UPDATE public.sbp_bookings SET bill_id = NULL WHERE id = p_booking_id;
  END IF;

  SELECT r.id, r.room_number, r.status, rt.name AS type_name
    INTO v_room
    FROM public.sbp_rooms r
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
   WHERE booking_id = p_booking_id
     AND shop_id    = p_shop_id
     AND is_voided  = false;

  v_balance := GREATEST(0, v_grand_total - v_paid);

  v_status := CASE
    WHEN v_balance <= 0.005 THEN 'Paid'
    WHEN v_paid > 0         THEN 'Partial'
    ELSE 'Credit'
  END;

  SELECT INITCAP(payment_mode) INTO v_payment_mode
    FROM public.sbp_folio_payments
   WHERE booking_id = p_booking_id
     AND shop_id    = p_shop_id
     AND is_voided  = false
   ORDER BY recorded_at DESC
   LIMIT 1;
  IF v_payment_mode IS NULL THEN v_payment_mode := 'Cash'; END IF;
  v_payment_mode := CASE LOWER(v_payment_mode)
    WHEN 'upi'           THEN 'UPI'
    WHEN 'bank_transfer' THEN 'Bank'
    WHEN 'ota_prepaid'   THEN 'OTA'
    ELSE INITCAP(v_payment_mode)
  END;

  -- ──────────────────────────────────────────────────────────────
  -- Reserve invoice number
  -- next_invoice_no returns { invoice_prefix, invoice_counter }
  -- (NOT { prefix, n } — confirmed via billing.html usage)
  -- ──────────────────────────────────────────────────────────────
  BEGIN
    SELECT * INTO v_inv FROM public.next_invoice_no(p_shop_id);
    v_invoice_no := COALESCE(v_inv.invoice_prefix, 'INV') || '-' || LPAD((v_inv.invoice_counter)::text, 4, '0');
  EXCEPTION WHEN OTHERS THEN
    -- Re-raise the original error instead of swallowing it — easier
    -- to diagnose future failures.
    RETURN jsonb_build_object(
      'ok',     false,
      'error',  'invoice_no_failed',
      'detail', SQLERRM,
      'state',  SQLSTATE
    );
  END;

  IF v_invoice_no IS NULL OR v_invoice_no = 'INV-' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invoice_no_failed', 'detail', 'RPC returned null/empty');
  END IF;

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
    (v_gst_amount > 0), v_supply_type, 'hotel_checkout',
    NULL,
    'Auto-finalized from folio (Batch 022C)',
    p_booking_id
  )
  RETURNING id INTO v_bill_id;

  IF v_room_subtotal > 0 THEN
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
      v_room_gst_rate,
      0,
      v_room_subtotal,
      v_room_gst_amt,
      'room',
      v_b.room_type_id,
      p_booking_id,
      'night',
      COALESCE(v_b.num_nights, 1) || ' night' || CASE WHEN COALESCE(v_b.num_nights, 1) > 1 THEN 's' ELSE '' END
    );
    v_line_count := v_line_count + 1;
  END IF;

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
        0,
        v_line_total,
        v_line_gst,
        v_kind,
        p_booking_id
      );
      v_line_count := v_line_count + 1;
    END;
  END LOOP;

  IF v_line_count = 0 THEN
    DELETE FROM public.bills WHERE id = v_bill_id;
    RETURN jsonb_build_object('ok', false, 'error', 'no_line_items');
  END IF;

  UPDATE public.sbp_bookings
     SET bill_id        = v_bill_id,
         status         = CASE WHEN status IN ('checked_out','cancelled')
                              THEN status
                              ELSE 'checked_out' END,
         checked_out_at = COALESCE(checked_out_at, now())
   WHERE id      = p_booking_id
     AND shop_id = p_shop_id;

  IF v_b.room_id IS NOT NULL THEN
    UPDATE public.sbp_rooms
       SET status = 'vacant'
     WHERE id      = v_b.room_id
       AND shop_id = p_shop_id
       AND status  = 'occupied';
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

-- ──────────────── End of 030b_invoice_no_columns_fix.sql ─────────
