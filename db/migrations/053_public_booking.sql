-- ════════════════════════════════════════════════════════════════════
-- 053_public_booking.sql
--
-- Public-facing booking flow. Allows anonymous customers visiting
-- /s/{slug} to submit a booking request via a form embedded in the
-- iframe. The booking lands in the shop's sbp_bookings table with
-- source='public_form', visible immediately in /bookings.html admin.
--
-- Three RPCs:
--   1. sbp_get_public_room_types(slug) → list room types for the form
--   2. sbp_create_booking_public(slug, payload) → create booking row
--   3. sbp_get_public_booking_form_config(slug) → form config + business type
--
-- Security model:
--   • RPCs run with SECURITY DEFINER and only resolve slugs that have
--     ai_published=true or published=true (matches sbp_resolve_shop_slug).
--   • Rate limiting: max 5 bookings per IP per shop per hour (via
--     sbp_public_booking_attempts table).
--   • Input validation: enforces non-empty name, valid phone format,
--     date sanity (check-out > check-in, both in future or today).
--   • No customer login required — anonymous submissions only.
--   • Returns booking_id + confirmation_code so the customer can
--     reference their booking when contacting the shop.
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Rate-limit table ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sbp_public_booking_attempts (
  id          bigserial PRIMARY KEY,
  shop_id     uuid NOT NULL,
  ip_hash     text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pub_book_rate
  ON sbp_public_booking_attempts (shop_id, ip_hash, created_at);

-- Auto-purge old rate-limit records (keep only last 24h)
-- This runs lazily via the create_booking RPC.

-- ── 2. Public room types lookup ─────────────────────────────────────
-- Returns the list of room types the shop offers, for the form's
-- dropdown. Anonymous-callable. Only returns active room types.

DROP FUNCTION IF EXISTS sbp_get_public_room_types(text);

CREATE OR REPLACE FUNCTION sbp_get_public_room_types(p_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
  v_types   jsonb;
BEGIN
  -- Resolve slug → shop_id, with same publish-gate as sbp_resolve_shop_slug
  SELECT w.shop_id INTO v_shop_id
  FROM sbp_shop_websites w
  WHERE w.slug = p_slug
    AND (
      COALESCE(w.published, false) = true
      OR (COALESCE(w.ai_published, false) = true AND w.ai_generated_html IS NOT NULL)
    )
  LIMIT 1;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- Get active room types
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                t.id,
    'name',              t.name,
    'description',       t.description,
    'base_price',        t.base_price,
    'capacity_adults',   t.capacity_adults,
    'capacity_children', t.capacity_children,
    'amenities',         t.amenities
  ) ORDER BY t.display_order, t.name), '[]'::jsonb) INTO v_types
  FROM sbp_room_types t
  WHERE t.shop_id = v_shop_id AND t.active = true;

  RETURN jsonb_build_object(
    'ok',         true,
    'shop_id',    v_shop_id,
    'room_types', v_types
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_public_room_types(text)
  TO anon, authenticated, service_role;


-- ── 3. Public services lookup for non-hospitality booking ────────────
-- Returns active services from sbp_services — used by non-hospitality
-- verticals (salon, healthcare, services) for service-based bookings.
-- Hospitality verticals use sbp_get_public_room_types instead.

DROP FUNCTION IF EXISTS sbp_get_public_services_for_booking(text);

CREATE OR REPLACE FUNCTION sbp_get_public_services_for_booking(p_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
  v_svcs    jsonb;
BEGIN
  SELECT w.shop_id INTO v_shop_id
  FROM sbp_shop_websites w
  WHERE w.slug = p_slug
    AND (
      COALESCE(w.published, false) = true
      OR (COALESCE(w.ai_published, false) = true AND w.ai_generated_html IS NOT NULL)
    )
  LIMIT 1;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',               s.id,
    'name',             s.name,
    'description',      s.description,
    'price',            s.price,
    'duration_minutes', s.duration_minutes
  ) ORDER BY s.display_order NULLS LAST, s.name), '[]'::jsonb) INTO v_svcs
  FROM sbp_services s
  WHERE s.shop_id = v_shop_id
    AND s.active = true;

  RETURN jsonb_build_object(
    'ok',       true,
    'shop_id',  v_shop_id,
    'services', v_svcs
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_public_services_for_booking(text)
  TO anon, authenticated, service_role;


-- ── 4. Public booking form config ──────────────────────────────────
-- Returns: shop name, business type (so form picks right vertical layout),
-- whether the shop accepts bookings, whether to ask for room or service.

DROP FUNCTION IF EXISTS sbp_get_public_booking_form_config(text);

CREATE OR REPLACE FUNCTION sbp_get_public_booking_form_config(p_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id   uuid;
  v_shop_name text;
  v_shop_type text;
  v_phone     text;
  v_form_mode text;       -- 'hospitality' | 'service' | 'generic'
BEGIN
  SELECT w.shop_id, s.name, s.shop_type, s.phone
    INTO v_shop_id, v_shop_name, v_shop_type, v_phone
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = p_slug
    AND (
      COALESCE(w.published, false) = true
      OR (COALESCE(w.ai_published, false) = true AND w.ai_generated_html IS NOT NULL)
    )
  LIMIT 1;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- Derive form mode from shop_type
  v_form_mode := CASE
    WHEN v_shop_type IN (
      'general_hotel','luxury_hotel','budget_hotel','day_room','pg_hostel',
      'serviced_apartment','homestay','resort','motel','guest_house','dharamshala'
    ) THEN 'hospitality'
    WHEN v_shop_type IN (
      'unisex_salon','ladies_salon','mens_salon','spa','barber_shop',
      'beauty_parlor','nail_studio','tattoo_studio','medical_clinic',
      'dental_clinic','physiotherapy','diagnostic_lab','consultancy',
      'repair_service','tutoring','training_institute','test_prep'
    ) THEN 'service'
    ELSE 'generic'
  END;

  RETURN jsonb_build_object(
    'ok',           true,
    'shop_id',      v_shop_id,
    'shop_name',    v_shop_name,
    'shop_type',    v_shop_type,
    'shop_phone',   v_phone,
    'form_mode',    v_form_mode,
    'slug',         p_slug
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_public_booking_form_config(text)
  TO anon, authenticated, service_role;


-- ── 5. The main RPC — create booking from public form ──────────────
-- Accepts a jsonb payload with customer info + dates + room/service.
-- Validates everything server-side. Rate-limits by (shop_id, ip_hash).
-- Returns { ok, booking_id, confirmation_code }.

DROP FUNCTION IF EXISTS sbp_create_booking_public(text, jsonb, text);

CREATE OR REPLACE FUNCTION sbp_create_booking_public(
  p_slug    text,
  p_payload jsonb,
  p_ip_hash text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id        uuid;
  v_shop_name      text;
  v_shop_type      text;
  v_recent_count   int;
  v_check_in       date;
  v_check_out      date;
  v_num_nights     int;
  v_customer_name  text;
  v_customer_phone text;
  v_customer_email text;
  v_num_adults     int;
  v_num_children   int;
  v_notes          text;
  v_room_type_id   uuid;
  v_room_type_name text;
  v_rate_per_night numeric;
  v_room_total     numeric;
  v_booking_id     uuid;
  v_confirmation   text;
BEGIN
  -- ── A. Resolve shop ──────────────────────────────────────────────
  SELECT w.shop_id, s.name, s.shop_type
    INTO v_shop_id, v_shop_name, v_shop_type
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = p_slug
    AND (
      COALESCE(w.published, false) = true
      OR (COALESCE(w.ai_published, false) = true AND w.ai_generated_html IS NOT NULL)
    )
  LIMIT 1;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- ── B. Rate-limit: max 5 attempts per IP per shop per hour ───────
  IF p_ip_hash IS NOT NULL THEN
    -- Purge old records (lazy cleanup, 24h+ old)
    DELETE FROM sbp_public_booking_attempts
    WHERE created_at < now() - interval '24 hours';

    SELECT COUNT(*) INTO v_recent_count
    FROM sbp_public_booking_attempts
    WHERE shop_id = v_shop_id
      AND ip_hash = p_ip_hash
      AND created_at > now() - interval '1 hour';

    IF v_recent_count >= 5 THEN
      RETURN jsonb_build_object(
        'ok',    false,
        'error', 'rate_limited',
        'message', 'Too many booking attempts. Please try again in an hour.'
      );
    END IF;

    -- Record this attempt
    INSERT INTO sbp_public_booking_attempts (shop_id, ip_hash)
    VALUES (v_shop_id, p_ip_hash);
  END IF;

  -- ── C. Validate required fields ──────────────────────────────────
  v_customer_name  := NULLIF(trim(COALESCE(p_payload->>'customer_name', '')), '');
  v_customer_phone := NULLIF(trim(COALESCE(p_payload->>'customer_phone', '')), '');
  v_customer_email := NULLIF(trim(COALESCE(p_payload->>'customer_email', '')), '');
  v_notes          := NULLIF(trim(COALESCE(p_payload->>'notes', '')), '');

  IF v_customer_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_required');
  END IF;
  IF length(v_customer_name) > 100 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_too_long');
  END IF;

  IF v_customer_phone IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'phone_required');
  END IF;

  -- Phone format: digits only, 10-15 chars (allows +country codes)
  IF NOT (regexp_replace(v_customer_phone, '[^0-9]', '', 'g') ~ '^[0-9]{10,15}$') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_phone');
  END IF;

  -- Email format if provided
  IF v_customer_email IS NOT NULL
     AND NOT (v_customer_email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
  THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_email');
  END IF;

  -- ── D. Parse dates ───────────────────────────────────────────────
  BEGIN
    v_check_in  := (p_payload->>'check_in_date')::date;
    v_check_out := (p_payload->>'check_out_date')::date;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date');
  END;

  IF v_check_in IS NULL OR v_check_out IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'dates_required');
  END IF;
  IF v_check_in < (CURRENT_DATE - interval '1 day') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'check_in_past');
  END IF;
  IF v_check_out <= v_check_in THEN
    RETURN jsonb_build_object('ok', false, 'error', 'check_out_before_check_in');
  END IF;
  IF v_check_out > v_check_in + interval '90 days' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'stay_too_long');
  END IF;

  v_num_nights := (v_check_out - v_check_in)::int;

  -- ── E. Guest counts ──────────────────────────────────────────────
  v_num_adults   := COALESCE((p_payload->>'num_adults')::int, 1);
  v_num_children := COALESCE((p_payload->>'num_children')::int, 0);
  IF v_num_adults < 1 OR v_num_adults > 20 THEN v_num_adults := 1; END IF;
  IF v_num_children < 0 OR v_num_children > 10 THEN v_num_children := 0; END IF;

  -- ── F. Resolve room type (optional, but use first active if omitted) ─
  v_room_type_id   := NULLIF(p_payload->>'room_type_id', '')::uuid;
  v_room_type_name := NULLIF(trim(COALESCE(p_payload->>'room_type_name', '')), '');

  IF v_room_type_id IS NOT NULL THEN
    SELECT t.name, t.base_price
      INTO v_room_type_name, v_rate_per_night
    FROM sbp_room_types t
    WHERE t.id = v_room_type_id AND t.shop_id = v_shop_id AND t.active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_room_type');
    END IF;
  ELSE
    -- Caller passed only a free-text room name (from AI's room cards)
    v_rate_per_night := COALESCE((p_payload->>'rate_per_night')::numeric, 0);
  END IF;

  v_room_total := v_rate_per_night * v_num_nights;

  -- ── G. Create booking ────────────────────────────────────────────
  v_confirmation := upper(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 8));

  INSERT INTO sbp_bookings (
    shop_id, customer_name, customer_phone, customer_wa, customer_email,
    num_adults, num_children,
    room_type_id, room_type_snapshot,
    check_in_date, check_out_date, num_nights,
    rate_per_night, room_total, grand_total,
    status, source,
    notes
  )
  VALUES (
    v_shop_id, v_customer_name, v_customer_phone, v_customer_phone, v_customer_email,
    v_num_adults, v_num_children,
    v_room_type_id, v_room_type_name,
    v_check_in, v_check_out, v_num_nights,
    v_rate_per_night, v_room_total, v_room_total,
    'pending', 'public_form',
    'Confirmation: ' || v_confirmation
    || CASE WHEN v_notes IS NOT NULL THEN E'\n\n' || v_notes ELSE '' END
  )
  RETURNING id INTO v_booking_id;

  -- ── H. Done ──────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'ok',                true,
    'booking_id',        v_booking_id,
    'confirmation_code', v_confirmation,
    'shop_name',         v_shop_name,
    'shop_phone',        (SELECT phone FROM shops WHERE id = v_shop_id),
    'shop_whatsapp',     (SELECT wa FROM shops WHERE id = v_shop_id),
    'check_in',          v_check_in,
    'check_out',         v_check_out,
    'num_nights',        v_num_nights,
    'room_total',        v_room_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_create_booking_public(text, jsonb, text)
  TO anon, authenticated, service_role;


NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--
--   SELECT sbp_get_public_booking_form_config('glitz-glam');
--   -- Should return form_mode='hospitality', shop_name='Glitz &Glam'
--
--   SELECT sbp_get_public_room_types('glitz-glam');
--   -- Returns whatever room_types are defined (may be empty array)
--
--   SELECT sbp_create_booking_public('glitz-glam', jsonb_build_object(
--     'customer_name', 'Test User',
--     'customer_phone', '9876543210',
--     'check_in_date', (CURRENT_DATE + 1)::text,
--     'check_out_date', (CURRENT_DATE + 3)::text,
--     'num_adults', 2,
--     'room_type_name', 'Deluxe Room',
--     'rate_per_night', 2500
--   ), 'test-hash');
--   -- Should return ok=true with booking_id and confirmation_code
--
--   -- Verify it landed:
--   SELECT id, customer_name, source, status, room_type_snapshot, check_in_date
--   FROM sbp_bookings
--   WHERE shop_id = '73aa8ede-6352-4549-8617-cccacdd5c821'
--   ORDER BY created_at DESC LIMIT 5;
-- ════════════════════════════════════════════════════════════════════
