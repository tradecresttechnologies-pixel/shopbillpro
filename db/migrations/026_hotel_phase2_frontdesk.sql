-- ════════════════════════════════════════════════════════════════════
-- 026_hotel_phase2_frontdesk.sql
-- Batch 021B-A — Front-desk dashboard + walk-in fast-path (9 May 2026)
--
-- Two new RPCs powering the 021B-A frontend:
--
--   1. sbp_front_desk_dashboard(p_shop_id) — one-roundtrip JSON envelope
--      with today's arrivals/departures/in-house/vacant rooms + counts.
--      Front-desk.html polls this every 30s. Returns top 50 entries per
--      bucket (more than enough for the dashboard view; full lists go
--      to bookings.html).
--
--   2. sbp_walkin_check_in(p_shop_id, p_data) — atomic create-booking
--      + check-in for guests who walk in without a reservation. Wraps
--      the existing sbp_bookings_create + sbp_bookings_check_in logic
--      into a single transaction so partial failures don't leave the
--      booking in 'pending' state. Returns booking_id + folio summary.
--
-- All times are evaluated in IST (Asia/Kolkata) — Indian hotels run
-- their day boundary on local time, not UTC.
--
-- Idempotent. Safe to re-run.
-- Prerequisites: migrations 015 + 022 + 023 must have run.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. RPC: sbp_front_desk_dashboard
-- ──────────────────────────────────────────────────────────────────
--
-- Returns the front-desk operational view in one round trip:
--
-- {
--   ok: true,
--   date: '2026-05-09',
--   counts: {
--     arrivals_today, departures_today, in_house, vacant_rooms,
--     total_rooms, occupancy_pct
--   },
--   arrivals: [        -- sorted by check_in_date, then created_at
--     { id, customer_name, customer_phone, room_number, room_type_name,
--       num_adults, num_children, num_nights, rate_per_night, grand_total,
--       advance_amount, status, is_foreign }
--   ],
--   departures: [...], -- same shape, sorted by check_out_date
--   in_house: [...],   -- same shape, sorted by check_out_date
--   vacant_rooms: [    -- sorted by floor, room_number
--     { id, room_number, floor, status, room_type_name, base_price }
--   ]
-- }
--
-- Each list capped at 50 to keep the payload bounded.

