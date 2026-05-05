-- ════════════════════════════════════════════════════════════════════
-- 011_appointments.sql
-- Universal Appointments (Layer 2 universal add-on per Master Plan §6.1)
--
-- Closes salon, spa, gym, yoga, clinic, dentist, vet, coaching,
-- photographer, plumber, mover, tailor + ~30 verticals to ~95% complete.
--
-- Plan gating: BUSINESS-tier only (per locked decision May 5 2026).
-- Pro / Free shops cannot use appointments. Server-side enforced.
--
-- API-FIRST DESIGN (per locked rule):
--   - All logic in PLpgSQL RPCs
--   - jsonb {ok, error, ...data} envelope, stable error codes
--   - SECURITY DEFINER + auth.uid() ownership checks on admin RPCs
--   - 3 PUBLIC STOREFRONT RPCs (anon-callable):
--       sbp_get_appointment_config_public(slug)
--       sbp_get_available_slots_public(slug, ...)
--       sbp_book_appointment_public(slug, ...)
--   - Powers /s/[slug] booking flow + future external/AI website builders
--
-- Prerequisite: 010_service_catalog.sql must run first (sbp_services FK).
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Tables ──────────────────────────────────────────────────────────

-- 1a. Providers (the people/resources being booked: stylist, doctor, instructor)
CREATE TABLE IF NOT EXISTS sbp_appointment_providers (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id                uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  name                   text NOT NULL CHECK (length(trim(name)) > 0),
  role                   text,                      -- "Stylist", "Doctor", "Instructor"
  phone                  text,
  email                  text,
  photo_url              text,
  bio                    text,
  -- Availability (simple model: working days + daily hours)
  working_days           smallint[] NOT NULL DEFAULT ARRAY[1,2,3,4,5,6]::smallint[],  -- Mon-Sat default (0=Sun..6=Sat)
  work_start_time        time NOT NULL DEFAULT '09:00',
  work_end_time          time NOT NULL DEFAULT '18:00',
  slot_interval_minutes  int NOT NULL DEFAULT 30  CHECK (slot_interval_minutes BETWEEN 5 AND 240),
  buffer_minutes         int NOT NULL DEFAULT 0   CHECK (buffer_minutes BETWEEN 0 AND 120),
  active                 boolean NOT NULL DEFAULT true,
  display_order          int NOT NULL DEFAULT 0,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CHECK (work_start_time < work_end_time)
);

-- 1b. One-off date blocks (vacation, sickness, holidays, lunch override)
CREATE TABLE IF NOT EXISTS sbp_provider_blocks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id   uuid NOT NULL REFERENCES sbp_appointment_providers(id) ON DELETE CASCADE,
  block_date    date NOT NULL,
  start_time    time,                  -- NULL = whole day blocked
  end_time      time,
  reason        text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (start_time IS NULL AND end_time IS NULL) OR
    (start_time IS NOT NULL AND end_time IS NOT NULL AND start_time < end_time)
  )
);

-- 1c. Appointments (the bookings)
CREATE TABLE IF NOT EXISTS sbp_appointments (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id                  uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  provider_id              uuid NOT NULL REFERENCES sbp_appointment_providers(id) ON DELETE RESTRICT,
  service_id               uuid REFERENCES sbp_services(id) ON DELETE SET NULL,  -- nullable: walk-in / generic
  customer_id              uuid REFERENCES customers(id) ON DELETE SET NULL,     -- nullable: non-saved customer
  customer_name            text NOT NULL CHECK (length(trim(customer_name)) > 0),
  customer_phone           text,
  customer_wa              text,
  starts_at                timestamptz NOT NULL,
  ends_at                  timestamptz NOT NULL,
  duration_minutes         int NOT NULL CHECK (duration_minutes > 0),
  service_name_snapshot    text,        -- snapshot at booking time (in case service is later deleted)
  service_price_snapshot   numeric,
  status                   text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','confirmed','completed','cancelled','no_show')),
  notes                    text,        -- public-facing (from customer)
  internal_notes           text,        -- admin-only
  bill_id                  uuid REFERENCES bills(id) ON DELETE SET NULL,  -- linked when bill created
  source                   text NOT NULL DEFAULT 'admin'
    CHECK (source IN ('admin','public_form','whatsapp','walk_in')),
  reminder_sent_at         timestamptz,
  cancelled_at             timestamptz,
  cancelled_reason         text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);

-- ── 2. Indexes ─────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_appt_providers_shop_active
  ON sbp_appointment_providers(shop_id, active, display_order)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_provider_blocks_provider_date
  ON sbp_provider_blocks(provider_id, block_date);

