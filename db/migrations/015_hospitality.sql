-- ════════════════════════════════════════════════════════════════════
-- 015_hospitality.sql
-- Batch 015 — Hospitality Phase 1 (6 May 2026)
--
-- Brings the Hospitality vertical from ~50% (website + WhatsApp + cash)
-- to 100% complete for beta launch. Small hotels, lodges, homestays,
-- guesthouses, hostels, dharamshalas, resorts, service apartments,
-- day-room lounges, boutique hotels, camping/glamping operators can
-- run their full daily workflow on the platform after this ships.
--
-- DELIVERABLES:
--   1. 4 new tables: sbp_room_types, sbp_rooms, sbp_bookings,
--      sbp_booking_extras
--   2. ~12 RPCs covering: room/room-type CRUD, availability check,
--      booking lifecycle (create, check-in, check-out, cancel),
--      folio extras add/remove, occupancy summary
--   3. 8 new sub-types under hospitality macro
--   4. UPDATE sbp_module_profiles: rooms+bookings+folio active+NEW
--   5. RLS policies on all 4 tables
--   6. Indexes for date-range conflict queries
--
-- API-FIRST per locked rule. jsonb envelope, owner check, idempotent
-- where possible.
--
-- Prerequisites: 003_business_categories.sql must have run.
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Sub-type expansion (8 new) ───────────────────────────────────

INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('resort',           'hospitality', 'Resort',                    'रिसोर्ट',            '🏖️', 'hospitality', 13),
  ('guesthouse',       'hospitality', 'Guest House',                'गेस्ट हाउस',         '🛏️', 'hospitality', 14),
  ('service_apartment','hospitality', 'Service Apartment',          'सर्विस अपार्टमेंट',  '🏘️', 'hospitality', 15),
  ('hostel',           'hospitality', 'Hostel / Backpacker',        'हॉस्टल',             '🎒', 'hospitality', 16),
  ('dharamshala',      'hospitality', 'Dharamshala / Pilgrim Lodge','धर्मशाला',           '🛕', 'hospitality', 17),
  ('day_room',         'hospitality', 'Day Room / Transit Lounge',  'डे रूम / लाउंज',     '💼', 'hospitality', 18),
  ('boutique_hotel',   'hospitality', 'Boutique Hotel',              'बुटीक होटल',         '💎', 'hospitality', 19),
  ('camping',          'hospitality', 'Camping / Glamping',          'कैंपिंग',            '🏕️', 'hospitality', 20)
ON CONFLICT (code) DO UPDATE SET
  name_en        = EXCLUDED.name_en,
  name_hi        = EXCLUDED.name_hi,
  emoji          = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order  = EXCLUDED.display_order;


-- ── 2. Tables ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sbp_room_types (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id             uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  name                text NOT NULL CHECK (length(trim(name)) > 0),
  description         text,
  capacity_adults     int NOT NULL DEFAULT 2 CHECK (capacity_adults >= 1),
  capacity_children   int NOT NULL DEFAULT 0 CHECK (capacity_children >= 0),
  base_price          numeric NOT NULL DEFAULT 0 CHECK (base_price >= 0),
  weekend_price       numeric CHECK (weekend_price IS NULL OR weekend_price >= 0),
  amenities           text[] NOT NULL DEFAULT '{}',
  active              boolean NOT NULL DEFAULT true,
  display_order       int NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_room_types_shop ON sbp_room_types(shop_id) WHERE active = true;

CREATE TABLE IF NOT EXISTS sbp_rooms (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id             uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  room_type_id        uuid REFERENCES sbp_room_types(id) ON DELETE SET NULL,
  room_number         text NOT NULL CHECK (length(trim(room_number)) > 0),
  floor               text,
  status              text NOT NULL DEFAULT 'available'
    CHECK (status IN ('available','occupied','cleaning','maintenance','blocked')),
  notes               text,
  active              boolean NOT NULL DEFAULT true,
  display_order       int NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, room_number)
);
CREATE INDEX IF NOT EXISTS idx_rooms_shop ON sbp_rooms(shop_id) WHERE active = true;
CREATE INDEX IF NOT EXISTS idx_rooms_type ON sbp_rooms(room_type_id);

