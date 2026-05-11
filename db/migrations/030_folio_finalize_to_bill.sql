-- ════════════════════════════════════════════════════════════════════
-- 030_folio_finalize_to_bill.sql
-- Batch 022C — Silent Bill Generation (9 May 2026)
--
-- Closes the architectural awkwardness around "Generate Bill":
--
--   Before:  Folio settled → operator clicks "Check Out & Generate Bill"
--            → redirect to billing.html → bill form pre-populated with
--            folio items → operator clicks Preview & Save → bill is saved.
--            Two screens, two confirmations, redundant UI.
--
--   After:   Folio settled → operator clicks "Check Out & Finalize"
--            → server-side: one atomic RPC creates the bill + items,
--            reserves invoice number, marks booking checked_out,
--            frees the room. UI shows invoice number badge, line items
--            lock, "View Invoice" button appears. No redirect.
--
-- The bill record + bill_items rows still get created so Reports / GST
-- Report / customer history / GSTR-1 exports keep working identically.
-- The only thing that changes is the UX path to create them.
--
-- The legacy billing.html?booking_id= path stays functional for edits/
-- corrections (admin affordance), but is no longer the primary route.
--
-- Idempotent. Safe to re-run.
-- Prerequisites: 028 (folio_payments), 029 (unified payment arch),
-- 029a (mode enum fix) must have run.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. RPC: sbp_folio_finalize_to_bill
-- ──────────────────────────────────────────────────────────────────
--
-- Args:
--   p_shop_id     uuid
--   p_booking_id  uuid
--
-- What it does (all in one transaction):
--   1. Validates ownership + booking exists in this shop
--   2. If booking already has bill_id → IDEMPOTENT RETURN of existing bill
--      (operator can re-click safely without creating duplicates)
--   3. Reserves a new invoice_no via next_invoice_no RPC
--   4. Inserts bills row:
--        - line items computed from booking (room nights + GST slab)
--          + sbp_booking_extras (each extra with its own GST rate)
--        - paid_amount = SUM(sbp_folio_payments where !voided)
--        - balance_due, status computed from totals
--        - booking_id, customer linkage preserved
--   5. Inserts bill_items rows (one per line, with kind=room/service/product)
--   6. Updates booking:
--        - status = 'checked_out' (if not already)
--        - checked_out_at = now() (if not already)
--        - bill_id = the new bill's id
--   7. Frees the room: sbp_rooms.status from 'occupied' → 'vacant'
--   8. Returns { ok, bill_id, invoice_no, totals, line_count }
--
-- Errors:
--   - 'not_owner'                 — RLS / ownership fail
--   - 'booking_not_found'
--   - 'no_line_items'             — room missing + no extras (shouldn't happen)
--   - 'invoice_no_failed'         — next_invoice_no didn't return cleanly

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
  -- Ownership
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Fetch booking
  SELECT * INTO v_b
    FROM public.sbp_bookings
   WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;

  -- ──────────────────────────────────────────────────────────────
  -- IDEMPOTENCY: if booking already has a bill_id, return existing
  -- ──────────────────────────────────────────────────────────────
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
    -- bill_id was set but bill doesn't exist → clear it and proceed
    UPDATE public.sbp_bookings SET bill_id = NULL WHERE id = p_booking_id;
  END IF;

  -- Fetch room context
  SELECT r.id, r.room_number, r.status, rt.name AS type_name
    INTO v_room
    FROM public.sbp_rooms r
    LEFT JOIN public.sbp_room_types rt ON rt.id = r.room_type_id
   WHERE r.id = v_b.room_id;

  -- ──────────────────────────────────────────────────────────────
  -- Compute room line + GST slab (post 22 Sep 2025 reform)
  --   ≤ ₹1,000/night → 0%
  --   ≤ ₹7,500/night → 5%
  --   > ₹7,500/night → 18%
  -- ──────────────────────────────────────────────────────────────
  v_room_subtotal := COALESCE(v_b.rate_per_night, 0) * COALESCE(v_b.num_nights, 1);
  IF v_b.rate_per_night IS NULL OR v_b.rate_per_night <= 1000 THEN
    v_room_gst_rate := 0;
  ELSIF v_b.rate_per_night <= 7500 THEN
    v_room_gst_rate := 5;
  ELSE
    v_room_gst_rate := 18;
  END IF;
  v_room_gst_amt := v_room_subtotal * v_room_gst_rate / 100;

  -- Compute extras subtotal + GST (per-line)
  SELECT
    COALESCE(SUM(CASE WHEN COALESCE(e.taxable_amount, e.amount) IS NOT NULL
                     THEN COALESCE(e.taxable_amount, e.amount) ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN COALESCE(e.gst_amount, 0) IS NOT NULL
                     THEN COALESCE(e.gst_amount, 0) ELSE 0 END), 0)
    INTO v_extras_sub, v_extras_gst_amt
    FROM public.sbp_booking_extras e
   WHERE e.booking_id = p_booking_id;

  v_subtotal    := v_room_subtotal + v_extras_sub;
  v_gst_amount  := v_room_gst_amt  + v_extras_gst_amt;
  v_grand_total := v_subtotal + v_gst_amount;

  -- Sum non-voided folio payments
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

  -- Pick the most recent payment mode for the bill's payment_mode field
  -- (legacy column — informational only; the full mode breakdown lives
  -- in sbp_folio_payments)
  SELECT INITCAP(payment_mode) INTO v_payment_mode
    FROM public.sbp_folio_payments
   WHERE booking_id = p_booking_id
     AND shop_id    = p_shop_id
     AND is_voided  = false
   ORDER BY recorded_at DESC
   LIMIT 1;
  IF v_payment_mode IS NULL THEN v_payment_mode := 'Cash'; END IF;
  -- Pretty-print mode for the bills.payment_mode column
  v_payment_mode := CASE LOWER(v_payment_mode)
    WHEN 'upi'           THEN 'UPI'
    WHEN 'bank_transfer' THEN 'Bank'
    WHEN 'ota_prepaid'   THEN 'OTA'
    ELSE INITCAP(v_payment_mode)
  END;

  -- ──────────────────────────────────────────────────────────────
  -- Reserve invoice number
  -- ──────────────────────────────────────────────────────────────
  BEGIN
    SELECT * INTO v_inv FROM public.next_invoice_no(p_shop_id);
    v_invoice_no := COALESCE(v_inv.prefix, 'INV') || '-' || LPAD((v_inv.n)::text, 4, '0');
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invoice_no_failed', 'detail', SQLERRM);
  END;

  IF v_invoice_no IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invoice_no_failed');
  END IF;

  -- ──────────────────────────────────────────────────────────────
  -- Insert bills row
  -- ──────────────────────────────────────────────────────────────
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

  -- ──────────────────────────────────────────────────────────────
  -- Insert bill_items: room line + GST sub-row + each extra
  -- ──────────────────────────────────────────────────────────────

  -- Room line
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

  -- Each extra as its own line
  FOR v_extra IN
    SELECT e.id, e.category, e.description, e.qty, e.unit_price,
           e.amount, e.taxable_amount, e.gst_rate, e.gst_amount, e.unit
      FROM public.sbp_booking_extras e
     WHERE e.booking_id = p_booking_id
     ORDER BY e.added_at
  LOOP
    DECLARE
      v_line_total numeric;
      v_line_gst   numeric;
      v_kind       text;
      v_taxable    numeric;
    BEGIN
      v_taxable    := COALESCE(v_extra.taxable_amount, v_extra.amount, 0);
      v_line_total := v_taxable;
      v_line_gst   := COALESCE(v_extra.gst_amount, 0);
      v_kind       := CASE
        WHEN v_extra.category IN ('service','spa','laundry','transport','telephone') THEN 'service'
        WHEN v_extra.category IN ('food','minibar') THEN 'product'
        ELSE 'product'
      END;

      INSERT INTO public.bill_items (
        bill_id, item_name, qty, rate,
        gst_rate, discount, line_total, gst_amount,
        kind, booking_id, unit
      ) VALUES (
        v_bill_id,
        COALESCE(v_extra.description, 'Extra') ||
          CASE WHEN v_extra.category IS NOT NULL THEN ' (' || v_extra.category || ')' ELSE '' END,
        COALESCE(v_extra.qty, 1),
        CASE WHEN COALESCE(v_extra.qty, 0) > 0
             THEN v_taxable / v_extra.qty
             ELSE COALESCE(v_extra.unit_price, 0)
        END,
        COALESCE(v_extra.gst_rate, 18),
        0,
        v_line_total,
        v_line_gst,
        v_kind,
        p_booking_id,
        v_extra.unit
      );
      v_line_count := v_line_count + 1;
    END;
  END LOOP;

  IF v_line_count = 0 THEN
    -- Rollback the bill insert — empty bills are bugs
    DELETE FROM public.bills WHERE id = v_bill_id;
    RETURN jsonb_build_object('ok', false, 'error', 'no_line_items');
  END IF;

  -- ──────────────────────────────────────────────────────────────
  -- Mark booking checked-out + linked to bill
  -- ──────────────────────────────────────────────────────────────
  UPDATE public.sbp_bookings
     SET bill_id        = v_bill_id,
         status         = CASE WHEN status IN ('checked_out','cancelled')
                              THEN status
                              ELSE 'checked_out' END,
         checked_out_at = COALESCE(checked_out_at, now())
   WHERE id      = p_booking_id
     AND shop_id = p_shop_id;

  -- ──────────────────────────────────────────────────────────────
  -- Free the room (best effort — don't fail finalize on this)
  -- ──────────────────────────────────────────────────────────────
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


-- ──────────────────────────────────────────────────────────────────
-- 2. Verification
-- ──────────────────────────────────────────────────────────────────

-- (1) Finalize the latest in-house booking (or use a specific booking id):
--   SELECT public.sbp_folio_finalize_to_bill(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     (SELECT id FROM public.sbp_bookings WHERE status='checked_in' ORDER BY created_at DESC LIMIT 1)
--   );
--
-- Expected first call: { ok: true, already_done: false, bill_id: '...', invoice_no: 'GG-0079', ... }
-- Expected second call (same booking): { ok: true, already_done: true, bill_id: '...', invoice_no: 'GG-0079', ... }

-- (2) Verify bill + items landed:
--   SELECT b.invoice_no, b.grand_total, b.paid_amount, b.balance_due, b.status,
--          (SELECT COUNT(*) FROM bill_items WHERE bill_id = b.id) AS line_count
--     FROM public.bills b
--    WHERE b.booking_id = '<booking-id>';

-- (3) Verify room freed:
--   SELECT r.room_number, r.status FROM public.sbp_rooms r
--     JOIN public.sbp_bookings b ON b.room_id = r.id WHERE b.id = '<booking-id>';

-- ──────────────── End of 030_folio_finalize_to_bill.sql ──────────