CREATE INDEX IF NOT EXISTS idx_appointments_shop_starts
  ON sbp_appointments(shop_id, starts_at DESC);

CREATE INDEX IF NOT EXISTS idx_appointments_provider_starts
  ON sbp_appointments(provider_id, starts_at)
  WHERE status IN ('pending','confirmed');

CREATE INDEX IF NOT EXISTS idx_appointments_status
  ON sbp_appointments(shop_id, status, starts_at);

CREATE INDEX IF NOT EXISTS idx_appointments_customer
  ON sbp_appointments(customer_id) WHERE customer_id IS NOT NULL;

-- ── 3. Updated_at triggers ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_appt_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appt_providers_updated ON sbp_appointment_providers;
CREATE TRIGGER trg_appt_providers_updated
  BEFORE UPDATE ON sbp_appointment_providers
  FOR EACH ROW EXECUTE FUNCTION sbp_appt_set_updated_at();

DROP TRIGGER IF EXISTS trg_appointments_updated ON sbp_appointments;
CREATE TRIGGER trg_appointments_updated
  BEFORE UPDATE ON sbp_appointments
  FOR EACH ROW EXECUTE FUNCTION sbp_appt_set_updated_at();

-- ── 4. RLS policies ────────────────────────────────────────────────────

ALTER TABLE sbp_appointment_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE sbp_provider_blocks       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sbp_appointments          ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_appt_providers_owner ON sbp_appointment_providers;
CREATE POLICY p_appt_providers_owner ON sbp_appointment_providers
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

DROP POLICY IF EXISTS p_provider_blocks_owner ON sbp_provider_blocks;
CREATE POLICY p_provider_blocks_owner ON sbp_provider_blocks
  FOR ALL TO authenticated
  USING (provider_id IN (
    SELECT id FROM sbp_appointment_providers
    WHERE shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
  ))
  WITH CHECK (provider_id IN (
    SELECT id FROM sbp_appointment_providers
    WHERE shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
  ));

DROP POLICY IF EXISTS p_appointments_owner ON sbp_appointments;
CREATE POLICY p_appointments_owner ON sbp_appointments
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

-- ── 5. Helper: verify Business plan + ownership ────────────────────────

CREATE OR REPLACE FUNCTION sbp_check_business_owner(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_plan text;
  v_expires timestamptz;
  v_owner uuid;
BEGIN
  SELECT plan, plan_expires_at, owner_id
  INTO v_plan, v_expires, v_owner
  FROM shops WHERE id = p_shop_id;

  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  IF v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Honor plan expiry
  IF v_expires IS NOT NULL AND v_expires < now() THEN
    v_plan := 'free';
  END IF;

  IF v_plan IS NULL OR v_plan NOT IN ('business','enterprise') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'business_plan_required');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── 6. ADMIN RPCs — Providers ──────────────────────────────────────────

