-- ════════════════════════════════════════════════════════════════════
-- 027_hotel_compliance.sql
-- Batch 021B-B — Form B (Hotel Register) + Form C (FRRO) (9 May 2026)
--
-- Two new read-only RPCs powering compliance.html:
--
--   1. sbp_hotel_form_b_register(shop_id, p_from, p_to) — Indian
--      Hotel Register (state-mandated under Police Act / Local Hotel
--      Rules). Returns ALL bookings (Indian + foreign) that arrived in
--      the date range, in register-row format.
--
--   2. sbp_hotel_form_c_data(shop_id, p_from, p_to) — FRRO Form C
--      (Bureau of Immigration). Returns FOREIGN bookings only with
--      passport/visa/address-abroad/purpose-of-visit fields needed
--      for compliance.frro.gov.in submission.
--
-- All dates evaluated in IST (Asia/Kolkata) — Indian regulators run
-- on local time.
--
-- Idempotent. Safe to re-run.
-- Prerequisites: migrations 015 + 022 + 023.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. RPC: sbp_hotel_form_b_register
-- ──────────────────────────────────────────────────────────────────
--
-- Args:  p_shop_id uuid, p_from date, p_to date
-- Range: bookings with check_in_date BETWEEN p_from AND p_to
--        (bookings that arrived during the window).
--
-- Returns:
-- {
--   ok: true,
--   shop: { name, address, gstin, phone },
--   period: { from, to },
--   total: N,
--   rows: [
--     { serial, booking_id, arrival_date, arrival_time, guest_name,
--       father_husband_name, address, nationality, occupation,
--       coming_from, going_to, departure_date, room_number,
--       num_adults, num_children, id_proof_type, id_proof_number,
--       purpose, status, is_foreign }
--   ]
-- }
--
-- Fields we don't have on sbp_bookings (father's name, occupation,
-- coming_from, going_to) come back NULL — printed register has
-- handwriting space for the operator to fill in at desk.

CREATE OR REPLACE FUNCTION public.sbp_hotel_form_b_register(
  p_shop_id uuid,
  p_from    date,
  p_to      date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check  jsonb;
  v_shop   record;
  v_rows   jsonb;
  v_count  int;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_range_required');
  END IF;
  IF p_to < p_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date_range');
  END IF;

  -- Shop header (printed at top of register)
  SELECT * INTO v_shop FROM public.shops WHERE id = p_shop_id;

  -- Fetch bookings in the arrival window. INCLUDE every status
  -- except 'cancelled' — under Indian hotel law, the register
  -- captures ARRIVALS regardless of whether the guest later checked
  -- out, no-showed, or stayed longer.
  WITH ranked AS (
    SELECT
      ROW_NUMBER() OVER (ORDER BY b.check_in_date, b.created_at) AS serial,
      b.id                              AS booking_id,
      b.check_in_date                   AS arrival_date,
      to_char(b.checked_in_at AT TIME ZONE 'Asia/Kolkata', 'HH24:MI') AS arrival_time,
      b.customer_name                   AS guest_name,
      NULL::text                        AS father_husband_name,
      NULL::text                        AS address,
      COALESCE(b.guest_country, 'Indian') AS nationality,
      NULL::text                        AS occupation,
      NULL::text                        AS coming_from,
      NULL::text                        AS going_to,
      b.check_out_date                  AS departure_date,
      COALESCE(b.room_number_snapshot, r.room_number) AS room_number,
      b.num_adults,
      b.num_children,
      b.id_proof_type,
      b.id_proof_number,
      b.purpose_of_visit                AS purpose,
      b.status,
      COALESCE(b.is_foreign, false)     AS is_foreign,
      COALESCE(b.customer_phone, b.customer_wa) AS phone
    FROM public.sbp_bookings b
    LEFT JOIN public.sbp_rooms r ON r.id = b.room_id
    WHERE b.shop_id = p_shop_id
      AND b.check_in_date BETWEEN p_from AND p_to
      AND b.status <> 'cancelled'
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'serial',              serial,
      'booking_id',          booking_id,
      'arrival_date',        arrival_date,
      'arrival_time',        arrival_time,
      'guest_name',          guest_name,
      'father_husband_name', father_husband_name,
      'address',             address,
      'nationality',         nationality,
      'occupation',          occupation,
      'coming_from',         coming_from,
      'going_to',            going_to,
      'departure_date',      departure_date,
      'room_number',         room_number,
      'num_adults',          num_adults,
      'num_children',        num_children,
      'id_proof_type',       id_proof_type,
      'id_proof_number',     id_proof_number,
      'purpose',             purpose,
      'status',              status,
      'is_foreign',          is_foreign,
      'phone',               phone
    ) ORDER BY serial), '[]'::jsonb),
    COUNT(*)
  INTO v_rows, v_count
  FROM ranked;

  RETURN jsonb_build_object(
    'ok',     true,
    'shop',   jsonb_build_object(
      'name',   v_shop.name,
      'phone',  v_shop.phone,
      'gstin',  v_shop.gstin,
      'address', concat_ws(', ',
                  NULLIF(v_shop.address,''),
                  NULLIF(v_shop.city,''),
                  NULLIF(v_shop.state,''),
                  NULLIF(v_shop.pin,''))
    ),
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'total',  v_count,
    'rows',   v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_hotel_form_b_register(uuid, date, date) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 2. RPC: sbp_hotel_form_c_data
-- ──────────────────────────────────────────────────────────────────
--
-- Args:  p_shop_id uuid, p_from date, p_to date
-- Range: bookings with check_in_date BETWEEN p_from AND p_to,
--        is_foreign = true.
--
-- Returns:
-- {
--   ok: true,
--   shop: { name, address, gstin, phone, frro_id (nullable) },
--   period: { from, to },
--   total: N,
--   rows: [
--     { serial, booking_id, name, nationality, sex, dob,
--       passport_number, passport_place_issue, passport_date_issue,
--       passport_expiry, visa_number, visa_type, visa_date_issue,
--       visa_place_issue, visa_expiry,
--       arrival_in_india_date, place_of_arrival_in_india,
--       check_in_date, check_out_date,
--       address_abroad, next_address_in_india, purpose_of_visit,
--       email, phone, room_number, status }
--   ]
-- }
--
-- Fields we don't have (sex, DOB, passport place/date of issue,
-- visa place/date of issue, place of arrival in India) come back
-- NULL. Operator can fill in handwriting on printed Form C, or
-- supplement the CSV before FRRO portal upload.