CREATE OR REPLACE FUNCTION public.sbp_front_desk_dashboard(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check        jsonb;
  v_today        date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_total_rooms  int;
  v_occupied     int;
  v_arr_cnt      int;
  v_dep_cnt      int;
  v_in_cnt       int;
  v_vac_cnt      int;
  v_arrivals     jsonb;
  v_departures   jsonb;
  v_in_house     jsonb;
  v_vacant       jsonb;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Counts (cheap aggregates first)
  SELECT COUNT(*) INTO v_total_rooms
    FROM sbp_rooms WHERE shop_id = p_shop_id AND active = true;

  SELECT COUNT(*) INTO v_occupied
    FROM sbp_rooms
   WHERE shop_id = p_shop_id AND active = true AND status = 'occupied';

  SELECT COUNT(*) INTO v_arr_cnt
    FROM sbp_bookings
   WHERE shop_id = p_shop_id
     AND check_in_date = v_today
     AND status IN ('pending','confirmed');

  SELECT COUNT(*) INTO v_dep_cnt
    FROM sbp_bookings
   WHERE shop_id = p_shop_id
     AND check_out_date = v_today
     AND status = 'checked_in';

  SELECT COUNT(*) INTO v_in_cnt
    FROM sbp_bookings
   WHERE shop_id = p_shop_id AND status = 'checked_in';

  v_vac_cnt := v_total_rooms - v_occupied;

  -- Arrivals today (top 50)
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY check_in_date, created_at), '[]'::jsonb)
    INTO v_arrivals
    FROM (
      SELECT jsonb_build_object(
        'id',                  b.id,
        'customer_name',       b.customer_name,
        'customer_phone',      COALESCE(b.customer_phone, b.customer_wa),
        'room_number',         COALESCE(b.room_number_snapshot, r.room_number),
        'room_type_name',      COALESCE(b.room_type_snapshot, rt.name),
        'num_adults',          b.num_adults,
        'num_children',        b.num_children,
        'num_nights',          b.num_nights,
        'check_in_date',       b.check_in_date,
        'check_out_date',      b.check_out_date,
        'rate_per_night',      b.rate_per_night,
        'grand_total',         b.grand_total,
        'advance_amount',      COALESCE(b.advance_amount, 0),
        'status',              b.status,
        'is_foreign',          COALESCE(b.is_foreign, false),
        'source',              b.source
      ) AS row_obj,
      b.check_in_date,
      b.created_at
      FROM sbp_bookings b
      LEFT JOIN sbp_rooms r       ON r.id  = b.room_id
      LEFT JOIN sbp_room_types rt ON rt.id = b.room_type_id
      WHERE b.shop_id = p_shop_id
        AND b.check_in_date = v_today
        AND b.status IN ('pending','confirmed')
      ORDER BY b.check_in_date, b.created_at
      LIMIT 50
    ) sub;

  -- Departures today
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY check_out_date, created_at), '[]'::jsonb)
    INTO v_departures
    FROM (
      SELECT jsonb_build_object(
        'id',                  b.id,
        'customer_name',       b.customer_name,
        'customer_phone',      COALESCE(b.customer_phone, b.customer_wa),
        'room_number',         COALESCE(b.room_number_snapshot, r.room_number),
        'room_type_name',      COALESCE(b.room_type_snapshot, rt.name),
        'num_adults',          b.num_adults,
        'num_children',        b.num_children,
        'num_nights',          b.num_nights,
        'check_in_date',       b.check_in_date,
        'check_out_date',      b.check_out_date,
        'rate_per_night',      b.rate_per_night,
        'grand_total',         b.grand_total,
        'advance_amount',      COALESCE(b.advance_amount, 0),
        'status',              b.status,
        'is_foreign',          COALESCE(b.is_foreign, false)
      ) AS row_obj,
      b.check_out_date,
      b.created_at
      FROM sbp_bookings b
      LEFT JOIN sbp_rooms r       ON r.id  = b.room_id
      LEFT JOIN sbp_room_types rt ON rt.id = b.room_type_id
      WHERE b.shop_id = p_shop_id
        AND b.check_out_date = v_today
        AND b.status = 'checked_in'
      ORDER BY b.check_out_date, b.created_at
      LIMIT 50
    ) sub;

  -- Currently in-house (all checked-in regardless of check-out date)
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY check_out_date NULLS LAST, created_at), '[]'::jsonb)
    INTO v_in_house
    FROM (
      SELECT jsonb_build_object(
        'id',                  b.id,
        'customer_name',       b.customer_name,
        'customer_phone',      COALESCE(b.customer_phone, b.customer_wa),
        'room_number',         COALESCE(b.room_number_snapshot, r.room_number),
        'room_type_name',      COALESCE(b.room_type_snapshot, rt.name),
        'num_adults',          b.num_adults,
        'num_children',        b.num_children,
        'num_nights',          b.num_nights,
        'check_in_date',       b.check_in_date,
        'check_out_date',      b.check_out_date,
        'rate_per_night',      b.rate_per_night,
        'grand_total',         b.grand_total,
        'advance_amount',      COALESCE(b.advance_amount, 0),
        'status',              b.status,
        'is_foreign',          COALESCE(b.is_foreign, false),
        'days_remaining',      GREATEST(0, b.check_out_date - v_today)
      ) AS row_obj,
      b.check_out_date,
      b.created_at
      FROM sbp_bookings b
      LEFT JOIN sbp_rooms r       ON r.id  = b.room_id
      LEFT JOIN sbp_room_types rt ON rt.id = b.room_type_id
      WHERE b.shop_id = p_shop_id
        AND b.status  = 'checked_in'
      ORDER BY b.check_out_date NULLS LAST, b.created_at
      LIMIT 50
    ) sub;

  -- Vacant rooms (anything not 'occupied' AND active=true)
  SELECT COALESCE(jsonb_agg(row_obj ORDER BY floor NULLS LAST, room_number), '[]'::jsonb)
    INTO v_vacant
    FROM (
      SELECT jsonb_build_object(
        'id',              r.id,
        'room_number',     r.room_number,
        'floor',           r.floor,
        'status',          r.status,
        'room_type_id',    r.room_type_id,
        'room_type_name',  rt.name,
        'base_price',      rt.base_price,
        'capacity_adults', rt.capacity_adults,
        'notes',           r.notes
      ) AS row_obj,
      r.floor,
      r.room_number
      FROM sbp_rooms r
      LEFT JOIN sbp_room_types rt ON rt.id = r.room_type_id
      WHERE r.shop_id = p_shop_id
        AND r.active = true
        AND r.status <> 'occupied'
      ORDER BY r.floor NULLS LAST, r.room_number
      LIMIT 50
    ) sub;

  RETURN jsonb_build_object(
    'ok',           true,
    'date',         v_today,
    'counts',       jsonb_build_object(
      'arrivals_today',   v_arr_cnt,
      'departures_today', v_dep_cnt,
      'in_house',         v_in_cnt,
      'vacant_rooms',     v_vac_cnt,
      'total_rooms',      v_total_rooms,
      'occupancy_pct',    CASE WHEN v_total_rooms > 0
                                THEN ROUND((v_occupied::numeric / v_total_rooms) * 100)
                                ELSE 0 END
    ),
    'arrivals',     v_arrivals,
    'departures',   v_departures,
    'in_house',     v_in_house,
    'vacant_rooms', v_vacant
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_front_desk_dashboard(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 2. RPC: sbp_walkin_check_in
-- ──────────────────────────────────────────────────────────────────
--
-- Atomic create-booking + check-in for walk-in guests. Wraps the two
-- existing operations so:
--   - check_in_date defaults to today (IST), check_out to today+nights
--   - status flips through pending → confirmed → checked_in in one shot
--   - room status flips from vacant → occupied atomically
--   - if any step fails, the whole thing rolls back (no orphaned
--     bookings sitting in 'pending')
--
-- p_data shape: same as sbp_bookings_create's p_data, plus optional
--   'num_nights' (defaults 1). check_in_date / check_out_date in
--   p_data are ignored — walk-ins always start "now" (today IST).
--
-- Returns: { ok, booking_id, folio: { ... summary ... } } on success,
--          { ok: false, error: '...' } otherwise.

CREATE OR REPLACE FUNCTION public.sbp_walkin_check_in(p_shop_id uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check         jsonb;
  v_today         date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_nights        int  := GREATEST(1, COALESCE((p_data->>'num_nights')::int, 1));
  v_data          jsonb;
  v_create_res    jsonb;
  v_checkin_res   jsonb;
  v_booking_id    uuid;
  v_room_id       uuid;
  v_room_number   text;
  v_room_type     text;
  v_rate          numeric;
  v_grand         numeric;
  v_advance       numeric;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Force today IST as check-in, today+nights as check-out
  v_data := p_data
    || jsonb_build_object(
         'check_in_date',  v_today::text,
         'check_out_date', (v_today + v_nights)::text,
         'source',         COALESCE(p_data->>'source', 'walk_in'),
         'status',         'confirmed'
       );

  -- 1. Create booking (existing RPC handles validation, customer
  --    resolution via 023, advance, foreign fields, etc.)
  v_create_res := public.sbp_bookings_create(p_shop_id, v_data);
  IF NOT (v_create_res->>'ok')::boolean THEN
    RETURN v_create_res;
  END IF;

  v_booking_id := (v_create_res->>'booking_id')::uuid;
  IF v_booking_id IS NULL THEN
    -- Defensive: older create RPCs may have returned booking under different key
    v_booking_id := (v_create_res->'booking'->>'id')::uuid;
  END IF;

  IF v_booking_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'walkin_create_no_booking_id',
      'create_response', v_create_res
    );
  END IF;

  -- 2. Immediately check in (RPC flips status + room state)
  v_checkin_res := public.sbp_bookings_check_in(p_shop_id, v_booking_id);
  IF NOT (v_checkin_res->>'ok')::boolean THEN
    -- Roll back the booking we just created so we don't leave an orphan
    BEGIN
      DELETE FROM public.sbp_bookings
       WHERE id = v_booking_id AND shop_id = p_shop_id AND status = 'confirmed';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RETURN jsonb_build_object(
      'ok',    false,
      'error', COALESCE(v_checkin_res->>'error', 'walkin_checkin_failed'),
      'booking_id', v_booking_id
    );
  END IF;

  -- 3. Pull a folio summary for the response (so the UI can show the
  --    just-checked-in guest immediately without a second round-trip).
  SELECT
    b.room_id,
    COALESCE(b.room_number_snapshot, r.room_number),
    COALESCE(b.room_type_snapshot,   rt.name),
    b.rate_per_night,
    b.grand_total,
    COALESCE(b.advance_amount, 0)
    INTO v_room_id, v_room_number, v_room_type, v_rate, v_grand, v_advance
    FROM public.sbp_bookings b
    LEFT JOIN public.sbp_rooms r       ON r.id  = b.room_id
    LEFT JOIN public.sbp_room_types rt ON rt.id = b.room_type_id
   WHERE b.id = v_booking_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'booking_id',   v_booking_id,
    'folio', jsonb_build_object(
      'check_in_date',  v_today,
      'check_out_date', v_today + v_nights,
      'num_nights',     v_nights,
      'room_id',        v_room_id,
      'room_number',    v_room_number,
      'room_type',      v_room_type,
      'rate_per_night', v_rate,
      'grand_total',    v_grand,
      'advance_amount', v_advance,
      'balance_due',    GREATEST(0, COALESCE(v_grand,0) - COALESCE(v_advance,0))
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_walkin_check_in(uuid, jsonb) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 3. Module profile entries — surface the new pages in the sidebar
-- ──────────────────────────────────────────────────────────────────
--
-- Add 'front_desk' + 'walk_in' module codes to the hospitality profile.
-- The sidebar engine reads sbp_module_profiles for the shop's profile
-- and renders entries whose status='active'. Idempotent via
-- ON CONFLICT.

INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('hospitality', 'front_desk', 'active', 'NEW', 155),
  ('hospitality', 'walk_in',    'active', 'NEW', 156)
ON CONFLICT (profile, module_code) DO UPDATE
  SET status = EXCLUDED.status,
      badge  = EXCLUDED.badge,
      display_order = EXCLUDED.display_order;


-- ──────────────────────────────────────────────────────────────────
-- 4. Verification queries (run manually after migration)
-- ──────────────────────────────────────────────────────────────────

-- (1) Front-desk dashboard for Glitz & Glam:
--   SELECT public.sbp_front_desk_dashboard(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
--   );
--   Expected: jsonb with 'ok':true, 'counts', 'arrivals', 'departures',
--   'in_house', 'vacant_rooms' arrays.

-- (2) Walk-in test (replace <room-uuid> with a real vacant room id):
--   SELECT public.sbp_walkin_check_in(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     jsonb_build_object(
--       'customer_name',   'Test Walk-in',
--       'customer_phone',  '9999999999',
--       'customer_wa',     '9999999999',
--       'num_adults',      1,
--       'num_children',    0,
--       'num_nights',      1,
--       'room_id',         '<room-uuid>',
--       'rate_per_night',  600,
--       'id_proof_type',   'aadhaar',
--       'id_proof_number', '1234 5678 9012'
--     )
--   );
--   Expected: { ok: true, booking_id: '...', folio: { ... } }

-- ──────────────── End of 026_hotel_phase2_frontdesk.sql ────────────
