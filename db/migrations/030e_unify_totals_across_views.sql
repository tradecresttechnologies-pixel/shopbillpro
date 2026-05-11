-- ════════════════════════════════════════════════════════════════════
-- 030e_unify_totals_across_views.sql
-- Batch 022C fifth hotfix — bill/folio/picker show one consistent total
-- (11 May 2026)
--
-- Your complaint (verbatim):
--   "same bill, same folio, same guest with same stay but too much
--    contradiction .. all each pages showing different different
--    outstanding. while guest had pay full in two term"
--
-- Three places, three different numbers — root cause is the data
-- model inconsistency in how operator-entered amounts are interpreted.
--
-- Concrete example from your screenshots:
--   Operator types "Lunch (per person) ₹250"
--     → folio displays ₹250 (treats as gross/total)
--     → trigger stores with gst_inclusive=FALSE (treats as pre-GST)
--     → e.amount = ₹250, e.taxable_amount = ₹250, e.gst_amount = ₹12.50
--   At finalize, my old SQL read taxable_amount and added GST on top
--   → bill shows line as ₹262.50 → bill total drifts above folio total
--
--   Folio total:        ₹1,649
--   Bill total (old):   ₹1,667   ← ₹18 phantom higher
--   Picker balance:     ₹100     ← ignored extras + later payments entirely
--
-- This migration:
--   1. Replaces sbp_folio_finalize_to_bill — back-computes taxable
--      from e.amount-as-gross, so bill.grand_total === folio.grand_total.
--      Also backfills legacy booking.advance_amount into folio_payments
--      at finalize time so paid_amount is complete.
--
--   2. Replaces sbp_bookings_list — adds three live totals via
--      LEFT JOIN to bills + correlated SUM from folio_payments:
--        - live_grand_total
--        - live_paid_amount
--        - live_balance_due
--      The picker uses these directly. No more stale booking columns.
--
-- Idempotent. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- PART 1: Finalize RPC — bill total = folio total
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
  v_extras_taxable numeric := 0;
  v_extras_gst     numeric := 0;
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
  v_room_freed     boolean := false;
  v_legacy_id      uuid;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM public.sbp_bookings
   WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;

  -- Idempotent: existing linked bill returns same response
  IF v_b.bill_id IS NOT NULL THEN
    SELECT id, invoice_no, grand_total, paid_amount, balance_due, status
      INTO v_existing_bill FROM public.bills
     WHERE id = v_b.bill_id AND shop_id = p_shop_id;
    IF v_existing_bill.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', true, 'already_done', true,
        'bill_id',     v_existing_bill.id,
        'invoice_no',  v_existing_bill.invoice_no,
        'grand_total', v_existing_bill.grand_total,
        'paid_amount', v_existing_bill.paid_amount,
        'balance_due', v_existing_bill.balance_due,
        'status',      v_existing_bill.status
      );
    END IF;
    UPDATE public.sbp_bookings SET bill_id = NULL WHERE id = p_booking_id;
  END IF;

  SELECT r.id, r.room_number, r.status, rt.name AS type_name
    INTO v_room FROM public.sbp_rooms r
    LEFT JOIN public.sbp_room_types rt ON rt.id = r.room_type_id
   WHERE r.id = v_b.room_id;

  -- Room subtotal + GST (slab based on rate per night)
  v_room_subtotal := COALESCE(v_b.rate_per_night, 0) * COALESCE(v_b.num_nights, 1);
  IF v_b.rate_per_night IS NULL OR v_b.rate_per_night <= 1000 THEN
    v_room_gst_rate := 0;
  ELSIF v_b.rate_per_night <= 7500 THEN
    v_room_gst_rate := 5;
  ELSE
    v_room_gst_rate := 18;
  END IF;
  v_room_gst_amt := ROUND((v_room_subtotal * v_room_gst_rate / 100)::numeric, 2);

  -- ────────────────────────────────────────────────────────────────
  -- Extras: treat e.amount as canonical GROSS (= what folio shows =
  -- what guest pays). Back-compute taxable + GST so bill totals
  -- match folio totals exactly.
  --
  -- For each extra:
  --   eff_rate    = e.gst_rate (if > 0) else category default
  --   gross       = e.amount
  --   taxable     = gross / (1 + eff_rate/100)
  --   gst         = gross - taxable
  -- ────────────────────────────────────────────────────────────────
  SELECT
    COALESCE(SUM(
      CASE
        WHEN COALESCE(NULLIF(e.gst_rate, 0),
             CASE WHEN LOWER(e.category) IN ('food','transport') THEN 5
                  WHEN LOWER(e.category) IN ('laundry','minibar','service','telephone','spa','other') THEN 18
                  ELSE 0 END) > 0
          THEN e.amount / (1 + COALESCE(NULLIF(e.gst_rate, 0),
               CASE WHEN LOWER(e.category) IN ('food','transport') THEN 5
                    WHEN LOWER(e.category) IN ('laundry','minibar','service','telephone','spa','other') THEN 18
                    ELSE 0 END) / 100.0)
        ELSE e.amount
      END
    ), 0),
    COALESCE(SUM(
      CASE
        WHEN COALESCE(NULLIF(e.gst_rate, 0),
             CASE WHEN LOWER(e.category) IN ('food','transport') THEN 5
                  WHEN LOWER(e.category) IN ('laundry','minibar','service','telephone','spa','other') THEN 18
                  ELSE 0 END) > 0
          THEN e.amount - (e.amount / (1 + COALESCE(NULLIF(e.gst_rate, 0),
               CASE WHEN LOWER(e.category) IN ('food','transport') THEN 5
                    WHEN LOWER(e.category) IN ('laundry','minibar','service','telephone','spa','other') THEN 18
                    ELSE 0 END) / 100.0))
        ELSE 0
      END
    ), 0)
    INTO v_extras_taxable, v_extras_gst
    FROM public.sbp_booking_extras e
   WHERE e.booking_id = p_booking_id;

  v_extras_taxable := ROUND(v_extras_taxable::numeric, 2);
  v_extras_gst     := ROUND(v_extras_gst::numeric, 2);

  v_subtotal    := v_room_subtotal + v_extras_taxable;
  v_gst_amount  := v_room_gst_amt  + v_extras_gst;
  v_grand_total := v_subtotal + v_gst_amount;

  -- ────────────────────────────────────────────────────────────────
  -- Backfill legacy advance into folio_payments if not present
  -- (Some bookings have advance_amount > 0 but no folio_payments row
  -- because the original 029 backfill missed them or they were created
  -- after.)  After this, paid_amount sum is complete and consistent.
  -- ────────────────────────────────────────────────────────────────
  IF COALESCE(v_b.advance_amount, 0) > 0 AND NOT EXISTS (
       SELECT 1 FROM public.sbp_folio_payments
        WHERE booking_id = p_booking_id AND shop_id = p_shop_id
          AND is_advance = true AND is_voided = false
     )
  THEN
    BEGIN
      INSERT INTO public.sbp_folio_payments
        (shop_id, booking_id, amount, payment_mode, reference, note, is_advance, recorded_at)
      VALUES (
        p_shop_id, p_booking_id, v_b.advance_amount,
        COALESCE(NULLIF(LOWER(v_b.advance_payment_mode), ''), 'cash'),
        NULLIF(v_b.advance_reference, ''),
        'Auto-migrated from booking advance (at finalize)',
        true,
        COALESCE(v_b.advance_paid_at, v_b.created_at)
      )
      RETURNING id INTO v_legacy_id;
    EXCEPTION WHEN OTHERS THEN
      -- Non-fatal: if backfill fails, paid_amount calc below still
      -- handles legacy advance correctly. But surface in response.
      v_legacy_id := NULL;
    END;
  END IF;

  -- Sum all non-voided payments (now includes the legacy advance if backfilled)
  SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM public.sbp_folio_payments
   WHERE booking_id = p_booking_id AND shop_id = p_shop_id AND is_voided = false;

  -- Safety net: if backfill failed but legacy advance exists, add it manually
  IF v_legacy_id IS NULL AND COALESCE(v_b.advance_amount, 0) > 0
     AND NOT EXISTS (SELECT 1 FROM public.sbp_folio_payments
                      WHERE booking_id = p_booking_id AND is_advance = true AND is_voided = false)
  THEN
    v_paid := v_paid + v_b.advance_amount;
  END IF;

  v_balance := GREATEST(0, ROUND((v_grand_total - v_paid)::numeric, 2));
  v_status := CASE
    WHEN v_balance <= 0.005 THEN 'Paid'
    WHEN v_paid > 0         THEN 'Partial'
    ELSE 'Credit'
  END;

  -- Pick most-recent payment mode for bill's display
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

  -- Insert bills row — totals match folio exactly
  BEGIN
    INSERT INTO public.bills (
      shop_id, invoice_no, invoice_date, due_date,
      customer_name, customer_wa, customer_gstin,
      payment_mode, status,
      subtotal, gst_amount, discount, grand_total,
      paid_amount, balance_due,
      is_gst_invoice, supply_type, bill_mode,
      place_of_supply, notes, booking_id
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

  -- Room line item
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

  -- Each extra: back-compute taxable + GST from gross
  FOR v_extra IN
    SELECT e.id, e.category, e.description, e.qty, e.unit_price,
           e.amount, e.gst_rate
      FROM public.sbp_booking_extras e
     WHERE e.booking_id = p_booking_id
     ORDER BY e.added_at
  LOOP
    DECLARE
      v_gross       numeric;
      v_eff_rate    numeric;
      v_l_taxable   numeric;
      v_l_gst       numeric;
      v_l_rate      numeric;
      v_kind        text;
    BEGIN
      v_gross := COALESCE(v_extra.amount, 0);

      -- Effective GST rate: row's gst_rate if set, else category default
      v_eff_rate := COALESCE(NULLIF(v_extra.gst_rate, 0),
        CASE
          WHEN LOWER(v_extra.category) IN ('food','transport') THEN 5
          WHEN LOWER(v_extra.category) IN ('laundry','minibar','service','telephone','spa','other') THEN 18
          ELSE 0
        END
      );

      -- Back-compute taxable + GST from gross (treats e.amount as inclusive)
      IF v_eff_rate > 0 THEN
        v_l_taxable := ROUND((v_gross / (1 + v_eff_rate / 100.0))::numeric, 2);
        v_l_gst     := ROUND((v_gross - v_l_taxable)::numeric, 2);
      ELSE
        v_l_taxable := v_gross;
        v_l_gst     := 0;
      END IF;

      v_l_rate := CASE WHEN COALESCE(v_extra.qty, 0) > 0
                       THEN ROUND((v_l_taxable / v_extra.qty)::numeric, 2)
                       ELSE v_l_taxable
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
        v_l_rate,
        v_eff_rate,
        0, v_l_taxable, v_l_gst,
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

  -- Mark booking checked-out + linked to bill
  UPDATE public.sbp_bookings
     SET bill_id        = v_bill_id,
         status         = CASE WHEN status IN ('checked_out','cancelled')
                              THEN status ELSE 'checked_out' END,
         checked_out_at = COALESCE(checked_out_at, now())
   WHERE id = p_booking_id AND shop_id = p_shop_id;

  -- Free room (cleaning state — verified against existing checkout RPC)
  IF v_b.room_id IS NOT NULL THEN
    BEGIN
      UPDATE public.sbp_rooms
         SET status = 'cleaning', updated_at = now()
       WHERE id = v_b.room_id AND shop_id = p_shop_id AND status = 'occupied';
      v_room_freed := true;
    EXCEPTION WHEN OTHERS THEN
      v_room_freed := false;
    END;
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
    'room_freed',   v_room_freed,
    'legacy_backfilled', (v_legacy_id IS NOT NULL)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_finalize_to_bill(uuid, uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- PART 2: sbp_bookings_list — add live totals for picker
-- ──────────────────────────────────────────────────────────────────
--
-- Adds three new fields per row:
--   live_grand_total — bill.grand_total if billed, else recomputed
--   live_paid_amount — bill.paid_amount if billed, else SUM(folio_payments)
--                       + (legacy advance if no folio_payments row)
--   live_balance_due — live_grand_total - live_paid_amount
--
-- These three numbers will ALWAYS match what folio_get_full returns
-- and what the bill stores (post 030e), so the picker, the folio,
-- and the bill never disagree again.

CREATE OR REPLACE FUNCTION public.sbp_bookings_list(
  p_shop_id        uuid,
  p_filter         text DEFAULT 'all',
  p_status_filter  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_rows  jsonb;
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  WITH filtered AS (
    SELECT b.*
      FROM sbp_bookings b
     WHERE b.shop_id = p_shop_id
       AND (
         p_filter = 'all' OR
         (p_filter = 'today'    AND (b.check_in_date = v_today OR b.check_out_date = v_today OR b.status = 'checked_in')) OR
         (p_filter = 'upcoming' AND b.check_in_date >= v_today AND b.status IN ('pending','confirmed')) OR
         (p_filter = 'past'     AND (b.check_out_date < v_today OR b.status IN ('checked_out','cancelled','no_show'))) OR
         (p_filter = 'in_house' AND b.status = 'checked_in') OR
         (p_filter = 'checked_out' AND b.status = 'checked_out') OR
         (p_filter = 'cancelled' AND b.status = 'cancelled')
       )
       AND (p_status_filter IS NULL OR p_status_filter = 'all' OR b.status = p_status_filter)
  ),
  -- Per-booking live computations
  live AS (
    SELECT
      f.id AS booking_id,
      -- Live grand total: bill.grand_total if billed, else recomputed
      CASE
        WHEN f.bill_id IS NOT NULL THEN COALESCE(bl.grand_total, 0)
        ELSE
          -- Room subtotal + GST slab
          (COALESCE(f.rate_per_night, 0) * COALESCE(f.num_nights, 1))
          + (COALESCE(f.rate_per_night, 0) * COALESCE(f.num_nights, 1)) *
            (CASE
              WHEN COALESCE(f.rate_per_night, 0) <= 1000 THEN 0
              WHEN f.rate_per_night <= 7500 THEN 5
              ELSE 18
             END) / 100.0
          -- Plus sum of extras as gross
          + COALESCE((SELECT SUM(e.amount) FROM sbp_booking_extras e WHERE e.booking_id = f.id), 0)
      END AS live_grand_total,
      -- Live paid: bill.paid_amount if billed, else SUM(folio_payments) + legacy
      CASE
        WHEN f.bill_id IS NOT NULL THEN COALESCE(bl.paid_amount, 0)
        ELSE
          COALESCE((SELECT SUM(amount) FROM sbp_folio_payments p
                     WHERE p.booking_id = f.id AND p.is_voided = false), 0)
          + (CASE
              WHEN NOT EXISTS (SELECT 1 FROM sbp_folio_payments p
                                WHERE p.booking_id = f.id AND p.is_advance = true AND p.is_voided = false)
                AND COALESCE(f.advance_amount, 0) > 0
              THEN COALESCE(f.advance_amount, 0)
              ELSE 0
             END)
      END AS live_paid_amount,
      -- Live balance: bill.balance_due if billed
      CASE
        WHEN f.bill_id IS NOT NULL THEN COALESCE(bl.balance_due, 0)
        ELSE NULL  -- computed below
      END AS live_balance_due_billed
    FROM filtered f
    LEFT JOIN bills bl ON bl.id = f.bill_id AND bl.shop_id = p_shop_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                 f.id,
    'customer_name',      f.customer_name,
    'customer_phone',     f.customer_phone,
    'customer_wa',        f.customer_wa,
    'customer_id',        f.customer_id,
    'num_adults',         f.num_adults,
    'num_children',       f.num_children,
    'room_id',            f.room_id,
    'room_number',        COALESCE(f.room_number_snapshot, (SELECT room_number FROM sbp_rooms WHERE id = f.room_id)),
    'room_type_id',       f.room_type_id,
    'room_type_name',     COALESCE(f.room_type_snapshot, (SELECT name FROM sbp_room_types WHERE id = f.room_type_id)),
    'check_in_date',      f.check_in_date,
    'check_out_date',     f.check_out_date,
    'num_nights',         f.num_nights,
    'rate_per_night',     f.rate_per_night,
    'room_total',         f.room_total,
    'extras_total',       f.extras_total,
    'grand_total',        f.grand_total,
    'advance_amount',     COALESCE(f.advance_amount, 0),
    'status',             f.status,
    'source',             f.source,
    'id_proof_type',      f.id_proof_type,
    'id_proof_number',    f.id_proof_number,
    'is_foreign',         COALESCE(f.is_foreign, false),
    'guest_country',      f.guest_country,
    'passport_number',    f.passport_number,
    'notes',              f.notes,
    'booked_at',          f.booked_at,
    'checked_in_at',      f.checked_in_at,
    'checked_out_at',     f.checked_out_at,
    'cancelled_at',       f.cancelled_at,
    'bill_id',            f.bill_id,
    -- BATCH 022C 030e — live totals consistent with folio + bill
    'live_grand_total',   ROUND(COALESCE(live.live_grand_total, 0)::numeric, 2),
    'live_paid_amount',   ROUND(COALESCE(live.live_paid_amount, 0)::numeric, 2),
    'live_balance_due',   ROUND(
                            COALESCE(
                              live.live_balance_due_billed,
                              GREATEST(0, COALESCE(live.live_grand_total, 0) - COALESCE(live.live_paid_amount, 0))
                            )::numeric, 2)
  ) ORDER BY f.check_in_date DESC, f.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM filtered f
  LEFT JOIN live ON live.booking_id = f.id;

  RETURN jsonb_build_object('ok', true, 'bookings', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bookings_list(uuid, text, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- Verification
-- ──────────────────────────────────────────────────────────────────
-- After running, the SAME booking should show the SAME number across
-- folio, bill, and picker:
--
--   -- Folio total via get_full
--   SELECT (data->'totals'->>'grand_total')::numeric AS folio_grand,
--          (data->'totals'->>'balance_due')::numeric AS folio_balance
--     FROM (SELECT public.sbp_folio_get_full(
--             '<shop-id>'::uuid, '<booking-id>'::uuid) AS data) x;
--
--   -- Bill total (if finalized)
--   SELECT grand_total AS bill_grand, balance_due AS bill_balance
--     FROM public.bills
--    WHERE booking_id = '<booking-id>'::uuid;
--
--   -- Picker totals from list
--   SELECT b->>'live_grand_total' AS picker_grand,
--          b->>'live_balance_due' AS picker_balance
--     FROM jsonb_array_elements(
--       (public.sbp_bookings_list('<shop-id>'::uuid, 'all', NULL))->'bookings'
--     ) b
--    WHERE b->>'id' = '<booking-id>';

-- ──────────────── End of 030e_unify_totals_across_views.sql ──────