-- 6a. List providers
CREATE OR REPLACE FUNCTION sbp_appt_providers_list(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_rows jsonb;
BEGIN
  v_check := sbp_check_business_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN
    RETURN v_check;
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_jsonb(p) ORDER BY p.display_order, p.created_at), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, name, role, phone, email, photo_url, bio,
           working_days, work_start_time::text, work_end_time::text,
           slot_interval_minutes, buffer_minutes, active, display_order
    FROM sbp_appointment_providers
    WHERE shop_id = p_shop_id
    ORDER BY display_order, created_at
  ) p;

  RETURN jsonb_build_object('ok', true, 'providers', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appt_providers_list(uuid) TO authenticated;

-- 6b. Upsert provider (create new or update existing)
CREATE OR REPLACE FUNCTION sbp_appt_providers_upsert(
  p_shop_id     uuid,
  p_provider_id uuid,         -- NULL to create, UUID to update
  p_data        jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_id uuid;
  v_max_order int;
  v_name text;
BEGIN
  v_check := sbp_check_business_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_name := trim(coalesce(p_data->>'name', ''));
  IF length(v_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_required');
  END IF;

  IF p_provider_id IS NULL THEN
    -- CREATE
    SELECT COALESCE(MAX(display_order), -1) + 1 INTO v_max_order
    FROM sbp_appointment_providers WHERE shop_id = p_shop_id;

    INSERT INTO sbp_appointment_providers(
      shop_id, name, role, phone, email, photo_url, bio,
      working_days, work_start_time, work_end_time,
      slot_interval_minutes, buffer_minutes, active, display_order
    ) VALUES (
      p_shop_id, v_name,
      NULLIF(trim(coalesce(p_data->>'role',''))     , ''),
      NULLIF(trim(coalesce(p_data->>'phone',''))    , ''),
      NULLIF(trim(coalesce(p_data->>'email',''))    , ''),
      NULLIF(trim(coalesce(p_data->>'photo_url','')), ''),
      NULLIF(trim(coalesce(p_data->>'bio',''))      , ''),
      COALESCE(
        (SELECT array_agg(value::smallint) FROM jsonb_array_elements_text(p_data->'working_days')),
        ARRAY[1,2,3,4,5,6]::smallint[]
      ),
      COALESCE((p_data->>'work_start_time')::time, '09:00'::time),
      COALESCE((p_data->>'work_end_time')::time, '18:00'::time),
      COALESCE((p_data->>'slot_interval_minutes')::int, 30),
      COALESCE((p_data->>'buffer_minutes')::int, 0),
      COALESCE((p_data->>'active')::boolean, true),
      COALESCE((p_data->>'display_order')::int, v_max_order)
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'id', v_id, 'created', true);
  ELSE
    -- UPDATE
    -- Verify provider belongs to this shop
    IF NOT EXISTS (SELECT 1 FROM sbp_appointment_providers WHERE id = p_provider_id AND shop_id = p_shop_id) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'not_found');
    END IF;

    UPDATE sbp_appointment_providers SET
      name             = v_name,
      role             = CASE WHEN p_data ? 'role'      THEN NULLIF(trim(p_data->>'role'),'')      ELSE role      END,
      phone            = CASE WHEN p_data ? 'phone'     THEN NULLIF(trim(p_data->>'phone'),'')     ELSE phone     END,
      email            = CASE WHEN p_data ? 'email'     THEN NULLIF(trim(p_data->>'email'),'')     ELSE email     END,
      photo_url        = CASE WHEN p_data ? 'photo_url' THEN NULLIF(trim(p_data->>'photo_url'),'') ELSE photo_url END,
      bio              = CASE WHEN p_data ? 'bio'       THEN NULLIF(trim(p_data->>'bio'),'')       ELSE bio       END,
      working_days     = CASE WHEN p_data ? 'working_days'
                              THEN COALESCE(
                                (SELECT array_agg(value::smallint) FROM jsonb_array_elements_text(p_data->'working_days')),
                                working_days
                              )
                              ELSE working_days END,
      work_start_time  = COALESCE((p_data->>'work_start_time')::time, work_start_time),
      work_end_time    = COALESCE((p_data->>'work_end_time')::time, work_end_time),
      slot_interval_minutes = COALESCE((p_data->>'slot_interval_minutes')::int, slot_interval_minutes),
      buffer_minutes   = COALESCE((p_data->>'buffer_minutes')::int, buffer_minutes),
      active           = COALESCE((p_data->>'active')::boolean, active),
      display_order    = COALESCE((p_data->>'display_order')::int, display_order)
    WHERE id = p_provider_id;

    RETURN jsonb_build_object('ok', true, 'id', p_provider_id, 'created', false);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appt_providers_upsert(uuid, uuid, jsonb) TO authenticated;

-- 6c. Delete provider
CREATE OR REPLACE FUNCTION sbp_appt_providers_delete(p_provider_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_check jsonb;
  v_active_appts int;
BEGIN
  SELECT shop_id INTO v_shop_id FROM sbp_appointment_providers WHERE id = p_provider_id;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_check := sbp_check_business_owner(v_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Block deletion if there are pending/confirmed appointments
  SELECT count(*) INTO v_active_appts
  FROM sbp_appointments
  WHERE provider_id = p_provider_id
    AND status IN ('pending','confirmed')
    AND starts_at >= now();

  IF v_active_appts > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'has_active_appointments',
                              'count', v_active_appts);
  END IF;

  DELETE FROM sbp_appointment_providers WHERE id = p_provider_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appt_providers_delete(uuid) TO authenticated;

-- ── 7. ADMIN RPCs — Blocks ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_appt_block_create(
  p_provider_id uuid,
  p_date date,
  p_start_time time,        -- NULL = full day
  p_end_time time,
  p_reason text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_check jsonb;
  v_id uuid;
BEGIN
  SELECT shop_id INTO v_shop_id FROM sbp_appointment_providers WHERE id = p_provider_id;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'provider_not_found');
  END IF;

  v_check := sbp_check_business_owner(v_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  IF p_date IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'date_required');
  END IF;

  IF (p_start_time IS NULL) <> (p_end_time IS NULL) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'partial_time_invalid');
  END IF;

  IF p_start_time IS NOT NULL AND p_end_time <= p_start_time THEN
    RETURN jsonb_build_object('ok', false, 'error', 'end_before_start');
  END IF;

  INSERT INTO sbp_provider_blocks(provider_id, block_date, start_time, end_time, reason)
  VALUES (p_provider_id, p_date, p_start_time, p_end_time, NULLIF(trim(coalesce(p_reason,'')),''))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appt_block_create(uuid, date, time, time, text) TO authenticated;

CREATE OR REPLACE FUNCTION sbp_appt_block_delete(p_block_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_check jsonb;
BEGIN
  SELECT p.shop_id INTO v_shop_id
  FROM sbp_provider_blocks b
  JOIN sbp_appointment_providers p ON p.id = b.provider_id
  WHERE b.id = p_block_id;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_check := sbp_check_business_owner(v_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  DELETE FROM sbp_provider_blocks WHERE id = p_block_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appt_block_delete(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION sbp_appt_blocks_list(
  p_provider_id uuid,
  p_from        date,
  p_to          date
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_check jsonb;
  v_rows jsonb;
BEGIN
  SELECT shop_id INTO v_shop_id FROM sbp_appointment_providers WHERE id = p_provider_id;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'provider_not_found');
  END IF;

  v_check := sbp_check_business_owner(v_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COALESCE(jsonb_agg(row_to_jsonb(b) ORDER BY b.block_date), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, block_date, start_time::text, end_time::text, reason, created_at
    FROM sbp_provider_blocks
    WHERE provider_id = p_provider_id
      AND (p_from IS NULL OR block_date >= p_from)
      AND (p_to IS NULL OR block_date <= p_to)
    ORDER BY block_date
  ) b;

  RETURN jsonb_build_object('ok', true, 'blocks', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appt_blocks_list(uuid, date, date) TO authenticated;

-- ── 8. ADMIN RPCs — Appointments ──────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_appointments_list(
  p_shop_id     uuid,
  p_from        timestamptz,
  p_to          timestamptz,
  p_provider_id uuid DEFAULT NULL,
  p_status      text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_rows jsonb;
BEGIN
  v_check := sbp_check_business_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COALESCE(jsonb_agg(row_to_jsonb(a) ORDER BY a.starts_at), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      ap.id, ap.starts_at, ap.ends_at, ap.duration_minutes,
      ap.customer_name, ap.customer_phone, ap.customer_wa, ap.customer_id,
      ap.service_id, ap.service_name_snapshot, ap.service_price_snapshot,
      ap.provider_id, ap.status, ap.notes, ap.internal_notes,
      ap.bill_id, ap.source, ap.created_at,
      pr.name AS provider_name, pr.role AS provider_role
    FROM sbp_appointments ap
    LEFT JOIN sbp_appointment_providers pr ON pr.id = ap.provider_id
    WHERE ap.shop_id = p_shop_id
      AND (p_from IS NULL OR ap.starts_at >= p_from)
      AND (p_to IS NULL OR ap.starts_at <= p_to)
      AND (p_provider_id IS NULL OR ap.provider_id = p_provider_id)
      AND (p_status IS NULL OR ap.status = p_status)
    ORDER BY ap.starts_at
    LIMIT 500
  ) a;

  RETURN jsonb_build_object('ok', true, 'appointments', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appointments_list(uuid, timestamptz, timestamptz, uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION sbp_appointments_create(
  p_shop_id uuid,
  p_data    jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_id uuid;
  v_provider_id uuid;
  v_starts timestamptz;
  v_duration int;
  v_service_id uuid;
  v_service_name text;
  v_service_price numeric;
  v_customer_name text;
BEGIN
  v_check := sbp_check_business_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_provider_id := (p_data->>'provider_id')::uuid;
  IF v_provider_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'provider_required');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM sbp_appointment_providers WHERE id = v_provider_id AND shop_id = p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'provider_not_found_or_other_shop');
  END IF;

  v_starts := (p_data->>'starts_at')::timestamptz;
  IF v_starts IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'starts_at_required');
  END IF;

  v_duration := COALESCE((p_data->>'duration_minutes')::int, 30);
  IF v_duration <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_duration');
  END IF;

  v_customer_name := trim(coalesce(p_data->>'customer_name', ''));
  IF length(v_customer_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_name_required');
  END IF;

  -- Snapshot service info if service_id given
  v_service_id := (p_data->>'service_id')::uuid;
  IF v_service_id IS NOT NULL THEN
    SELECT name, price INTO v_service_name, v_service_price
    FROM sbp_services WHERE id = v_service_id AND shop_id = p_shop_id;
    -- If service_id was provided but doesn't belong to this shop, ignore
    IF v_service_name IS NULL THEN
      v_service_id := NULL;
    END IF;
  END IF;

  INSERT INTO sbp_appointments(
    shop_id, provider_id, service_id,
    customer_id, customer_name, customer_phone, customer_wa,
    starts_at, ends_at, duration_minutes,
    service_name_snapshot, service_price_snapshot,
    status, notes, internal_notes, source
  ) VALUES (
    p_shop_id, v_provider_id, v_service_id,
    NULLIF(p_data->>'customer_id','')::uuid,
    v_customer_name,
    NULLIF(trim(coalesce(p_data->>'customer_phone','')), ''),
    NULLIF(trim(coalesce(p_data->>'customer_wa','')), ''),
    v_starts,
    v_starts + (v_duration || ' minutes')::interval,
    v_duration,
    v_service_name,
    v_service_price,
    COALESCE(NULLIF(trim(p_data->>'status'), ''), 'confirmed'),  -- admin-created defaults to confirmed
    NULLIF(trim(coalesce(p_data->>'notes','')), ''),
    NULLIF(trim(coalesce(p_data->>'internal_notes','')), ''),
    COALESCE(NULLIF(trim(p_data->>'source'), ''), 'admin')
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appointments_create(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION sbp_appointments_update(
  p_appt_id uuid,
  p_patch   jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_check jsonb;
  v_new_starts timestamptz;
  v_new_duration int;
BEGIN
  SELECT shop_id INTO v_shop_id FROM sbp_appointments WHERE id = p_appt_id;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_check := sbp_check_business_owner(v_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'patch_must_be_object');
  END IF;

  -- If starts_at or duration changes, recompute ends_at
  v_new_starts := COALESCE((p_patch->>'starts_at')::timestamptz,
                           (SELECT starts_at FROM sbp_appointments WHERE id = p_appt_id));
  v_new_duration := COALESCE((p_patch->>'duration_minutes')::int,
                              (SELECT duration_minutes FROM sbp_appointments WHERE id = p_appt_id));

  UPDATE sbp_appointments SET
    customer_name    = CASE WHEN p_patch ? 'customer_name'  THEN NULLIF(trim(p_patch->>'customer_name'),'')  ELSE customer_name  END,
    customer_phone   = CASE WHEN p_patch ? 'customer_phone' THEN NULLIF(trim(p_patch->>'customer_phone'),'') ELSE customer_phone END,
    customer_wa      = CASE WHEN p_patch ? 'customer_wa'    THEN NULLIF(trim(p_patch->>'customer_wa'),'')    ELSE customer_wa    END,
    starts_at        = v_new_starts,
    duration_minutes = v_new_duration,
    ends_at          = v_new_starts + (v_new_duration || ' minutes')::interval,
    notes            = CASE WHEN p_patch ? 'notes'          THEN NULLIF(trim(p_patch->>'notes'),'')          ELSE notes          END,
    internal_notes   = CASE WHEN p_patch ? 'internal_notes' THEN NULLIF(trim(p_patch->>'internal_notes'),'') ELSE internal_notes END
  WHERE id = p_appt_id
    AND COALESCE(NULLIF(trim(p_patch->>'customer_name'),''), customer_name) IS NOT NULL;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appointments_update(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION sbp_appointments_set_status(
  p_appt_id  uuid,
  p_status   text,
  p_reason   text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_check jsonb;
BEGIN
  IF p_status NOT IN ('pending','confirmed','completed','cancelled','no_show') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status');
  END IF;

  SELECT shop_id INTO v_shop_id FROM sbp_appointments WHERE id = p_appt_id;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_check := sbp_check_business_owner(v_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  UPDATE sbp_appointments SET
    status = p_status,
    cancelled_at = CASE WHEN p_status = 'cancelled' THEN now() ELSE cancelled_at END,
    cancelled_reason = CASE WHEN p_status = 'cancelled' THEN NULLIF(trim(coalesce(p_reason,'')),'') ELSE cancelled_reason END
  WHERE id = p_appt_id;

  RETURN jsonb_build_object('ok', true, 'status', p_status);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_appointments_set_status(uuid, text, text) TO authenticated;

-- ── 9. PUBLIC STOREFRONT RPCs (anon) ───────────────────────────────────

-- 9a. Get appointment configuration for a shop (by slug)
-- Returns: enabled flag, providers, services bookable
CREATE OR REPLACE FUNCTION sbp_get_appointment_config_public(p_slug text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_published boolean;
  v_plan text;
  v_expires timestamptz;
  v_clean text;
  v_providers jsonb;
  v_services jsonb;
BEGIN
  v_clean := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_slug', 'enabled', false);
  END IF;

  -- Resolve slug → shop_id + plan
  SELECT w.shop_id, w.published, s.plan, s.plan_expires_at
  INTO v_shop_id, v_published, v_plan, v_expires
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = v_clean;

  IF v_shop_id IS NULL OR NOT v_published THEN
    RETURN jsonb_build_object('ok', true, 'enabled', false);
  END IF;

  -- Honor plan expiry
  IF v_expires IS NOT NULL AND v_expires < now() THEN v_plan := 'free'; END IF;

  -- Appointments are Business-only
  IF v_plan NOT IN ('business','enterprise') THEN
    RETURN jsonb_build_object('ok', true, 'enabled', false);
  END IF;

  -- Providers (active only, public-safe columns)
  SELECT COALESCE(jsonb_agg(row_to_jsonb(p) ORDER BY p.display_order), '[]'::jsonb)
  INTO v_providers
  FROM (
    SELECT id, name, role, photo_url, bio, working_days,
           work_start_time::text, work_end_time::text,
           slot_interval_minutes
    FROM sbp_appointment_providers
    WHERE shop_id = v_shop_id AND active = true
    ORDER BY display_order
  ) p;

  -- Services bookable (active only, with duration > 0)
  SELECT COALESCE(jsonb_agg(row_to_jsonb(s) ORDER BY s.display_order), '[]'::jsonb)
  INTO v_services
  FROM (
    SELECT id, name, description, category, price, duration_minutes, image_url
    FROM sbp_services
    WHERE shop_id = v_shop_id AND active = true
    ORDER BY display_order
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', (jsonb_array_length(v_providers) > 0),
    'providers', v_providers,
    'services', v_services
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_appointment_config_public(text) TO anon;
GRANT EXECUTE ON FUNCTION sbp_get_appointment_config_public(text) TO authenticated;

-- 9b. Compute available slots for a provider on a date for a given duration
-- This is the heavy lifter — used by the public booking flow
CREATE OR REPLACE FUNCTION sbp_get_available_slots_public(
  p_slug         text,
  p_provider_id  uuid,
  p_date         date,
  p_duration_minutes int
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_published boolean;
  v_plan text;
  v_expires timestamptz;
  v_clean text;
  v_provider record;
  v_dow smallint;
  v_now timestamptz := now();
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_cursor timestamptz;
  v_slot_end timestamptz;
  v_slot_step interval;
  v_duration interval;
  v_buffer interval;
  v_slots jsonb := '[]'::jsonb;
  v_taken int := 0;
  v_total int := 0;
BEGIN
  v_clean := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_slug');
  END IF;

  -- Resolve + plan check
  SELECT w.shop_id, w.published, s.plan, s.plan_expires_at
  INTO v_shop_id, v_published, v_plan, v_expires
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = v_clean;

  IF v_shop_id IS NULL OR NOT v_published THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  IF v_expires IS NOT NULL AND v_expires < now() THEN v_plan := 'free'; END IF;
  IF v_plan NOT IN ('business','enterprise') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'feature_disabled');
  END IF;

  -- Validate provider belongs to this shop
  SELECT * INTO v_provider
  FROM sbp_appointment_providers
  WHERE id = p_provider_id AND shop_id = v_shop_id AND active = true;

  IF v_provider.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'provider_not_found');
  END IF;

  -- Validate date (not past, not too far future)
  IF p_date < CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'error', 'past_date', 'slots', v_slots);
  END IF;
  IF p_date > (CURRENT_DATE + interval '90 days') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_far_future', 'slots', v_slots);
  END IF;

  -- Validate duration
  IF p_duration_minutes IS NULL OR p_duration_minutes <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_duration', 'slots', v_slots);
  END IF;

  -- Provider closed on this weekday?
  v_dow := EXTRACT(DOW FROM p_date)::smallint;
  IF NOT (v_dow = ANY(v_provider.working_days)) THEN
    RETURN jsonb_build_object('ok', true, 'slots', v_slots, 'reason', 'closed');
  END IF;

  -- Whole-day block?
  IF EXISTS (
    SELECT 1 FROM sbp_provider_blocks
    WHERE provider_id = p_provider_id
      AND block_date = p_date
      AND start_time IS NULL
  ) THEN
    RETURN jsonb_build_object('ok', true, 'slots', v_slots, 'reason', 'blocked');
  END IF;

  v_duration := (p_duration_minutes || ' minutes')::interval;
  v_buffer   := (v_provider.buffer_minutes || ' minutes')::interval;
  v_slot_step := (v_provider.slot_interval_minutes || ' minutes')::interval;

  -- Build day window in IST (Asia/Kolkata) for clarity, then convert to UTC
  v_day_start := (p_date::text || ' ' || v_provider.work_start_time::text)::timestamp AT TIME ZONE 'Asia/Kolkata';
  v_day_end   := (p_date::text || ' ' || v_provider.work_end_time::text)::timestamp AT TIME ZONE 'Asia/Kolkata';

  v_cursor := v_day_start;

  -- Iterate slot starts, step by slot_interval
  WHILE v_cursor + v_duration <= v_day_end LOOP
    v_slot_end := v_cursor + v_duration;
    v_total := v_total + 1;

    -- Skip if in the past
    IF v_cursor <= v_now + interval '15 minutes' THEN
      v_cursor := v_cursor + v_slot_step;
      CONTINUE;
    END IF;

    -- Skip if intersects a partial block on this date
    IF EXISTS (
      SELECT 1 FROM sbp_provider_blocks b
      WHERE b.provider_id = p_provider_id
        AND b.block_date = p_date
        AND b.start_time IS NOT NULL
        AND tsrange(
              (b.block_date::text || ' ' || b.start_time::text)::timestamp AT TIME ZONE 'Asia/Kolkata',
              (b.block_date::text || ' ' || b.end_time::text)::timestamp AT TIME ZONE 'Asia/Kolkata'
            ) && tsrange(v_cursor, v_slot_end)
    ) THEN
      v_cursor := v_cursor + v_slot_step;
      CONTINUE;
    END IF;

    -- Skip if intersects an existing pending/confirmed appointment (with buffer)
    IF EXISTS (
      SELECT 1 FROM sbp_appointments a
      WHERE a.provider_id = p_provider_id
        AND a.status IN ('pending','confirmed')
        AND tsrange(a.starts_at - v_buffer, a.ends_at + v_buffer)
            && tsrange(v_cursor, v_slot_end)
    ) THEN
      v_taken := v_taken + 1;
      v_cursor := v_cursor + v_slot_step;
      CONTINUE;
    END IF;

    -- Slot is free
    v_slots := v_slots || jsonb_build_array(jsonb_build_object(
      'starts_at', v_cursor,
      'ends_at', v_slot_end,
      'time_label', to_char(v_cursor AT TIME ZONE 'Asia/Kolkata', 'HH12:MI AM')
    ));

    v_cursor := v_cursor + v_slot_step;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'slots', v_slots,
    'total_slots', v_total,
    'taken_slots', v_taken
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_available_slots_public(text, uuid, date, int) TO anon;
GRANT EXECUTE ON FUNCTION sbp_get_available_slots_public(text, uuid, date, int) TO authenticated;

-- 9c. Book an appointment (anon) — creates pending appointment
CREATE OR REPLACE FUNCTION sbp_book_appointment_public(
  p_slug    text,
  p_data    jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_published boolean;
  v_plan text;
  v_expires timestamptz;
  v_clean text;
  v_provider_id uuid;
  v_provider record;
  v_service_id uuid;
  v_service_name text;
  v_service_price numeric;
  v_starts timestamptz;
  v_duration int;
  v_ends timestamptz;
  v_id uuid;
  v_customer_name text;
  v_customer_phone text;
BEGIN
  -- Resolve slug + plan check
  v_clean := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean) = 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'no_slug'); END IF;

  SELECT w.shop_id, w.published, s.plan, s.plan_expires_at
  INTO v_shop_id, v_published, v_plan, v_expires
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = v_clean;

  IF v_shop_id IS NULL OR NOT v_published THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  IF v_expires IS NOT NULL AND v_expires < now() THEN v_plan := 'free'; END IF;
  IF v_plan NOT IN ('business','enterprise') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'feature_disabled');
  END IF;

  -- Validate inputs
  v_provider_id := (p_data->>'provider_id')::uuid;
  v_starts := (p_data->>'starts_at')::timestamptz;
  v_duration := (p_data->>'duration_minutes')::int;
  v_customer_name := trim(coalesce(p_data->>'customer_name', ''));
  v_customer_phone := trim(coalesce(p_data->>'customer_phone', ''));

  IF v_provider_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'provider_required'); END IF;
  IF v_starts IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'starts_at_required'); END IF;
  IF v_duration IS NULL OR v_duration <= 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'invalid_duration'); END IF;
  IF length(v_customer_name) = 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'name_required'); END IF;
  IF length(v_customer_phone) < 7 THEN RETURN jsonb_build_object('ok', false, 'error', 'phone_required'); END IF;

  -- Past start?
  IF v_starts < now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'past_starts_at');
  END IF;

  -- Provider belongs to this shop?
  SELECT * INTO v_provider FROM sbp_appointment_providers
  WHERE id = v_provider_id AND shop_id = v_shop_id AND active = true;
  IF v_provider.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'provider_not_found');
  END IF;

  v_ends := v_starts + (v_duration || ' minutes')::interval;

  -- Conflict check: ensure no overlapping pending/confirmed appointment
  IF EXISTS (
    SELECT 1 FROM sbp_appointments a
    WHERE a.provider_id = v_provider_id
      AND a.status IN ('pending','confirmed')
      AND tsrange(
            a.starts_at - (v_provider.buffer_minutes || ' minutes')::interval,
            a.ends_at + (v_provider.buffer_minutes || ' minutes')::interval
          ) && tsrange(v_starts, v_ends)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slot_taken');
  END IF;

  -- Snapshot service info
  v_service_id := NULLIF(p_data->>'service_id','')::uuid;
  IF v_service_id IS NOT NULL THEN
    SELECT name, price INTO v_service_name, v_service_price
    FROM sbp_services WHERE id = v_service_id AND shop_id = v_shop_id AND active = true;
    IF v_service_name IS NULL THEN
      v_service_id := NULL;
    END IF;
  END IF;

  -- Create the appointment in 'pending' status (admin can confirm)
  INSERT INTO sbp_appointments(
    shop_id, provider_id, service_id,
    customer_name, customer_phone, customer_wa,
    starts_at, ends_at, duration_minutes,
    service_name_snapshot, service_price_snapshot,
    status, notes, source
  ) VALUES (
    v_shop_id, v_provider_id, v_service_id,
    v_customer_name, v_customer_phone,
    NULLIF(trim(coalesce(p_data->>'customer_wa','')), ''),
    v_starts, v_ends, v_duration,
    v_service_name, v_service_price,
    'pending',
    NULLIF(trim(coalesce(p_data->>'notes','')), ''),
    'public_form'
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'appointment_id', v_id,
    'starts_at', v_starts,
    'provider_name', v_provider.name,
    'service_name', v_service_name,
    'duration_minutes', v_duration
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_book_appointment_public(text, jsonb) TO anon;
GRANT EXECUTE ON FUNCTION sbp_book_appointment_public(text, jsonb) TO authenticated;

-- 9d. Customer status check (verify with phone match)
CREATE OR REPLACE FUNCTION sbp_get_appointment_status_public(
  p_appointment_id uuid,
  p_phone          text
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_row record;
  v_clean_phone text;
BEGIN
  v_clean_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  IF length(v_clean_phone) < 7 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_phone');
  END IF;

  SELECT a.id, a.status, a.starts_at, a.ends_at, a.customer_name,
         a.service_name_snapshot, a.duration_minutes,
         pr.name AS provider_name,
         s.name AS shop_name
  INTO v_row
  FROM sbp_appointments a
  JOIN sbp_appointment_providers pr ON pr.id = a.provider_id
  JOIN shops s ON s.id = a.shop_id
  WHERE a.id = p_appointment_id
    AND regexp_replace(coalesce(a.customer_phone, ''), '[^0-9]', '', 'g') = v_clean_phone;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found_or_phone_mismatch');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'appointment_id', v_row.id,
    'status', v_row.status,
    'starts_at', v_row.starts_at,
    'duration_minutes', v_row.duration_minutes,
    'customer_name', v_row.customer_name,
    'service_name', v_row.service_name_snapshot,
    'provider_name', v_row.provider_name,
    'shop_name', v_row.shop_name
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_appointment_status_public(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION sbp_get_appointment_status_public(uuid, text) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- Verification (run manually):
--
-- -- 1. Tables + RLS
-- SELECT tablename, rowsecurity FROM pg_tables WHERE tablename LIKE 'sbp_appointment%' OR tablename = 'sbp_provider_blocks';
--
-- -- 2. Functions exist
-- SELECT proname FROM pg_proc WHERE proname LIKE 'sbp_appt%' OR proname LIKE 'sbp_appointments%' OR proname LIKE 'sbp_get_appointment%' OR proname = 'sbp_book_appointment_public' OR proname = 'sbp_get_available_slots_public' OR proname = 'sbp_check_business_owner';
-- -- Expected: 13 rows
--
-- -- 3. Public RPCs anon-callable
-- SELECT sbp_get_appointment_config_public('glitz-glam');
-- ════════════════════════════════════════════════════════════════════
