-- ════════════════════════════════════════════════════════════════════
-- 028_folio_management.sql
-- Batch 022A — Dedicated Folio Page (9 May 2026)
--
-- Adds the schema + RPCs powering folio.html:
--
--   1. sbp_folio_extras_catalog — per-shop preset extras for one-tap
--      add. Replaces the "operator types every extra by hand" pattern
--      with a tap-tap-done quick-add UX.
--
--   2. sbp_folio_payments — multi-payment ledger. Today the schema only
--      tracks advance_amount on sbp_bookings (single value). Real
--      hotels record multiple payments per stay (advance, partial mid-
--      stay, final settle). This table is the ledger.
--
--   3. sbp_folio_get_full — one round-trip RPC that returns the full
--      folio: booking + room nights breakdown + extras + payments +
--      computed totals. The folio.html page calls this once per load.
--
--   4. sbp_folio_payment_add / sbp_folio_payment_void — record/void
--      payment events.
--
--   5. sbp_folio_extras_catalog_* — list/add/remove presets.
--
--   6. Module profile flip — surfaces folio in the sidebar.
--
-- Idempotent. Safe to re-run.
-- Prerequisites: 015 + 022 + 023 (booking + extras tables already exist)
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. Tables
-- ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.sbp_folio_extras_catalog (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id     uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  category    text NOT NULL DEFAULT 'service'
    CHECK (category IN ('food','laundry','minibar','service','telephone','transport','spa','other')),
  description text NOT NULL CHECK (length(trim(description)) > 0),
  default_qty       int NOT NULL DEFAULT 1 CHECK (default_qty >= 1),
  default_unit_price numeric NOT NULL DEFAULT 0 CHECK (default_unit_price >= 0),
  display_order int NOT NULL DEFAULT 0,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_extras_catalog_shop ON public.sbp_folio_extras_catalog(shop_id, active, display_order);

ALTER TABLE public.sbp_folio_extras_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_extras_catalog_owner ON public.sbp_folio_extras_catalog;
CREATE POLICY p_extras_catalog_owner ON public.sbp_folio_extras_catalog
  USING (shop_id IN (SELECT id FROM public.shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM public.shops WHERE owner_id = auth.uid()));


CREATE TABLE IF NOT EXISTS public.sbp_folio_payments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  booking_id    uuid NOT NULL REFERENCES public.sbp_bookings(id) ON DELETE CASCADE,
  amount        numeric NOT NULL CHECK (amount > 0),
  payment_mode  text NOT NULL DEFAULT 'cash'
    CHECK (payment_mode IN ('cash','upi','card','bank_transfer','cheque','other')),
  reference     text,
  note          text,
  is_advance    boolean NOT NULL DEFAULT false,    -- true if this is the booking advance
  is_voided     boolean NOT NULL DEFAULT false,
  voided_at     timestamptz,
  voided_reason text,
  recorded_at   timestamptz NOT NULL DEFAULT now(),
  recorded_by   uuid REFERENCES auth.users(id)
);
CREATE INDEX IF NOT EXISTS idx_folio_payments_booking ON public.sbp_folio_payments(booking_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_folio_payments_shop    ON public.sbp_folio_payments(shop_id, recorded_at DESC);

ALTER TABLE public.sbp_folio_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_folio_payments_owner ON public.sbp_folio_payments;
CREATE POLICY p_folio_payments_owner ON public.sbp_folio_payments
  USING (shop_id IN (SELECT id FROM public.shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM public.shops WHERE owner_id = auth.uid()));


-- ──────────────────────────────────────────────────────────────────
-- 2. RPC: sbp_folio_get_full(booking_id)
-- ──────────────────────────────────────────────────────────────────
--
-- Returns:
-- {
--   ok: true,
--   booking: { ... full booking row ... },
--   room: { number, type, base_price, gst_rate },
--   nights: { count, dates: [...], rate, line_total, gst_amount },
--   extras: [ ... existing sbp_booking_extras ... ],
--   payments: [ ... non-voided payments ... ],
--   totals: { room_subtotal, extras_subtotal, gst_amount, grand_total,
--             payments_total, balance_due, status }
-- }
--
-- This is what folio.html calls on load. One round-trip, page paints.

CREATE OR REPLACE FUNCTION public.sbp_folio_get_full(p_shop_id uuid, p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check    jsonb;
  v_b        record;
  v_room     record;
  v_extras   jsonb;
  v_payments jsonb;
  v_room_subtotal   numeric := 0;
  v_extras_subtotal numeric := 0;
  v_gst_amount      numeric := 0;
  v_grand_total     numeric := 0;
  v_payments_total  numeric := 0;
  v_balance_due     numeric := 0;
  v_status          text;
  v_gst_rate        numeric := 0;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b
    FROM public.sbp_bookings
   WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;

  SELECT r.id, r.room_number, r.floor, rt.name AS room_type_name, rt.base_price
    INTO v_room
    FROM public.sbp_rooms r
    LEFT JOIN public.sbp_room_types rt ON rt.id = r.room_type_id
   WHERE r.id = v_b.room_id;

  -- Compute totals (mirror logic in lib/hospitality.js / billing.html)
  v_room_subtotal := COALESCE(v_b.rate_per_night, 0) * COALESCE(v_b.num_nights, 1);

  -- GST slab on room (post 22 Sep 2025 reform)
  IF v_b.rate_per_night IS NULL OR v_b.rate_per_night <= 1000 THEN v_gst_rate := 0;
  ELSIF v_b.rate_per_night <= 7500 THEN v_gst_rate := 5;
  ELSE v_gst_rate := 18;
  END IF;
  v_gst_amount := v_room_subtotal * v_gst_rate / 100;

  -- Extras subtotal
  SELECT COALESCE(SUM(amount), 0) INTO v_extras_subtotal
    FROM public.sbp_booking_extras WHERE booking_id = p_booking_id;

  v_grand_total := v_room_subtotal + v_gst_amount + v_extras_subtotal;

  -- Payments total (excluding voided)
  SELECT COALESCE(SUM(amount), 0) INTO v_payments_total
    FROM public.sbp_folio_payments
   WHERE booking_id = p_booking_id AND is_voided = false;

  -- Also count the booking.advance_amount if no advance row exists yet
  -- (legacy bookings created before this migration won't have a payments row)
  IF NOT EXISTS (SELECT 1 FROM public.sbp_folio_payments
                  WHERE booking_id = p_booking_id AND is_advance = true AND is_voided = false)
  THEN
    v_payments_total := v_payments_total + COALESCE(v_b.advance_amount, 0);
  END IF;

  v_balance_due := GREATEST(0, v_grand_total - v_payments_total);

  -- Folio status
  v_status := CASE
    WHEN v_b.status = 'cancelled' THEN 'voided'
    WHEN v_b.status = 'checked_out' AND v_balance_due = 0 THEN 'settled'
    WHEN v_b.status = 'checked_out' THEN 'settled_balance_due'
    WHEN v_b.status = 'checked_in' THEN 'open_inhouse'
    ELSE 'open'
  END;

  -- Extras list
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',          e.id,
      'category',    e.category,
      'description', e.description,
      'qty',         e.qty,
      'unit_price',  e.unit_price,
      'amount',      e.amount,
      'added_at',    e.added_at
    ) ORDER BY e.added_at), '[]'::jsonb)
    INTO v_extras
    FROM public.sbp_booking_extras e
   WHERE e.booking_id = p_booking_id;

  -- Payments list (newest first)
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
    INTO v_payments
    FROM public.sbp_folio_payments p
   WHERE p.booking_id = p_booking_id;

  RETURN jsonb_build_object(
    'ok',      true,
    'booking', jsonb_build_object(
      'id',                v_b.id,
      'customer_name',     v_b.customer_name,
      'customer_phone',    v_b.customer_phone,
      'customer_wa',       v_b.customer_wa,
      'customer_email',    v_b.customer_email,
      'check_in_date',     v_b.check_in_date,
      'check_out_date',    v_b.check_out_date,
      'num_nights',        v_b.num_nights,
      'num_adults',        v_b.num_adults,
      'num_children',      v_b.num_children,
      'rate_per_night',    v_b.rate_per_night,
      'advance_amount',    v_b.advance_amount,
      'status',            v_b.status,
      'is_foreign',        COALESCE(v_b.is_foreign, false),
      'guest_country',     v_b.guest_country,
      'id_proof_type',     v_b.id_proof_type,
      'id_proof_number',   v_b.id_proof_number,
      'passport_number',   v_b.passport_number,
      'visa_number',       v_b.visa_number,
      'source',            v_b.source,
      'created_at',        v_b.created_at,
      'checked_in_at',     v_b.checked_in_at,
      'checked_out_at',    v_b.checked_out_at,
      'bill_id',           v_b.bill_id
    ),
    'room',    CASE WHEN v_room.id IS NULL THEN NULL ELSE jsonb_build_object(
                 'id',             v_room.id,
                 'room_number',    v_room.room_number,
                 'floor',          v_room.floor,
                 'room_type_name', v_room.room_type_name,
                 'base_price',     v_room.base_price
               ) END,
    'extras',   v_extras,
    'payments', v_payments,
    'totals',   jsonb_build_object(
      'room_nights',      COALESCE(v_b.num_nights, 1),
      'room_rate',        COALESCE(v_b.rate_per_night, 0),
      'room_subtotal',    v_room_subtotal,
      'gst_rate',         v_gst_rate,
      'gst_amount',       v_gst_amount,
      'extras_subtotal',  v_extras_subtotal,
      'grand_total',      v_grand_total,
      'payments_total',   v_payments_total,
      'balance_due',      v_balance_due,
      'status',           v_status
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_get_full(uuid, uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 3. RPC: sbp_folio_payment_add
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

  v_mode := COALESCE(p_data->>'payment_mode', 'cash');
  IF v_mode NOT IN ('cash','upi','card','bank_transfer','cheque','other') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_payment_mode');
  END IF;

  -- Confirm booking exists in this shop
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
-- 4. RPC: sbp_folio_payment_void
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_folio_payment_void(p_shop_id uuid, p_payment_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_count int;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  UPDATE public.sbp_folio_payments
     SET is_voided     = true,
         voided_at     = now(),
         voided_reason = NULLIF(p_reason, '')
   WHERE id = p_payment_id
     AND shop_id = p_shop_id
     AND is_voided = false;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'payment_not_found_or_already_voided');
  END IF;
  RETURN jsonb_build_object('ok', true, 'voided', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_payment_void(uuid, uuid, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 5. RPC: sbp_folio_extras_catalog_list / _add / _remove
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_folio_extras_catalog_list(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_rows  jsonb;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',                 c.id,
      'category',           c.category,
      'description',        c.description,
      'default_qty',        c.default_qty,
      'default_unit_price', c.default_unit_price,
      'display_order',      c.display_order,
      'active',             c.active
    ) ORDER BY c.category, c.display_order, c.description), '[]'::jsonb)
    INTO v_rows
    FROM public.sbp_folio_extras_catalog c
   WHERE c.shop_id = p_shop_id AND c.active = true;

  RETURN jsonb_build_object('ok', true, 'catalog', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_extras_catalog_list(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.sbp_folio_extras_catalog_add(p_shop_id uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_id    uuid;
  v_cat   text;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_cat := COALESCE(p_data->>'category', 'service');
  IF v_cat NOT IN ('food','laundry','minibar','service','telephone','transport','spa','other') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_category');
  END IF;

  IF length(trim(COALESCE(p_data->>'description', ''))) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'description_required');
  END IF;

  INSERT INTO public.sbp_folio_extras_catalog
    (shop_id, category, description, default_qty, default_unit_price, display_order)
  VALUES (
    p_shop_id, v_cat,
    trim(p_data->>'description'),
    COALESCE((p_data->>'default_qty')::int, 1),
    COALESCE((p_data->>'default_unit_price')::numeric, 0),
    COALESCE((p_data->>'display_order')::int, 0)
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_extras_catalog_add(uuid, jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION public.sbp_folio_extras_catalog_remove(p_shop_id uuid, p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_count int;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  UPDATE public.sbp_folio_extras_catalog SET active = false
   WHERE id = p_id AND shop_id = p_shop_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('ok', v_count > 0, 'removed', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_extras_catalog_remove(uuid, uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 6. Seed default extras catalog for hospitality shops
--    (only if no rows yet — won't override existing customizations)
-- ──────────────────────────────────────────────────────────────────

DO $$
DECLARE
  s record;
BEGIN
  FOR s IN
    SELECT id FROM public.shops
     WHERE shop_type IN (
       'day_room','hotel','resort','guesthouse','homestay','dharamshala',
       'lodge','motel','boutique_hotel','heritage_hotel','farm_stay','villa_rental','tent_camp'
     )
  LOOP
    -- Only seed if shop has zero catalog rows
    IF NOT EXISTS (SELECT 1 FROM public.sbp_folio_extras_catalog WHERE shop_id = s.id) THEN
      INSERT INTO public.sbp_folio_extras_catalog (shop_id, category, description, default_qty, default_unit_price, display_order) VALUES
        (s.id, 'food',      'Breakfast (per person)',     1,  150, 10),
        (s.id, 'food',      'Lunch (per person)',         1,  250, 11),
        (s.id, 'food',      'Dinner (per person)',        1,  300, 12),
        (s.id, 'food',      'Tea / Coffee',               1,   30, 13),
        (s.id, 'minibar',   'Water bottle 1L',            1,   30, 20),
        (s.id, 'minibar',   'Soft drink',                 1,   60, 21),
        (s.id, 'minibar',   'Snack pack',                 1,   80, 22),
        (s.id, 'laundry',   'Laundry — small load',       1,  150, 30),
        (s.id, 'laundry',   'Laundry — full load',        1,  300, 31),
        (s.id, 'laundry',   'Iron / Press (per piece)',   1,   20, 32),
        (s.id, 'service',   'Late check-out',             1,  500, 40),
        (s.id, 'service',   'Early check-in',             1,  500, 41),
        (s.id, 'service',   'Extra bed',                  1,  500, 42),
        (s.id, 'service',   'Extra towel / linen',        1,  100, 43),
        (s.id, 'transport', 'Airport pickup',             1,  800, 50),
        (s.id, 'transport', 'Airport drop',               1,  800, 51),
        (s.id, 'transport', 'Local sightseeing (half day)', 1, 1500, 52),
        (s.id, 'telephone', 'STD call',                   1,    5, 60),
        (s.id, 'telephone', 'ISD call',                   1,   50, 61),
        (s.id, 'spa',       'Body massage (1hr)',         1, 1500, 70),
        (s.id, 'other',     'Damage / Replacement',       1,    0, 90);
    END IF;
  END LOOP;
END $$;


-- ──────────────────────────────────────────────────────────────────
-- 7. Module profile entry — surface folio in the sidebar
-- ──────────────────────────────────────────────────────────────────

INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('hospitality', 'folio', 'active', 'NEW', 165)
ON CONFLICT (profile, module_code) DO UPDATE
  SET status = EXCLUDED.status,
      badge  = EXCLUDED.badge,
      display_order = EXCLUDED.display_order;


-- ──────────────────────────────────────────────────────────────────
-- 8. Verification
-- ──────────────────────────────────────────────────────────────────

-- Get the full folio for a recent booking:
--   SELECT public.sbp_folio_get_full(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     (SELECT id FROM public.sbp_bookings ORDER BY created_at DESC LIMIT 1)
--   );

-- List catalog:
--   SELECT public.sbp_folio_extras_catalog_list(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
--   );

-- ──────────────── End of 028_folio_management.sql ────────────────
