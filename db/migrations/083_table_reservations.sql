-- ════════════════════════════════════════════════════════════════════
-- 083_table_reservations.sql
-- Restaurant TABLE reservations (distinct from 053 hotel room-night booking).
--
-- Design (from research doc + deep-dive):
--   • 053_public_booking.sql is HOTEL-only (check_in/out/nights/room_type).
--     We REUSE its proven scaffolding (slug→shop resolution via
--     sbp_shop_websites, sbp_public_booking_attempts rate-limit, anon
--     SECURITY DEFINER, jsonb {ok,error} envelope) but write to a NEW,
--     purpose-built table — NOT shoehorned into sbp_bookings.
--   • API-first: all logic server-side, jsonb envelope, owner checks.
--   • Status lifecycle: pending → confirmed → seated | no_show | cancelled
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Reservations table ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sbp_table_reservations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id          uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  table_id         uuid REFERENCES sbp_restaurant_tables(id) ON DELETE SET NULL,
  party_size       int  NOT NULL CHECK (party_size > 0 AND party_size <= 100),
  reservation_date date NOT NULL,
  time_slot        time NOT NULL,
  duration_min     int  NOT NULL DEFAULT 90 CHECK (duration_min BETWEEN 15 AND 600),
  customer_name    text NOT NULL,
  customer_phone   text NOT NULL,
  customer_email   text,
  notes            text,
  status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','confirmed','seated','no_show','cancelled')),
  source           text NOT NULL DEFAULT 'staff'
                     CHECK (source IN ('staff','online')),
  confirmation_code text,
  created_by       uuid,
  confirmed_by     uuid,
  confirmed_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sbp_table_res_shop_date
  ON sbp_table_reservations(shop_id, reservation_date, time_slot);
CREATE INDEX IF NOT EXISTS idx_sbp_table_res_status
  ON sbp_table_reservations(shop_id, status);

ALTER TABLE sbp_table_reservations ENABLE ROW LEVEL SECURITY;

-- Owner-scoped RLS (mirrors platform pattern; public writes go via SECURITY DEFINER RPC)
DROP POLICY IF EXISTS p_table_res_owner ON sbp_table_reservations;
CREATE POLICY p_table_res_owner ON sbp_table_reservations
  FOR ALL USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
  );

-- ── 2. PUBLIC create (customer books from website) ──────────────────
-- Reuses 053's slug-resolution + sbp_public_booking_attempts rate-limit.
DROP FUNCTION IF EXISTS sbp_create_table_reservation_public(text, jsonb, text);
CREATE OR REPLACE FUNCTION sbp_create_table_reservation_public(
  p_slug    text,
  p_payload jsonb,
  p_ip_hash text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id        uuid;
  v_recent_count   int;
  v_name           text;
  v_phone          text;
  v_email          text;
  v_party          int;
  v_date           date;
  v_time           time;
  v_notes          text;
  v_res_id         uuid;
  v_code           text;
BEGIN
  -- Resolve shop from published website slug (verbatim pattern from 053)
  SELECT w.shop_id INTO v_shop_id
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = p_slug
    AND ( COALESCE(w.published,false)=true
       OR (COALESCE(w.ai_published,false)=true AND w.ai_generated_html IS NOT NULL) )
  LIMIT 1;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- Rate-limit: max 5 attempts / hour / ip_hash (reuse 053's attempts table)
  IF p_ip_hash IS NOT NULL THEN
    SELECT count(*) INTO v_recent_count
    FROM sbp_public_booking_attempts
    WHERE shop_id = v_shop_id AND ip_hash = p_ip_hash
      AND created_at > now() - interval '1 hour';
    IF v_recent_count >= 5 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'rate_limited');
    END IF;
    INSERT INTO sbp_public_booking_attempts(shop_id, ip_hash)
    VALUES (v_shop_id, p_ip_hash);
  END IF;

  -- Validate payload
  v_name  := nullif(trim(p_payload->>'name'), '');
  v_phone := nullif(trim(p_payload->>'phone'), '');
  v_email := nullif(trim(p_payload->>'email'), '');
  v_party := COALESCE((p_payload->>'party_size')::int, 0);
  v_date  := (p_payload->>'date')::date;
  v_time  := (p_payload->>'time')::time;
  v_notes := nullif(trim(p_payload->>'notes'), '');

  IF v_name IS NULL OR length(v_name) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_name');
  END IF;
  IF v_phone IS NULL OR v_phone !~ '^[0-9+][0-9 -]{6,15}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_phone');
  END IF;
  IF v_party < 1 OR v_party > 100 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_party_size');
  END IF;
  IF v_date IS NULL OR v_date < current_date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date');
  END IF;
  IF v_time IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_time');
  END IF;

  v_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));

  INSERT INTO sbp_table_reservations(
    shop_id, party_size, reservation_date, time_slot,
    customer_name, customer_phone, customer_email, notes,
    status, source, confirmation_code
  ) VALUES (
    v_shop_id, v_party, v_date, v_time,
    v_name, v_phone, v_email, v_notes,
    'pending', 'online', v_code
  ) RETURNING id INTO v_res_id;

  RETURN jsonb_build_object(
    'ok', true,
    'reservation_id', v_res_id,
    'confirmation_code', v_code,
    'status', 'pending'
  );
