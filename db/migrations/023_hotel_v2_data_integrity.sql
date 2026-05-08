-- ════════════════════════════════════════════════════════════════════
-- 023_hotel_v2_data_integrity.sql
-- Batch 021.3 — Data integrity hotfix (8 May 2026)
--
-- Three independent fixes, all idempotent and safe to re-run:
--
--   1. Ensure bill_items table has all 6 columns introduced in Batch
--      019 (Universal Item Picker): kind, product_id, service_id,
--      room_type_id, unit, qty_unit_label.
--      ROOT CAUSE of the "Items not available" bug on hotel bills:
--      billing.html INSERTs referenced these columns. If migration 020
--      was never run, the INSERT failed silently and master bills
--      saved with zero line items.
--
--   2. Auto-create or link customer record on hotel booking creation +
--      check-out. Walk-in guests at the front desk should appear in
--      the Customer Book like any other customer. Currently
--      sbp_bookings_create stores customer_name on the booking row
--      but never adds them to the customers table.
--
--   3. Salvage RPC for already-broken hotel bills. Reconstructs
--      bill_items from the original booking's room + extras data,
--      using the GST-correct math from migration 022.
--      Run via: SELECT public.sbp_salvage_orphan_hotel_bills(shop_id);
--      Idempotent — only acts on bills with zero items.
--
-- ════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- 1. Ensure bill_items has all Batch 019 columns
-- ──────────────────────────────────────────────────────────────────

DO $$
BEGIN
  -- kind: 'product' | 'service' | 'room' | 'fee' etc.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bill_items' AND column_name = 'kind'
  ) THEN
    ALTER TABLE public.bill_items ADD COLUMN kind text NOT NULL DEFAULT 'product';
    RAISE NOTICE 'Added column bill_items.kind';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bill_items' AND column_name = 'product_id'
  ) THEN
    ALTER TABLE public.bill_items ADD COLUMN product_id uuid;
    RAISE NOTICE 'Added column bill_items.product_id';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bill_items' AND column_name = 'service_id'
  ) THEN
    ALTER TABLE public.bill_items ADD COLUMN service_id uuid;
    RAISE NOTICE 'Added column bill_items.service_id';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bill_items' AND column_name = 'room_type_id'
  ) THEN
    ALTER TABLE public.bill_items ADD COLUMN room_type_id uuid;
    RAISE NOTICE 'Added column bill_items.room_type_id';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bill_items' AND column_name = 'booking_id'
  ) THEN
    ALTER TABLE public.bill_items ADD COLUMN booking_id uuid;
    RAISE NOTICE 'Added column bill_items.booking_id';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bill_items' AND column_name = 'unit'
  ) THEN
    ALTER TABLE public.bill_items ADD COLUMN unit text;
    RAISE NOTICE 'Added column bill_items.unit';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'bill_items' AND column_name = 'qty_unit_label'
  ) THEN
    ALTER TABLE public.bill_items ADD COLUMN qty_unit_label text;
    RAISE NOTICE 'Added column bill_items.qty_unit_label';
  END IF;
END $$;

-- Index for kind-based reporting queries
CREATE INDEX IF NOT EXISTS idx_bill_items_kind ON public.bill_items(kind);
CREATE INDEX IF NOT EXISTS idx_bill_items_booking_id ON public.bill_items(booking_id) WHERE booking_id IS NOT NULL;

-- ──────────────────────────────────────────────────────────────────
-- 2. Customer auto-create / link helper
-- ──────────────────────────────────────────────────────────────────
--
-- Looks up an existing customer by phone for the shop, or creates
-- a new one. Returns the customer_id. Used by both bookings_create
-- and bookings_check_out.