CREATE OR REPLACE FUNCTION public.sbp_hotel_form_c_data(
  p_shop_id uuid,
  p_from    date,
  p_to      date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check  jsonb;
  v_shop   record;
  v_rows   jsonb;
  v_count  int;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_range_required');
  END IF;
  IF p_to < p_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date_range');
  END IF;

  SELECT * INTO v_shop FROM public.shops WHERE id = p_shop_id;

  WITH ranked AS (
    SELECT
      ROW_NUMBER() OVER (ORDER BY b.check_in_date, b.created_at) AS serial,
      b.id                                  AS booking_id,
      b.customer_name                       AS name,
      b.guest_country                       AS nationality,
      NULL::text                            AS sex,
      NULL::date                            AS dob,
      b.passport_number,
      NULL::text                            AS passport_place_issue,
      NULL::date                            AS passport_date_issue,
      b.passport_expiry,
      b.visa_number,
      b.visa_type,
      NULL::date                            AS visa_date_issue,
      NULL::text                            AS visa_place_issue,
      b.visa_expiry,
      b.arrival_in_india_date,
      NULL::text                            AS place_of_arrival_in_india,
      b.check_in_date,
      b.check_out_date,
      b.address_abroad,
      b.next_address_in_india,
      b.purpose_of_visit,
      b.customer_email                      AS email,
      COALESCE(b.customer_phone, b.customer_wa) AS phone,
      COALESCE(b.room_number_snapshot, r.room_number) AS room_number,
      b.status
    FROM public.sbp_bookings b
    LEFT JOIN public.sbp_rooms r ON r.id = b.room_id
    WHERE b.shop_id = p_shop_id
      AND b.check_in_date BETWEEN p_from AND p_to
      AND b.status <> 'cancelled'
      AND COALESCE(b.is_foreign, false) = true
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'serial',                     serial,
      'booking_id',                 booking_id,
      'name',                       name,
      'nationality',                nationality,
      'sex',                        sex,
      'dob',                        dob,
      'passport_number',            passport_number,
      'passport_place_issue',       passport_place_issue,
      'passport_date_issue',        passport_date_issue,
      'passport_expiry',            passport_expiry,
      'visa_number',                visa_number,
      'visa_type',                  visa_type,
      'visa_date_issue',            visa_date_issue,
      'visa_place_issue',           visa_place_issue,
      'visa_expiry',                visa_expiry,
      'arrival_in_india_date',      arrival_in_india_date,
      'place_of_arrival_in_india',  place_of_arrival_in_india,
      'check_in_date',              check_in_date,
      'check_out_date',             check_out_date,
      'address_abroad',             address_abroad,
      'next_address_in_india',      next_address_in_india,
      'purpose_of_visit',           purpose_of_visit,
      'email',                      email,
      'phone',                      phone,
      'room_number',                room_number,
      'status',                     status
    ) ORDER BY serial), '[]'::jsonb),
    COUNT(*)
  INTO v_rows, v_count
  FROM ranked;

  RETURN jsonb_build_object(
    'ok',     true,
    'shop',   jsonb_build_object(
      'name',   v_shop.name,
      'phone',  v_shop.phone,
      'gstin',  v_shop.gstin,
      'address', concat_ws(', ',
                  NULLIF(v_shop.address,''),
                  NULLIF(v_shop.city,''),
                  NULLIF(v_shop.state,''),
                  NULLIF(v_shop.pin,''))
    ),
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'total',  v_count,
    'rows',   v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_hotel_form_c_data(uuid, date, date) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 3. Module profile entry — surface compliance.html in the sidebar
-- ──────────────────────────────────────────────────────────────────

INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('hospitality', 'compliance', 'active', 'NEW', 175)
ON CONFLICT (profile, module_code) DO UPDATE
  SET status = EXCLUDED.status,
      badge  = EXCLUDED.badge,
      display_order = EXCLUDED.display_order;


-- ──────────────────────────────────────────────────────────────────
-- 4. Verification queries
-- ──────────────────────────────────────────────────────────────────

-- (1) Form B for last 30 days at Glitz & Glam:
--   SELECT public.sbp_hotel_form_b_register(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     CURRENT_DATE - INTERVAL '30 days',
--     CURRENT_DATE
--   );

-- (2) Form C foreign-only for last 90 days:
--   SELECT public.sbp_hotel_form_c_data(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     CURRENT_DATE - INTERVAL '90 days',
--     CURRENT_DATE
--   );

-- ──────────────── End of 027_hotel_compliance.sql ────────────────