CREATE TABLE IF NOT EXISTS sbp_bookings (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id             uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  -- Customer
  customer_id         uuid REFERENCES customers(id) ON DELETE SET NULL,  -- nullable: walk-in
  customer_name       text NOT NULL CHECK (length(trim(customer_name)) > 0),
  customer_phone      text,
  customer_wa         text,
  customer_email      text,
  -- Guest counts
  num_adults          int NOT NULL DEFAULT 1 CHECK (num_adults >= 1),
  num_children        int NOT NULL DEFAULT 0 CHECK (num_children >= 0),
  -- Room assignment (nullable until check-in for type-only bookings)
  room_id             uuid REFERENCES sbp_rooms(id) ON DELETE SET NULL,
  room_type_id        uuid REFERENCES sbp_room_types(id) ON DELETE SET NULL,
  room_number_snapshot text,        -- snapshot at check-in
  room_type_snapshot   text,        -- snapshot at check-in
  -- Dates
  check_in_date       date NOT NULL,
  check_out_date      date NOT NULL,
  num_nights          int NOT NULL CHECK (num_nights >= 1),
  -- Pricing
  rate_per_night      numeric NOT NULL DEFAULT 0 CHECK (rate_per_night >= 0),
  room_total          numeric NOT NULL DEFAULT 0,
  extras_total        numeric NOT NULL DEFAULT 0,
  discount_amount     numeric NOT NULL DEFAULT 0,
  tax_amount          numeric NOT NULL DEFAULT 0,
  grand_total         numeric NOT NULL DEFAULT 0,
  -- Status
  status              text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','confirmed','checked_in','checked_out','cancelled','no_show')),
  -- ID proof (Indian hotels mandatory)
  id_proof_type       text CHECK (id_proof_type IS NULL OR id_proof_type IN ('aadhaar','pan','passport','driving_license','voter_id','other')),
  id_proof_number     text,
  -- Source
  source              text NOT NULL DEFAULT 'admin'
    CHECK (source IN ('admin','walk_in','phone','whatsapp','public_form','online')),
  -- Timestamps
  booked_at           timestamptz NOT NULL DEFAULT now(),
  checked_in_at       timestamptz,
  checked_out_at      timestamptz,
  cancelled_at        timestamptz,
  cancelled_reason    text,
  -- Notes
  notes               text,        -- public-facing
  internal_notes      text,        -- staff-only
  -- Bill linkage (set at checkout)
  bill_id             uuid REFERENCES bills(id) ON DELETE SET NULL,
  -- Audit
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (check_out_date > check_in_date)
);
CREATE INDEX IF NOT EXISTS idx_bookings_shop_status ON sbp_bookings(shop_id, status, check_in_date);
CREATE INDEX IF NOT EXISTS idx_bookings_dates ON sbp_bookings(shop_id, check_in_date, check_out_date) WHERE status IN ('pending','confirmed','checked_in');
CREATE INDEX IF NOT EXISTS idx_bookings_customer ON sbp_bookings(customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bookings_room ON sbp_bookings(room_id) WHERE room_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS sbp_booking_extras (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id             uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  booking_id          uuid NOT NULL REFERENCES sbp_bookings(id) ON DELETE CASCADE,
  category            text NOT NULL DEFAULT 'service'
    CHECK (category IN ('food','laundry','minibar','service','telephone','transport','other')),
  description         text NOT NULL CHECK (length(trim(description)) > 0),
  qty                 int NOT NULL DEFAULT 1 CHECK (qty >= 1),
  unit_price          numeric NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  amount              numeric NOT NULL DEFAULT 0,            -- qty * unit_price
  added_at            timestamptz NOT NULL DEFAULT now(),
  added_by            uuid REFERENCES auth.users(id)
);
CREATE INDEX IF NOT EXISTS idx_booking_extras_booking ON sbp_booking_extras(booking_id, added_at DESC);


-- ── 3. RLS ──────────────────────────────────────────────────────────

ALTER TABLE sbp_room_types     ENABLE ROW LEVEL SECURITY;
ALTER TABLE sbp_rooms          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sbp_bookings       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sbp_booking_extras ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_room_types_owner ON sbp_room_types;
CREATE POLICY p_room_types_owner ON sbp_room_types
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

DROP POLICY IF EXISTS p_rooms_owner ON sbp_rooms;
CREATE POLICY p_rooms_owner ON sbp_rooms
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

DROP POLICY IF EXISTS p_bookings_owner ON sbp_bookings;
CREATE POLICY p_bookings_owner ON sbp_bookings
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

DROP POLICY IF EXISTS p_booking_extras_owner ON sbp_booking_extras;
CREATE POLICY p_booking_extras_owner ON sbp_booking_extras
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));