END;
$$;

-- ── 3. STAFF: list reservations (owner-scoped) ──────────────────────
DROP FUNCTION IF EXISTS sbp_reservations_list(date, date);
CREATE OR REPLACE FUNCTION sbp_reservations_list(
  p_from date DEFAULT current_date,
  p_to   date DEFAULT current_date + 30
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
  v_rows    jsonb;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.reservation_date, r.time_slot), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT tr.*,
           rt.table_number
    FROM sbp_table_reservations tr
    LEFT JOIN sbp_restaurant_tables rt ON rt.id = tr.table_id
    WHERE tr.shop_id = v_shop_id
      AND tr.reservation_date BETWEEN p_from AND p_to
  ) r;

  RETURN jsonb_build_object('ok', true, 'reservations', v_rows);
END;
$$;

-- ── 4. STAFF: one-click confirm + assign table ─────────────────────
DROP FUNCTION IF EXISTS sbp_reservation_confirm(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_reservation_confirm(
  p_reservation_id uuid,
  p_table_id       uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
  v_res     sbp_table_reservations%ROWTYPE;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop');
  END IF;

  SELECT * INTO v_res FROM sbp_table_reservations
  WHERE id = p_reservation_id AND shop_id = v_shop_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;

  -- If a table is supplied, validate it belongs to this shop
  IF p_table_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM sbp_restaurant_tables
                   WHERE id = p_table_id AND shop_id = v_shop_id) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_table');
    END IF;
  END IF;

  UPDATE sbp_table_reservations
  SET status       = 'confirmed',
      table_id     = COALESCE(p_table_id, table_id),
      confirmed_by = auth.uid(),
      confirmed_at = now(),
      updated_at   = now()
  WHERE id = p_reservation_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', p_reservation_id,
                            'status', 'confirmed');
END;
$$;

-- ── 5. STAFF: set status (seated / no_show / cancelled) ─────────────
DROP FUNCTION IF EXISTS sbp_reservation_set_status(uuid, text);
CREATE OR REPLACE FUNCTION sbp_reservation_set_status(
  p_reservation_id uuid,
  p_status         text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
BEGIN
  IF p_status NOT IN ('pending','confirmed','seated','no_show','cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop');
  END IF;

  UPDATE sbp_table_reservations
  SET status = p_status, updated_at = now()
  WHERE id = p_reservation_id AND shop_id = v_shop_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found');
  END IF;
  RETURN jsonb_build_object('ok', true, 'status', p_status);
END;
$$;

-- ── 6. STAFF: create reservation directly (phone/walk-in) ──────────
DROP FUNCTION IF EXISTS sbp_reservation_create_staff(jsonb);
CREATE OR REPLACE FUNCTION sbp_reservation_create_staff(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
  v_res_id  uuid;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop');
  END IF;

  IF nullif(trim(p_payload->>'name'),'') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_name');
  END IF;
  IF (p_payload->>'date')::date < current_date THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date');
  END IF;

  INSERT INTO sbp_table_reservations(
    shop_id, table_id, party_size, reservation_date, time_slot,
    customer_name, customer_phone, customer_email, notes,
    status, source, created_by
  ) VALUES (
    v_shop_id,
    nullif(p_payload->>'table_id','')::uuid,
    COALESCE((p_payload->>'party_size')::int, 2),
    (p_payload->>'date')::date,
    (p_payload->>'time')::time,
    trim(p_payload->>'name'),
    nullif(trim(p_payload->>'phone'),''),
    nullif(trim(p_payload->>'email'),''),
    nullif(trim(p_payload->>'notes'),''),
    'confirmed', 'staff', auth.uid()
  ) RETURNING id INTO v_res_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id,
                            'status', 'confirmed');
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
