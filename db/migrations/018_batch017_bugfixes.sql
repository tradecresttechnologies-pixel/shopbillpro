-- ════════════════════════════════════════════════════════════════════
-- 018_batch017_bugfixes.sql
-- Batch 017 — Bug fixes (7 May 2026)
--
-- Bundles two server-side fixes:
--
-- BUG-023 (HIGH): Hotel guests not appearing in Customers list.
--   When a hotel booking is created via sbp_bookings_create(), only the
--   sbp_bookings row gets the guest details (name/phone/wa). No row was
--   being added to the customers table. Result: shopkeeper opens the
--   Customers page and sees only customers added through bills, not
--   hotel guests.
--   FIX: At booking-create time, look up customers by phone (or name +
--   shop_id if no phone). If not found → INSERT new customer. Either
--   way, link sbp_bookings.customer_id to the matched/created customer.
--
-- BUG-020 (HIGH): Customer history stats still empty even after 017's
--   name-fallback. Some legacy bills also have customer_name = '' and
--   only customer_phone populated. Need a third match path.
--   FIX: sbp_get_customer_timeline now matches bills by EITHER
--   customer_id OR customer_name OR customer_phone (with NULL/empty
--   string handling).
--
-- Idempotent: re-running just re-creates the functions.
-- Prerequisite: Migrations 011 (appointments), 015 (hospitality),
-- 017 (timeline name fallback) deployed.
-- ════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────
-- BUG-023 FIX: sbp_bookings_create now ALSO ensures a customers row.
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_bookings_create(p_shop_id uuid, p_data jsonb)
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
  v_cust_phone  text;
  v_cust_wa     text;
  v_cust_email  text;
  v_cust_id     uuid;     -- linked customer (existing or freshly created)
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_cust_name  := trim(coalesce(p_data->>'customer_name',  ''));
  v_cust_phone := NULLIF(trim(coalesce(p_data->>'customer_phone', '')), '');
  v_cust_wa    := NULLIF(trim(coalesce(p_data->>'customer_wa',    '')), '');
  v_cust_email := NULLIF(trim(coalesce(p_data->>'customer_email', '')), '');

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

  -- Verify room belongs to shop + is bookable
  SELECT * INTO v_room FROM sbp_rooms WHERE id = v_room_id AND shop_id = p_shop_id;
  IF v_room.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_not_found');
  END IF;
  IF v_room.status IN ('maintenance','blocked') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_unavailable');
  END IF;

  -- Conflict check
  IF EXISTS (
    SELECT 1 FROM sbp_bookings
    WHERE room_id = v_room_id
      AND status IN ('pending','confirmed','checked_in')
      AND check_in_date < v_out
      AND check_out_date > v_in
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_already_booked');
  END IF;

  -- Pricing
  IF v_room.room_type_id IS NOT NULL THEN
    SELECT * INTO v_rt FROM sbp_room_types WHERE id = v_room.room_type_id;
  END IF;
  v_rate := COALESCE(NULLIF(p_data->>'rate_per_night','')::numeric, v_rt.base_price, 0);
  v_room_total := v_rate * v_nights;
  v_grand := v_room_total
           + COALESCE((p_data->>'tax_amount')::numeric, 0)
           - COALESCE((p_data->>'discount_amount')::numeric, 0);

  -- ── BUG-023 FIX: Resolve / create customer record ──
  -- 1. If client passed customer_id explicitly, trust it
  v_cust_id := NULLIF(p_data->>'customer_id','')::uuid;

  -- 2. Else lookup by phone (most reliable identifier)
  IF v_cust_id IS NULL AND v_cust_phone IS NOT NULL THEN
    SELECT id INTO v_cust_id
    FROM customers
    WHERE shop_id = p_shop_id
      AND (phone = v_cust_phone OR whatsapp = v_cust_phone)
    LIMIT 1;
  END IF;

  -- 3. Else lookup by exact name match (lower-case to be lenient)
  IF v_cust_id IS NULL THEN
    SELECT id INTO v_cust_id
    FROM customers
    WHERE shop_id = p_shop_id
      AND lower(trim(name)) = lower(v_cust_name)
    LIMIT 1;
  END IF;

  -- 4. Still nothing → create a new customer record
  IF v_cust_id IS NULL THEN
    INSERT INTO customers (shop_id, name, phone, whatsapp, email, customer_type, joined_at)
    VALUES (
      p_shop_id, v_cust_name, v_cust_phone, v_cust_wa, v_cust_email,
      'regular', now()
    )
    RETURNING id INTO v_cust_id;
  ELSE
    -- Update phone/whatsapp/email if previously empty (don't overwrite real values)
    UPDATE customers
       SET phone    = COALESCE(phone,    v_cust_phone),
           whatsapp = COALESCE(whatsapp, v_cust_wa),
           email    = COALESCE(email,    v_cust_email)
     WHERE id = v_cust_id;
  END IF;

  -- ── Insert the booking, now with customer_id linked ──
  INSERT INTO sbp_bookings (
    shop_id,
    customer_id, customer_name, customer_phone, customer_wa, customer_email,
    num_adults, num_children,
    room_id, room_type_id,
    check_in_date, check_out_date, num_nights,
    rate_per_night, room_total, discount_amount, tax_amount, grand_total,
    status, source,
    id_proof_type, id_proof_number,
    notes, internal_notes
  )
  VALUES (
    p_shop_id,
    v_cust_id,                                      -- BUG-023: now always populated
    v_cust_name, v_cust_phone, v_cust_wa, v_cust_email,
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
    p_data->>'notes', p_data->>'internal_notes'
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok', true, 'booking', to_jsonb(v_row), 'customer_id', v_cust_id);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_bookings_create(uuid, jsonb) TO authenticated;


-- ────────────────────────────────────────────────────────────────────
-- BUG-020 FIX: customer_timeline also matches bills by phone.
-- (previous 017 added name fallback; some legacy bills have only phone)
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_get_customer_timeline(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_user_id    uuid;
  v_customer   record;
  v_shop_id    uuid;
  v_cust_name  text;
  v_cust_phone text;
  v_cust_wa    text;
  v_stats      jsonb;
  v_timeline   jsonb;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_customer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_id_required');
  END IF;

  SELECT c.*
  INTO v_customer
  FROM customers c
  JOIN shops s ON s.id = c.shop_id
  WHERE c.id = p_customer_id AND s.owner_id = v_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_not_found_or_unauthorized');
  END IF;

  v_shop_id    := v_customer.shop_id;
  v_cust_name  := NULLIF(trim(coalesce(v_customer.name, '')), '');
  v_cust_phone := NULLIF(trim(coalesce(v_customer.phone, '')), '');
  v_cust_wa    := NULLIF(trim(coalesce(v_customer.whatsapp, '')), '');

  -- Stats — 3-way bill match: id, name, phone (or whatsapp).
  WITH bill_stats AS (
    SELECT
      COUNT(*) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided')::int AS total_bills,
      COUNT(*) FILTER (WHERE b.voided_at IS NOT NULL OR b.status = 'voided')::int AS voided_bills,
      COALESCE(SUM(b.grand_total) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_spent,
      COALESCE(SUM(b.paid_amount) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_paid,
      COALESCE(SUM(b.balance_due) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS balance_due,
      MIN(b.created_at) AS first_bill_at,
      MAX(b.created_at) AS last_bill_at
    FROM bills b
    WHERE b.shop_id = v_shop_id
      AND (
            b.customer_id = p_customer_id
        OR (b.customer_id IS NULL AND v_cust_name  IS NOT NULL AND lower(trim(b.customer_name))  = lower(v_cust_name))
        OR (b.customer_id IS NULL AND v_cust_phone IS NOT NULL AND b.customer_phone = v_cust_phone)
        OR (b.customer_id IS NULL AND v_cust_wa    IS NOT NULL AND b.customer_phone = v_cust_wa)
      )
  ),
  appt_stats AS (
    SELECT
      COUNT(*)::int                                                  AS appointments_total,
      COUNT(*) FILTER (WHERE status = 'completed')::int              AS appointments_completed,
      COUNT(*) FILTER (WHERE status IN ('cancelled','no_show'))::int AS appointments_cancelled
    FROM sbp_appointments
    WHERE shop_id = v_shop_id AND customer_id = p_customer_id
  ),
  loyalty_balance_calc AS (
    SELECT (points_earned - points_redeemed - points_expired)::int AS loyalty_balance
    FROM sbp_customer_loyalty
    WHERE shop_id = v_shop_id AND customer_id = p_customer_id
  )
  SELECT jsonb_build_object(
    'total_bills',            COALESCE(bs.total_bills, 0),
    'voided_bills',           COALESCE(bs.voided_bills, 0),
    'total_spent',            COALESCE(bs.total_spent, 0),
    'total_paid',             COALESCE(bs.total_paid, 0),
    'balance_due',            COALESCE(bs.balance_due, 0),
    'first_bill_at',          bs.first_bill_at,
    'last_bill_at',           bs.last_bill_at,
    'avg_ticket',             CASE WHEN COALESCE(bs.total_bills,0) > 0
                                   THEN ROUND(bs.total_spent / bs.total_bills, 2)
                                   ELSE 0 END,
    'appointments_total',     COALESCE(a.appointments_total, 0),
    'appointments_completed', COALESCE(a.appointments_completed, 0),
    'appointments_cancelled', COALESCE(a.appointments_cancelled, 0),
    'loyalty_balance',        COALESCE(lb.loyalty_balance, 0)
  )
  INTO v_stats
  FROM bill_stats bs CROSS JOIN appt_stats a LEFT JOIN loyalty_balance_calc lb ON true;

  -- Timeline — same 3-way match for bill events.
  WITH bill_events AS (
    SELECT
      'bill'::text AS event_type,
      b.created_at AS event_at,
      jsonb_build_object(
        'id',            b.id,
        'invoice_no',    b.invoice_no,
        'invoice_date',  b.invoice_date,
        'grand_total',   b.grand_total,
        'paid_amount',   b.paid_amount,
        'balance_due',   b.balance_due,
        'status',        b.status,
        'voided',        (b.voided_at IS NOT NULL OR b.status = 'voided'),
        'voided_at',     b.voided_at,
        'payment_mode',  b.payment_mode,
        'items_count',   (SELECT COUNT(*)::int FROM bill_items bi WHERE bi.bill_id = b.id),
        'items_summary', (
          SELECT string_agg(item_name, ', ' ORDER BY id)
          FROM (SELECT bi.item_name, bi.id FROM bill_items bi WHERE bi.bill_id = b.id ORDER BY bi.id LIMIT 5) x
        )
      ) AS payload
    FROM bills b
    WHERE b.shop_id = v_shop_id
      AND (
            b.customer_id = p_customer_id
        OR (b.customer_id IS NULL AND v_cust_name  IS NOT NULL AND lower(trim(b.customer_name))  = lower(v_cust_name))
        OR (b.customer_id IS NULL AND v_cust_phone IS NOT NULL AND b.customer_phone = v_cust_phone)
        OR (b.customer_id IS NULL AND v_cust_wa    IS NOT NULL AND b.customer_phone = v_cust_wa)
      )
  ),
  appt_events AS (
    SELECT
      'appointment'::text AS event_type,
      a.created_at        AS event_at,
      jsonb_build_object(
        'id',                   a.id,
        'starts_at',            a.starts_at,
        'ends_at',              a.ends_at,
        'duration_minutes',     a.duration_minutes,
        'status',               a.status,
        'service_name',         a.service_name_snapshot,
        'service_price',        a.service_price_snapshot,
        'source',               a.source,
        'notes',                a.notes,
        'bill_id',              a.bill_id,
        'cancelled_at',         a.cancelled_at,
        'cancelled_reason',     a.cancelled_reason,
        'provider_id',          a.provider_id,
        'provider_name',        (SELECT name FROM sbp_appointment_providers p WHERE p.id = a.provider_id)
      ) AS payload
    FROM sbp_appointments a
    WHERE a.shop_id = v_shop_id AND a.customer_id = p_customer_id
  ),
  loyalty_events AS (
    SELECT
      'loyalty'::text  AS event_type,
      lt.created_at    AS event_at,
      jsonb_build_object(
        'id',          lt.id,
        'txn_type',    lt.txn_type,
        'points',      lt.points,
        'description', lt.description,
        'bill_id',     lt.bill_id
      ) AS payload
    FROM sbp_loyalty_transactions lt
    WHERE lt.shop_id = v_shop_id AND lt.customer_id = p_customer_id
  ),
  registered_event AS (
    SELECT
      'registered'::text   AS event_type,
      v_customer.joined_at AS event_at,
      jsonb_build_object(
        'note',          'Customer added to your shop',
        'customer_type', v_customer.customer_type
      ) AS payload
    WHERE v_customer.joined_at IS NOT NULL
  ),
  all_events AS (
    SELECT * FROM bill_events
    UNION ALL SELECT * FROM appt_events
    UNION ALL SELECT * FROM loyalty_events
    UNION ALL SELECT * FROM registered_event
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'type', event_type, 'at', event_at, 'payload', payload
  ) ORDER BY event_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_timeline
  FROM (
    SELECT * FROM all_events ORDER BY event_at DESC NULLS LAST LIMIT 500
  ) ranked;

  RETURN jsonb_build_object(
    'ok', true,
    'customer', jsonb_build_object(
      'id',            v_customer.id,
      'name',          v_customer.name,
      'phone',         v_customer.phone,
      'whatsapp',      v_customer.whatsapp,
      'email',         v_customer.email,
      'address',       v_customer.address,
      'city',          v_customer.city,
      'gstin',         v_customer.gstin,
      'customer_type', v_customer.customer_type,
      'joined_at',     v_customer.joined_at
    ),
    'stats',    v_stats,
    'timeline', v_timeline
  );
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_get_customer_timeline(uuid) TO authenticated;


-- ────────────────────────────────────────────────────────────────────
-- VERIFICATION (paste in SQL Editor):
-- ────────────────────────────────────────────────────────────────────
--
-- (1) Functions recompiled:
--     SELECT proname, pg_get_function_arguments(oid)
--     FROM pg_proc
--     WHERE proname IN ('sbp_bookings_create','sbp_get_customer_timeline');
--     -- Expected: 2 rows
--
-- (2) BUG-020 smoke test (Jyoti — after this lands, stats should be non-zero):
--     SELECT sbp_get_customer_timeline('<jyoti-uuid>');
--     -- stats.total_bills should be 7 (matching customer page count)
--
-- (3) BUG-023 smoke test (creating a NEW booking should now populate customers):
--     -- After creating a booking via UI for a brand-new guest:
--     SELECT id, name, phone FROM customers WHERE shop_id = '<your-shop>'
--       ORDER BY joined_at DESC LIMIT 5;
--     -- The hotel guest should appear here.

-- ════════════════════════════════════════════════════════════════════
-- DONE
-- ════════════════════════════════════════════════════════════════════