-- ── 4. Helper: ownership + plan check (Pro+ for hospitality) ────────

CREATE OR REPLACE FUNCTION sbp_check_hospitality_owner(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_owner uuid;
  v_plan  text;
  v_exp   timestamptz;
BEGIN
  SELECT owner_id, plan, plan_expires_at INTO v_owner, v_plan, v_exp
  FROM shops WHERE id = p_shop_id;

  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  -- Hospitality is Pro/Business only (legacy 'enterprise' = 'business')
  IF v_plan IS NULL OR v_plan = 'free' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'free_plan_no_hospitality');
  END IF;
  IF v_exp IS NOT NULL AND v_exp < now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan_expired');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_check_hospitality_owner(uuid) TO authenticated;


-- ── 5. RPC: Room Types — list / upsert / delete ─────────────────────

CREATE OR REPLACE FUNCTION sbp_room_types_list(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_rows  jsonb;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(rt) ORDER BY rt.display_order, rt.created_at), '[]'::jsonb)
  INTO v_rows
  FROM sbp_room_types rt
  WHERE rt.shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true, 'room_types', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_room_types_list(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_room_types_upsert(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_id    uuid;
  v_name  text;
  v_row   sbp_room_types%ROWTYPE;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_name := trim(coalesce(p_data->>'name', ''));
  IF length(v_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_required');
  END IF;

  v_id := NULLIF(p_data->>'id', '')::uuid;

  IF v_id IS NULL THEN
    INSERT INTO sbp_room_types (
      shop_id, name, description,
      capacity_adults, capacity_children,
      base_price, weekend_price,
      amenities, active, display_order
    )
    VALUES (
      p_shop_id, v_name, p_data->>'description',
      COALESCE((p_data->>'capacity_adults')::int, 2),
      COALESCE((p_data->>'capacity_children')::int, 0),
      COALESCE((p_data->>'base_price')::numeric, 0),
      NULLIF(p_data->>'weekend_price','')::numeric,
      COALESCE(ARRAY(SELECT jsonb_array_elements_text(p_data->'amenities')), '{}'),
      COALESCE((p_data->>'active')::boolean, true),
      COALESCE((p_data->>'display_order')::int, 0)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE sbp_room_types SET
      name              = v_name,
      description       = p_data->>'description',
      capacity_adults   = COALESCE((p_data->>'capacity_adults')::int, capacity_adults),
      capacity_children = COALESCE((p_data->>'capacity_children')::int, capacity_children),
      base_price        = COALESCE((p_data->>'base_price')::numeric, base_price),
      weekend_price     = NULLIF(p_data->>'weekend_price','')::numeric,
      amenities         = COALESCE(ARRAY(SELECT jsonb_array_elements_text(p_data->'amenities')), amenities),
      active            = COALESCE((p_data->>'active')::boolean, active),
      display_order     = COALESCE((p_data->>'display_order')::int, display_order),
      updated_at        = now()
    WHERE id = v_id AND shop_id = p_shop_id
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'room_type_not_found');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'room_type', to_jsonb(v_row));
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_room_types_upsert(uuid, jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_room_types_delete(p_shop_id uuid, p_room_type_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_count int;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Check if rooms reference this type
  SELECT COUNT(*) INTO v_count FROM sbp_rooms
  WHERE room_type_id = p_room_type_id AND active = true;
  IF v_count > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rooms_using_type', 'count', v_count);
  END IF;

  DELETE FROM sbp_room_types
  WHERE id = p_room_type_id AND shop_id = p_shop_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_room_types_delete(uuid, uuid) TO authenticated;


-- ── 6. RPC: Rooms — list / upsert / delete / availability ───────────

CREATE OR REPLACE FUNCTION sbp_rooms_list(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_rows  jsonb;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             r.id,
    'room_number',    r.room_number,
    'floor',          r.floor,
    'status',         r.status,
    'notes',          r.notes,
    'active',         r.active,
    'display_order',  r.display_order,
    'room_type_id',   r.room_type_id,
    'room_type_name', rt.name,
    'base_price',     rt.base_price,
    'capacity_adults',rt.capacity_adults,
    'capacity_children',rt.capacity_children,
    'created_at',     r.created_at
  ) ORDER BY r.display_order, r.room_number), '[]'::jsonb)
  INTO v_rows
  FROM sbp_rooms r
  LEFT JOIN sbp_room_types rt ON rt.id = r.room_type_id
  WHERE r.shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true, 'rooms', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_rooms_list(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_rooms_upsert(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_id    uuid;
  v_num   text;
  v_row   sbp_rooms%ROWTYPE;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_num := trim(coalesce(p_data->>'room_number', ''));
  IF length(v_num) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_number_required');
  END IF;

  v_id := NULLIF(p_data->>'id', '')::uuid;

  IF v_id IS NULL THEN
    INSERT INTO sbp_rooms (
      shop_id, room_type_id, room_number, floor, status, notes, active, display_order
    ) VALUES (
      p_shop_id,
      NULLIF(p_data->>'room_type_id','')::uuid,
      v_num,
      p_data->>'floor',
      COALESCE(p_data->>'status', 'available'),
      p_data->>'notes',
      COALESCE((p_data->>'active')::boolean, true),
      COALESCE((p_data->>'display_order')::int, 0)
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE sbp_rooms SET
      room_type_id  = NULLIF(p_data->>'room_type_id','')::uuid,
      room_number   = v_num,
      floor         = p_data->>'floor',
      status        = COALESCE(p_data->>'status', status),
      notes         = p_data->>'notes',
      active        = COALESCE((p_data->>'active')::boolean, active),
      display_order = COALESCE((p_data->>'display_order')::int, display_order),
      updated_at    = now()
    WHERE id = v_id AND shop_id = p_shop_id
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'room_not_found');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'room', to_jsonb(v_row));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'duplicate_room_number');
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_rooms_upsert(uuid, jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_rooms_delete(p_shop_id uuid, p_room_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_active_bookings int;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COUNT(*) INTO v_active_bookings FROM sbp_bookings
  WHERE room_id = p_room_id AND status IN ('pending','confirmed','checked_in');
  IF v_active_bookings > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'has_active_bookings', 'count', v_active_bookings);
  END IF;

  DELETE FROM sbp_rooms WHERE id = p_room_id AND shop_id = p_shop_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_rooms_delete(uuid, uuid) TO authenticated;


-- Returns room IDs available for a date range (for booking creation)
CREATE OR REPLACE FUNCTION sbp_rooms_check_availability(
  p_shop_id uuid,
  p_check_in date,
  p_check_out date,
  p_room_type_id uuid DEFAULT NULL,
  p_exclude_booking_id uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_rooms jsonb;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  IF p_check_out <= p_check_in THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date_range');
  END IF;

  WITH conflicting_bookings AS (
    -- A booking conflicts if its date range overlaps [p_check_in, p_check_out)
    SELECT room_id FROM sbp_bookings
    WHERE shop_id = p_shop_id
      AND status IN ('pending','confirmed','checked_in')
      AND room_id IS NOT NULL
      AND (p_exclude_booking_id IS NULL OR id <> p_exclude_booking_id)
      AND check_in_date < p_check_out
      AND check_out_date > p_check_in
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',             r.id,
    'room_number',    r.room_number,
    'floor',          r.floor,
    'status',         r.status,
    'room_type_id',   r.room_type_id,
    'room_type_name', rt.name,
    'base_price',     rt.base_price,
    'capacity_adults',rt.capacity_adults
  ) ORDER BY r.display_order, r.room_number), '[]'::jsonb)
  INTO v_rooms
  FROM sbp_rooms r
  LEFT JOIN sbp_room_types rt ON rt.id = r.room_type_id
  WHERE r.shop_id = p_shop_id
    AND r.active = true
    AND r.status NOT IN ('maintenance','blocked')
    AND r.id NOT IN (SELECT room_id FROM conflicting_bookings WHERE room_id IS NOT NULL)
    AND (p_room_type_id IS NULL OR r.room_type_id = p_room_type_id);

  RETURN jsonb_build_object('ok', true, 'available_rooms', v_rooms);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_rooms_check_availability(uuid, date, date, uuid, uuid) TO authenticated;


-- ── 7. RPC: Bookings — list / create / cancel / check-in / check-out ─

CREATE OR REPLACE FUNCTION sbp_bookings_list(
  p_shop_id uuid,
  p_filter text DEFAULT 'upcoming',     -- 'today' | 'upcoming' | 'past' | 'all'
  p_status_filter text DEFAULT NULL     -- 'all' | specific status
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
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
        (p_filter = 'past'     AND (b.check_out_date < v_today OR b.status IN ('checked_out','cancelled','no_show')))
      )
      AND (p_status_filter IS NULL OR p_status_filter = 'all' OR b.status = p_status_filter)
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
    'status',             f.status,
    'source',             f.source,
    'id_proof_type',      f.id_proof_type,
    'id_proof_number',    f.id_proof_number,
    'notes',              f.notes,
    'booked_at',          f.booked_at,
    'checked_in_at',      f.checked_in_at,
    'checked_out_at',     f.checked_out_at,
    'cancelled_at',       f.cancelled_at,
    'bill_id',            f.bill_id
  ) ORDER BY f.check_in_date DESC, f.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM filtered f;

  RETURN jsonb_build_object('ok', true, 'bookings', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_bookings_list(uuid, text, text) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_bookings_create(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check    jsonb;
  v_avail    jsonb;
  v_in       date;
  v_out      date;
  v_nights   int;
  v_rate     numeric;
  v_room_id  uuid;
  v_room     sbp_rooms%ROWTYPE;
  v_rt       sbp_room_types%ROWTYPE;
  v_room_total numeric;
  v_grand    numeric;
  v_row      sbp_bookings%ROWTYPE;
  v_cust_name text;
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

  -- Verify room belongs to shop + isn't double-booked
  SELECT * INTO v_room FROM sbp_rooms WHERE id = v_room_id AND shop_id = p_shop_id;
  IF v_room.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_not_found');
  END IF;
  IF v_room.status IN ('maintenance','blocked') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'room_unavailable');
  END IF;

  -- Conflict check: any overlapping active booking on this room?
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
    NULLIF(p_data->>'customer_id','')::uuid,
    v_cust_name,
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
    p_data->>'notes', p_data->>'internal_notes'
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_bookings_create(uuid, jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_bookings_check_in(p_shop_id uuid, p_booking_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_b     sbp_bookings%ROWTYPE;
  v_room  sbp_rooms%ROWTYPE;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM sbp_bookings WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found'); END IF;
  IF v_b.status NOT IN ('pending','confirmed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_status_for_check_in', 'current_status', v_b.status);
  END IF;

  SELECT * INTO v_room FROM sbp_rooms WHERE id = v_b.room_id;

  UPDATE sbp_bookings SET
    status                = 'checked_in',
    checked_in_at         = now(),
    room_number_snapshot  = v_room.room_number,
    room_type_snapshot    = (SELECT name FROM sbp_room_types WHERE id = v_b.room_type_id),
    updated_at            = now()
  WHERE id = p_booking_id;

  -- Mark room occupied
  IF v_b.room_id IS NOT NULL THEN
    UPDATE sbp_rooms SET status = 'occupied', updated_at = now() WHERE id = v_b.room_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'booking_id', p_booking_id);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_bookings_check_in(uuid, uuid) TO authenticated;


-- Check-out: marks booking checked_out, frees the room (status='cleaning').
-- Returns folio summary so client can create the bill.
-- Bill creation itself stays client-side (consistent with existing billing.html flow).
CREATE OR REPLACE FUNCTION sbp_bookings_check_out(p_shop_id uuid, p_booking_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check       jsonb;
  v_b           sbp_bookings%ROWTYPE;
  v_extras_sum  numeric;
  v_extras      jsonb;
  v_grand       numeric;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM sbp_bookings WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found'); END IF;
  IF v_b.status <> 'checked_in' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_checked_in', 'current_status', v_b.status);
  END IF;

  -- Sum extras
  SELECT COALESCE(SUM(amount), 0) INTO v_extras_sum
  FROM sbp_booking_extras WHERE booking_id = p_booking_id;

  -- Final grand total = room + extras + tax - discount
  v_grand := v_b.room_total + v_extras_sum + v_b.tax_amount - v_b.discount_amount;

  -- Get extras list for return
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'description', description, 'category', category,
    'qty', qty, 'unit_price', unit_price, 'amount', amount,
    'added_at', added_at
  ) ORDER BY added_at), '[]'::jsonb)
  INTO v_extras
  FROM sbp_booking_extras WHERE booking_id = p_booking_id;

  -- Update booking
  UPDATE sbp_bookings SET
    status         = 'checked_out',
    checked_out_at = now(),
    extras_total   = v_extras_sum,
    grand_total    = v_grand,
    updated_at     = now()
  WHERE id = p_booking_id;

  -- Free the room (cleaning state — staff sets back to available manually)
  IF v_b.room_id IS NOT NULL THEN
    UPDATE sbp_rooms SET status = 'cleaning', updated_at = now() WHERE id = v_b.room_id;
  END IF;

  -- Return folio summary for client to create bill
  RETURN jsonb_build_object(
    'ok', true,
    'booking_id', p_booking_id,
    'folio', jsonb_build_object(
      'customer_name',   v_b.customer_name,
      'customer_id',     v_b.customer_id,
      'customer_phone',  v_b.customer_phone,
      'customer_wa',     v_b.customer_wa,
      'check_in_date',   v_b.check_in_date,
      'check_out_date',  v_b.check_out_date,
      'num_nights',      v_b.num_nights,
      'room_number',     v_b.room_number_snapshot,
      'room_type',       v_b.room_type_snapshot,
      'rate_per_night',  v_b.rate_per_night,
      'room_total',      v_b.room_total,
      'extras_total',    v_extras_sum,
      'extras',          v_extras,
      'discount_amount', v_b.discount_amount,
      'tax_amount',      v_b.tax_amount,
      'grand_total',     v_grand
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_bookings_check_out(uuid, uuid) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_bookings_cancel(p_shop_id uuid, p_booking_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_b     sbp_bookings%ROWTYPE;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM sbp_bookings WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found'); END IF;
  IF v_b.status IN ('checked_out','cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_cancel_in_status', 'current_status', v_b.status);
  END IF;

  UPDATE sbp_bookings SET
    status           = 'cancelled',
    cancelled_at     = now(),
    cancelled_reason = p_reason,
    updated_at       = now()
  WHERE id = p_booking_id;

  -- If was checked_in, free the room
  IF v_b.status = 'checked_in' AND v_b.room_id IS NOT NULL THEN
    UPDATE sbp_rooms SET status = 'available', updated_at = now() WHERE id = v_b.room_id;
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_bookings_cancel(uuid, uuid, text) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_bookings_link_bill(p_shop_id uuid, p_booking_id uuid, p_bill_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  UPDATE sbp_bookings SET bill_id = p_bill_id, updated_at = now()
  WHERE id = p_booking_id AND shop_id = p_shop_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_bookings_link_bill(uuid, uuid, uuid) TO authenticated;


-- ── 8. RPC: Folio extras — list / add / remove ──────────────────────

CREATE OR REPLACE FUNCTION sbp_booking_extras_list(p_shop_id uuid, p_booking_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_rows  jsonb;
  v_sum   numeric;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.added_at DESC), '[]'::jsonb),
         COALESCE(SUM(e.amount), 0)
  INTO v_rows, v_sum
  FROM sbp_booking_extras e
  WHERE e.booking_id = p_booking_id AND e.shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true, 'extras', v_rows, 'extras_total', v_sum);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_booking_extras_list(uuid, uuid) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_booking_extras_add(p_shop_id uuid, p_booking_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_b     sbp_bookings%ROWTYPE;
  v_qty   int;
  v_unit  numeric;
  v_amt   numeric;
  v_desc  text;
  v_row   sbp_booking_extras%ROWTYPE;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM sbp_bookings WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found'); END IF;
  IF v_b.status NOT IN ('pending','confirmed','checked_in') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_add_extras_in_status', 'current_status', v_b.status);
  END IF;

  v_desc := trim(coalesce(p_data->>'description', ''));
  IF length(v_desc) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'description_required');
  END IF;
  v_qty  := COALESCE((p_data->>'qty')::int, 1);
  v_unit := COALESCE((p_data->>'unit_price')::numeric, 0);
  v_amt  := v_qty * v_unit;

  INSERT INTO sbp_booking_extras (
    shop_id, booking_id, category, description, qty, unit_price, amount, added_by
  )
  VALUES (
    p_shop_id, p_booking_id,
    COALESCE(p_data->>'category', 'service'),
    v_desc, v_qty, v_unit, v_amt, auth.uid()
  )
  RETURNING * INTO v_row;

  -- Update the booking's extras_total cache
  UPDATE sbp_bookings SET
    extras_total = (SELECT COALESCE(SUM(amount),0) FROM sbp_booking_extras WHERE booking_id = p_booking_id),
    grand_total  = room_total + (SELECT COALESCE(SUM(amount),0) FROM sbp_booking_extras WHERE booking_id = p_booking_id) + tax_amount - discount_amount,
    updated_at   = now()
  WHERE id = p_booking_id;

  RETURN jsonb_build_object('ok', true, 'extra', to_jsonb(v_row));
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_booking_extras_add(uuid, uuid, jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION sbp_booking_extras_remove(p_shop_id uuid, p_extra_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_b_id  uuid;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT booking_id INTO v_b_id FROM sbp_booking_extras
  WHERE id = p_extra_id AND shop_id = p_shop_id;
  IF v_b_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'extra_not_found'); END IF;

  DELETE FROM sbp_booking_extras WHERE id = p_extra_id AND shop_id = p_shop_id;

  -- Recalculate booking totals
  UPDATE sbp_bookings SET
    extras_total = (SELECT COALESCE(SUM(amount),0) FROM sbp_booking_extras WHERE booking_id = v_b_id),
    grand_total  = room_total + (SELECT COALESCE(SUM(amount),0) FROM sbp_booking_extras WHERE booking_id = v_b_id) + tax_amount - discount_amount,
    updated_at   = now()
  WHERE id = v_b_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_booking_extras_remove(uuid, uuid) TO authenticated;


-- ── 9. RPC: Occupancy summary (today snapshot) ──────────────────────

CREATE OR REPLACE FUNCTION sbp_hospitality_summary(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_check jsonb;
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_total_rooms int;
  v_occupied    int;
  v_arrivals    int;
  v_departures  int;
  v_checked_in  int;
  v_pending     int;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COUNT(*) INTO v_total_rooms FROM sbp_rooms
  WHERE shop_id = p_shop_id AND active = true;

  SELECT COUNT(*) INTO v_occupied FROM sbp_rooms
  WHERE shop_id = p_shop_id AND active = true AND status = 'occupied';

  SELECT COUNT(*) INTO v_arrivals FROM sbp_bookings
  WHERE shop_id = p_shop_id AND check_in_date = v_today AND status IN ('pending','confirmed');

  SELECT COUNT(*) INTO v_departures FROM sbp_bookings
  WHERE shop_id = p_shop_id AND check_out_date = v_today AND status = 'checked_in';

  SELECT COUNT(*) INTO v_checked_in FROM sbp_bookings
  WHERE shop_id = p_shop_id AND status = 'checked_in';

  SELECT COUNT(*) INTO v_pending FROM sbp_bookings
  WHERE shop_id = p_shop_id AND check_in_date >= v_today AND status IN ('pending','confirmed');

  RETURN jsonb_build_object(
    'ok',                  true,
    'total_rooms',         v_total_rooms,
    'occupied_rooms',      v_occupied,
    'available_rooms',     v_total_rooms - v_occupied,
    'occupancy_pct',       CASE WHEN v_total_rooms > 0 THEN ROUND((v_occupied::numeric / v_total_rooms) * 100) ELSE 0 END,
    'arrivals_today',      v_arrivals,
    'departures_today',    v_departures,
    'currently_in_house',  v_checked_in,
    'upcoming_bookings',   v_pending
  );
END;
$$;
GRANT EXECUTE ON FUNCTION sbp_hospitality_summary(uuid) TO authenticated;


-- ── 10. Module profile updates: rooms+bookings+folio active+NEW ─────

UPDATE sbp_module_profiles
SET status = 'active', badge = 'NEW'
WHERE profile = 'hospitality'
  AND module_code IN ('rooms','bookings','folio');


-- ── Verification queries (paste in SQL Editor):
--
-- (1) Sub-types added:
--     SELECT code, name_en FROM sbp_business_categories
--     WHERE macro_code = 'hospitality' ORDER BY display_order;
--     -- Expected: 11 rows (3 existing + 8 new)
--
-- (2) Profile flips:
--     SELECT module_code, status, badge FROM sbp_module_profiles
--     WHERE profile = 'hospitality' ORDER BY display_order;
--     -- Expected: rooms, bookings, folio all 'active' + 'NEW' badge
--
-- (3) Smoke test RPCs (replace UUIDs):
--     SELECT sbp_room_types_list('<shop-uuid>');
--     SELECT sbp_hospitality_summary('<shop-uuid>');


-- ════════════════════════════════════════════════════════════════════
-- DONE — Migration 015 complete.
-- ════════════════════════════════════════════════════════════════════