CREATE OR REPLACE FUNCTION public.sbp_resolve_customer_for_booking(
  p_shop_id  uuid,
  p_name     text,
  p_phone    text,
  p_wa       text DEFAULT NULL,
  p_email    text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_customer_id uuid;
  v_norm_phone  text;
BEGIN
  -- Need at least a name to create a customer record
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RETURN NULL;
  END IF;

  -- Normalize phone — strip whitespace and non-digit characters except leading +
  v_norm_phone := NULLIF(regexp_replace(COALESCE(p_phone, ''), '[^0-9+]', '', 'g'), '');

  -- Look up by phone first (most reliable)
  IF v_norm_phone IS NOT NULL THEN
    SELECT id INTO v_customer_id
    FROM public.customers
    WHERE shop_id = p_shop_id
      AND regexp_replace(COALESCE(phone, ''), '[^0-9+]', '', 'g') = v_norm_phone
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_customer_id IS NOT NULL THEN
      RETURN v_customer_id;
    END IF;
  END IF;

  -- Fall back: lookup by name (case-insensitive) if no phone match
  IF v_norm_phone IS NULL THEN
    SELECT id INTO v_customer_id
    FROM public.customers
    WHERE shop_id = p_shop_id
      AND lower(trim(name)) = lower(trim(p_name))
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_customer_id IS NOT NULL THEN
      RETURN v_customer_id;
    END IF;
  END IF;

  -- Not found — create new
  INSERT INTO public.customers (shop_id, name, phone, whatsapp, email, customer_type)
  VALUES (
    p_shop_id,
    trim(p_name),
    v_norm_phone,
    NULLIF(trim(COALESCE(p_wa, '')), ''),
    NULLIF(trim(COALESCE(p_email, '')), ''),
    'regular'
  )
  RETURNING id INTO v_customer_id;

  RETURN v_customer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_resolve_customer_for_booking(uuid, text, text, text, text) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 3. Update sbp_bookings_create to auto-link customer
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_bookings_create(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check       jsonb;
  v_in          date;
  v_out         date;
  v_nights      int;
  v_rate        numeric;
  v_room_id     uuid;
  v_room        sbp_rooms%ROWTYPE;
  v_rt          sbp_room_types%ROWTYPE;
  v_room_total  numeric;
  v_grand       numeric;
  v_row         sbp_bookings%ROWTYPE;
  v_cust_name   text;
  v_advance     numeric;
  v_customer_id uuid;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_cust_name := trim(coalesce(p_data->>'customer_name', ''));
  IF length(v_cust_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_name_required');
  END IF;

  v_in  := (p_data->>'check_in_date')::date;
  v_out := (p_data->>'check_out_date')::date;
  IF v_in IS NULL OR v_out IS NULL OR v_out <= v_in THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date_range');
  END IF;
  v_nights := (v_out - v_in)::int;

  v_room_id := NULLIF(p_data->>'room_id','')::uuid;
  IF v_room_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_id_required');
  END IF;

  SELECT * INTO v_room FROM sbp_rooms WHERE id = v_room_id AND shop_id = p_shop_id;
  IF v_room.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_not_found');
  END IF;
  IF v_room.status IN ('maintenance','blocked') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_unavailable');
  END IF;

  IF EXISTS (
    SELECT 1 FROM sbp_bookings
    WHERE room_id = v_room_id
      AND status IN ('pending','confirmed','checked_in')
      AND check_in_date < v_out
      AND check_out_date > v_in
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_already_booked');
  END IF;

  IF v_room.room_type_id IS NOT NULL THEN
    SELECT * INTO v_rt FROM sbp_room_types WHERE id = v_room.room_type_id;
  END IF;
  v_rate := COALESCE(NULLIF(p_data->>'rate_per_night','')::numeric, v_rt.base_price, 0);
  v_room_total := v_rate * v_nights;
  v_grand := v_room_total
           + COALESCE((p_data->>'tax_amount')::numeric, 0)
           - COALESCE((p_data->>'discount_amount')::numeric, 0);

  v_advance := COALESCE((p_data->>'advance_amount')::numeric, 0);

  -- ── Batch 021.3 — resolve or create customer record ──
  v_customer_id := NULLIF(p_data->>'customer_id','')::uuid;
  IF v_customer_id IS NULL THEN
    v_customer_id := sbp_resolve_customer_for_booking(
      p_shop_id,
      v_cust_name,
      p_data->>'customer_phone',
      p_data->>'customer_wa',
      p_data->>'customer_email'
    );
  END IF;

  INSERT INTO sbp_bookings (
    shop_id,
    customer_id, customer_name, customer_phone, customer_wa, customer_email,
    num_adults, num_children,
    room_id, room_type_id,
    check_in_date, check_out_date, num_nights,
    rate_per_night, room_total, discount_amount, tax_amount, grand_total,
    status, source,
    id_proof_type, id_proof_number,
    notes, internal_notes,
    advance_amount, advance_paid_at, advance_payment_mode, advance_reference,
    is_foreign, guest_country, passport_number, passport_expiry,
    visa_number, visa_type, visa_expiry,
    arrival_in_india_date, intended_departure_date,
    address_abroad, next_address_in_india, purpose_of_visit
  )
  VALUES (
    p_shop_id,
    v_customer_id, v_cust_name,
    p_data->>'customer_phone',
    p_data->>'customer_wa',
    p_data->>'customer_email',
    COALESCE((p_data->>'num_adults')::int, 1),
    COALESCE((p_data->>'num_children')::int, 0),
    v_room_id, v_room.room_type_id,
    v_in, v_out, v_nights,
    v_rate, v_room_total,
    COALESCE((p_data->>'discount_amount')::numeric, 0),
    COALESCE((p_data->>'tax_amount')::numeric, 0),
    v_grand,
    COALESCE(p_data->>'status', 'confirmed'),
    COALESCE(p_data->>'source', 'admin'),
    NULLIF(p_data->>'id_proof_type',''),
    p_data->>'id_proof_number',
    p_data->>'notes', p_data->>'internal_notes',
    v_advance,
    CASE WHEN v_advance > 0 THEN now() ELSE NULL END,
    NULLIF(p_data->>'advance_payment_mode',''),
    NULLIF(p_data->>'advance_reference',''),
    COALESCE((p_data->>'is_foreign')::boolean, false),
    NULLIF(p_data->>'guest_country',''),
    NULLIF(p_data->>'passport_number',''),
    NULLIF(p_data->>'passport_expiry','')::date,
    NULLIF(p_data->>'visa_number',''),
    NULLIF(p_data->>'visa_type',''),
    NULLIF(p_data->>'visa_expiry','')::date,
    NULLIF(p_data->>'arrival_in_india_date','')::date,
    NULLIF(p_data->>'intended_departure_date','')::date,
    NULLIF(p_data->>'address_abroad',''),
    NULLIF(p_data->>'next_address_in_india',''),
    NULLIF(p_data->>'purpose_of_visit','')
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok', true, 'booking', to_jsonb(v_row), 'customer_id', v_customer_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bookings_create(uuid, jsonb) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 4. One-shot backfill: link existing bookings to customers
-- ──────────────────────────────────────────────────────────────────
--
-- For every existing booking that has customer_name but no customer_id,
-- resolve or create the customer record and link it.

DO $$
DECLARE
  r record;
  v_cust_id uuid;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT id, shop_id, customer_name, customer_phone, customer_wa, customer_email
    FROM sbp_bookings
    WHERE customer_id IS NULL
      AND customer_name IS NOT NULL
      AND length(trim(customer_name)) > 0
  LOOP
    BEGIN
      v_cust_id := public.sbp_resolve_customer_for_booking(
        r.shop_id, r.customer_name, r.customer_phone, r.customer_wa, r.customer_email
      );
      IF v_cust_id IS NOT NULL THEN
        UPDATE sbp_bookings SET customer_id = v_cust_id WHERE id = r.id;
        v_count := v_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not resolve customer for booking % (%): %', r.id, r.customer_name, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE 'Backfilled customer_id for % bookings', v_count;
END $$;

-- Same for bills with customer_name but no customer_id.
-- Defensive: bills schemas vary, so we wrap everything in an outer EXCEPTION
-- and only reference columns we know exist (customer_name + customer_email).
DO $$
DECLARE
  r record;
  v_cust_id uuid;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT id, shop_id, customer_name, customer_email
    FROM bills
    WHERE customer_id IS NULL
      AND customer_name IS NOT NULL
      AND length(trim(customer_name)) > 0
      AND status NOT IN ('voided','draft')
  LOOP
    BEGIN
      v_cust_id := public.sbp_resolve_customer_for_booking(
        r.shop_id, r.customer_name, NULL, NULL, r.customer_email
      );
      IF v_cust_id IS NOT NULL THEN
        UPDATE bills SET customer_id = v_cust_id WHERE id = r.id;
        v_count := v_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;  -- Single bill failed, keep going
    END;
  END LOOP;
  RAISE NOTICE 'Backfilled customer_id for % bills', v_count;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Bills backfill skipped (schema variation): %', SQLERRM;
END $$;

-- ──────────────────────────────────────────────────────────────────
-- 5. Salvage RPC: rebuild bill_items for orphaned hotel bills
-- ──────────────────────────────────────────────────────────────────
--
-- Idempotent. Walks all checked-out bookings whose linked bill has
-- zero items, and reconstructs them from the booking + extras using
-- the same GST math used at check-out.

CREATE OR REPLACE FUNCTION public.sbp_salvage_orphan_hotel_bills(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check        jsonb;
  v_total_bills  int := 0;
  v_fixed_bills  int := 0;
  v_total_items  int := 0;
  r_booking      record;
  r_extra        record;
  v_existing_cnt int;
  v_extras_cnt   int;
  v_room_gst     numeric;
  v_room_cgst    numeric;
  v_room_sgst    numeric;
  v_room_taxable numeric;
  v_room_total_w numeric;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  FOR r_booking IN
    SELECT b.*
    FROM sbp_bookings b
    WHERE b.shop_id = p_shop_id
      AND b.status = 'checked_out'
      AND b.bill_id IS NOT NULL
  LOOP
    v_total_bills := v_total_bills + 1;

    -- Determine expected item count: 1 (room) + N extras
    SELECT COUNT(*) INTO v_extras_cnt FROM sbp_booking_extras WHERE booking_id = r_booking.id;

    -- Skip if bill already has the right number of items (room + extras)
    -- (Re-salvage if items are missing OR partially present from earlier failed insert)
    SELECT COUNT(*) INTO v_existing_cnt FROM bill_items WHERE bill_id = r_booking.bill_id;
    IF v_existing_cnt = (1 + v_extras_cnt) THEN CONTINUE; END IF;

    -- Bill exists but with wrong number of items — wipe and rebuild for consistency
    IF v_existing_cnt > 0 THEN
      DELETE FROM bill_items WHERE bill_id = r_booking.bill_id;
      RAISE NOTICE 'Wiped % stale items from bill % to rebuild', v_existing_cnt, r_booking.bill_id;
    END IF;

    -- Compute room GST per slab
    v_room_gst := sbp_hotel_room_gst_for_rate(r_booking.rate_per_night);
    v_room_taxable := r_booking.room_total;
    IF v_room_gst > 0 THEN
      v_room_cgst := ROUND((v_room_taxable * v_room_gst / 200.0)::numeric, 2);
      v_room_sgst := ROUND((v_room_taxable * v_room_gst / 100.0 - v_room_cgst)::numeric, 2);
    ELSE
      v_room_cgst := 0;
      v_room_sgst := 0;
    END IF;
    v_room_total_w := v_room_taxable + v_room_cgst + v_room_sgst;

    -- Insert ROOM line
    INSERT INTO bill_items (
      bill_id, item_name, qty, rate, gst_rate,
      discount, line_total, gst_amount,
      kind, room_type_id, booking_id, unit, qty_unit_label
    ) VALUES (
      r_booking.bill_id,
      'Room ' || COALESCE(r_booking.room_number_snapshot, '') ||
        CASE WHEN r_booking.room_type_snapshot IS NOT NULL
             THEN ' · ' || r_booking.room_type_snapshot ELSE '' END ||
        ' (' || r_booking.check_in_date || ' → ' || r_booking.check_out_date || ')',
      r_booking.num_nights,
      r_booking.rate_per_night,
      v_room_gst,
      0,
      v_room_total_w,
      v_room_cgst + v_room_sgst,
      'room',
      r_booking.room_type_id,
      r_booking.id,
      'night',
      r_booking.num_nights || ' night' || CASE WHEN r_booking.num_nights > 1 THEN 's' ELSE '' END
    );
    v_total_items := v_total_items + 1;

    -- Insert EXTRA lines
    FOR r_extra IN
      SELECT * FROM sbp_booking_extras WHERE booking_id = r_booking.id ORDER BY added_at ASC
    LOOP
      INSERT INTO bill_items (
        bill_id, item_name, qty, rate, gst_rate,
        discount, line_total, gst_amount,
        kind, booking_id
      ) VALUES (
        r_booking.bill_id,
        COALESCE(r_extra.description, 'Extra') ||
          CASE WHEN r_extra.category IS NOT NULL
               THEN ' (' || r_extra.category || ')' ELSE '' END,
        r_extra.qty,
        -- Use taxable_amount/qty as rate (so bill GST math reaches gross total)
        CASE WHEN r_extra.qty > 0 AND r_extra.taxable_amount IS NOT NULL
             THEN ROUND((r_extra.taxable_amount / r_extra.qty)::numeric, 2)
             ELSE r_extra.unit_price END,
        COALESCE(r_extra.gst_rate, 0),
        0,
        COALESCE(r_extra.total_with_gst, r_extra.amount),
        COALESCE(r_extra.cgst_amount, 0) + COALESCE(r_extra.sgst_amount, 0),
        CASE WHEN lower(COALESCE(r_extra.category, '')) IN ('service','spa','laundry','salon','massage','transport','tour')
             THEN 'service' ELSE 'product' END,
        r_booking.id
      );
      v_total_items := v_total_items + 1;
    END LOOP;

    v_fixed_bills := v_fixed_bills + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'total_checked_out_bookings', v_total_bills,
    'bills_salvaged',             v_fixed_bills,
    'items_inserted',             v_total_items
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_salvage_orphan_hotel_bills(uuid) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 6. Verification queries
-- ──────────────────────────────────────────────────────────────────

-- (1) Confirm bill_items has all required columns
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'bill_items'
--     AND column_name IN ('kind','product_id','service_id','room_type_id','booking_id','unit','qty_unit_label');
--   Expected: 7 rows.

-- (2) Confirm customer auto-create works on a fresh booking
--   (Create a new walk-in booking via the app and check the Customer Book — guest should appear.)

-- (3) Run the salvage to fix already-broken bills:
--   SELECT public.sbp_salvage_orphan_hotel_bills(
--     (SELECT id FROM shops WHERE shop_type IN ('hotel','resort','guesthouse','service_apartment','boutique_hotel','hostel','day_room') LIMIT 1)::uuid
--   );
--   Expected: { ok: true, total_checked_out_bookings: N, bills_salvaged: N, items_inserted: M }

-- (4) After salvage, confirm Jyoti's GG-0076 has 3 items:
--   SELECT item_name, qty, rate, gst_rate, line_total FROM bill_items
--   WHERE bill_id = (SELECT id FROM bills WHERE invoice_no = 'GG-0076' LIMIT 1);
--   Expected: 3 rows (Room, dinner, wine).

-- ──────────────── End of 023_hotel_v2_data_integrity.sql ────────────────
