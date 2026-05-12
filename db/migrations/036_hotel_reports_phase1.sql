-- ════════════════════════════════════════════════════════════════════
-- Migration 036 — Hotel Reports Phase 1 (021B-C)
--
-- Three RPCs for the new Hotel Reports tabs:
--   1. sbp_hotel_kpis              — Occupancy %, ADR, RevPAR + supporting stats
--   2. sbp_hotel_arrivals_departures — date-range arrivals + departures
--   3. sbp_hotel_in_house          — currently checked-in guests
--
-- All return jsonb {ok, ...} envelope. All enforce shop ownership.
-- KPI formulas follow industry standard (STR, Hotelogix, Cloudbeds):
--   • Occupancy %   = Room-nights sold / Available room-nights × 100
--   • ADR (₹)       = Room revenue / Room-nights sold
--   • RevPAR (₹)    = Room revenue / Available room-nights
--                  (= Occupancy × ADR / 100, by definition)
--
-- Room-nights counted only for bookings that ACTUALLY OCCURRED:
--   status IN ('checked_in', 'checked_out')
-- Cancellations and no-shows excluded (industry standard).
--
-- Revenue source: sbp_bookings.room_total (= rate_per_night × num_nights,
-- exclusive of GST and extras). For partial date ranges, revenue is
-- distributed evenly across nights.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- Helper: shop ownership check (reused across RPCs)
-- ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sbp_check_shop_owner(p_shop_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_owner_id uuid;
BEGIN
  SELECT owner_id INTO v_owner_id FROM shops WHERE id = p_shop_id;
  IF v_owner_id IS NULL THEN RETURN false; END IF;
  RETURN v_owner_id = auth.uid();
END;
$$;
GRANT EXECUTE ON FUNCTION public._sbp_check_shop_owner(uuid) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 1. sbp_hotel_kpis(p_shop_id, p_from, p_to)
--    Returns occupancy / ADR / RevPAR for the date range.
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_hotel_kpis(
  p_shop_id  uuid,
  p_from     date,
  p_to       date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_total_rooms        int;
  v_days               int;
  v_available_nights   int;
  v_room_nights_sold   numeric := 0;
  v_room_revenue       numeric := 0;
  v_occupancy_pct      numeric := 0;
  v_adr                numeric := 0;
  v_revpar             numeric := 0;
  -- Supporting counts
  v_bookings_count     int := 0;
  v_arrivals_count     int := 0;
  v_departures_count   int := 0;
  v_cancellations      int := 0;
  v_no_shows           int := 0;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date_range');
  END IF;

  -- Inclusive days count
  v_days := (p_to - p_from) + 1;

  -- Total active rooms (constant for now — future: handle rooms going
  -- in/out of service mid-range via a history table)
  SELECT COUNT(*) INTO v_total_rooms
  FROM sbp_rooms
  WHERE shop_id = p_shop_id AND active = true;

  v_available_nights := v_total_rooms * v_days;

  -- Room-nights sold + revenue, distributed across the date range.
  -- For each booking that overlaps the range, compute the number of
  -- nights within the range and multiply by per-night rate.
  -- Bookings span [check_in_date, check_out_date) — the checkout date
  -- itself isn't a stay night (standard hospitality convention).
  WITH overlap AS (
    SELECT
      b.id,
      b.num_nights,
      b.room_total,
      b.rate_per_night,
      GREATEST(b.check_in_date, p_from)                AS overlap_start,
      LEAST(b.check_out_date, p_to + INTERVAL '1 day') AS overlap_end_ex
    FROM sbp_bookings b
    WHERE b.shop_id = p_shop_id
      AND b.status IN ('checked_in', 'checked_out')
      AND b.check_in_date  <= p_to
      AND b.check_out_date >  p_from
  )
  SELECT
    COALESCE(SUM(GREATEST(0, (overlap_end_ex::date - overlap_start::date))), 0),
    COALESCE(SUM(GREATEST(0, (overlap_end_ex::date - overlap_start::date)) * rate_per_night), 0)
  INTO v_room_nights_sold, v_room_revenue
  FROM overlap;

  -- KPIs (handle div-by-zero)
  IF v_available_nights > 0 THEN
    v_occupancy_pct := ROUND((v_room_nights_sold / v_available_nights * 100)::numeric, 2);
    v_revpar        := ROUND((v_room_revenue   / v_available_nights)::numeric, 2);
  END IF;
  IF v_room_nights_sold > 0 THEN
    v_adr := ROUND((v_room_revenue / v_room_nights_sold)::numeric, 2);
  END IF;

  -- Supporting counts (for context cards in UI)
  SELECT COUNT(*) INTO v_bookings_count
    FROM sbp_bookings b
   WHERE b.shop_id = p_shop_id
     AND b.status IN ('checked_in', 'checked_out')
     AND b.check_in_date <= p_to
     AND b.check_out_date > p_from;

  SELECT COUNT(*) INTO v_arrivals_count
    FROM sbp_bookings b
   WHERE b.shop_id = p_shop_id
     AND b.check_in_date BETWEEN p_from AND p_to
     AND b.status IN ('confirmed', 'checked_in', 'checked_out');

  SELECT COUNT(*) INTO v_departures_count
    FROM sbp_bookings b
   WHERE b.shop_id = p_shop_id
     AND b.check_out_date BETWEEN p_from AND p_to
     AND b.status IN ('checked_in', 'checked_out');

  SELECT COUNT(*) INTO v_cancellations
    FROM sbp_bookings b
   WHERE b.shop_id = p_shop_id
     AND b.status = 'cancelled'
     AND b.cancelled_at::date BETWEEN p_from AND p_to;

  SELECT COUNT(*) INTO v_no_shows
    FROM sbp_bookings b
   WHERE b.shop_id = p_shop_id
     AND b.status = 'no_show'
     AND b.check_in_date BETWEEN p_from AND p_to;

  RETURN jsonb_build_object(
    'ok', true,
    'period', jsonb_build_object(
      'from', p_from,
      'to',   p_to,
      'days', v_days
    ),
    'kpis', jsonb_build_object(
      'occupancy_pct',    v_occupancy_pct,
      'adr',              v_adr,
      'revpar',           v_revpar,
      'room_nights_sold', v_room_nights_sold,
      'available_nights', v_available_nights,
      'room_revenue',     v_room_revenue,
      'total_rooms',      v_total_rooms
    ),
    'counts', jsonb_build_object(
      'bookings',      v_bookings_count,
      'arrivals',      v_arrivals_count,
      'departures',    v_departures_count,
      'cancellations', v_cancellations,
      'no_shows',      v_no_shows
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_hotel_kpis(uuid, date, date) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 2. sbp_hotel_arrivals_departures(p_shop_id, p_from, p_to)
--    Returns two ordered lists: arrivals + departures
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_hotel_arrivals_departures(
  p_shop_id  uuid,
  p_from     date,
  p_to       date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_arrivals   jsonb;
  v_departures jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date_range');
  END IF;

  -- Arrivals: bookings with check_in_date in range, status not cancelled/no_show
  SELECT COALESCE(jsonb_agg(row_to_jsonb(a) ORDER BY a.check_in_date, a.customer_name), '[]'::jsonb)
    INTO v_arrivals
    FROM (
      SELECT
        b.id                                              AS booking_id,
        b.customer_name,
        b.customer_phone,
        b.num_adults,
        b.num_children,
        b.check_in_date,
        b.check_out_date,
        b.num_nights,
        b.room_id,
        b.room_number_snapshot,
        b.room_type_snapshot,
        b.status,
        b.source,
        b.grand_total,
        b.id_proof_type,
        b.id_proof_number,
        r.room_number                                     AS current_room_number
      FROM sbp_bookings b
      LEFT JOIN sbp_rooms r ON r.id = b.room_id
      WHERE b.shop_id = p_shop_id
        AND b.check_in_date BETWEEN p_from AND p_to
        AND b.status IN ('pending', 'confirmed', 'checked_in', 'checked_out')
    ) a;

  -- Departures: bookings with check_out_date in range, status checked_in/out
  SELECT COALESCE(jsonb_agg(row_to_jsonb(d) ORDER BY d.check_out_date, d.customer_name), '[]'::jsonb)
    INTO v_departures
    FROM (
      SELECT
        b.id                                              AS booking_id,
        b.customer_name,
        b.customer_phone,
        b.num_adults,
        b.num_children,
        b.check_in_date,
        b.check_out_date,
        b.num_nights,
        b.room_id,
        b.room_number_snapshot,
        b.room_type_snapshot,
        b.status,
        b.source,
        b.grand_total,
        b.checked_out_at,
        b.bill_id,
        r.room_number                                     AS current_room_number
      FROM sbp_bookings b
      LEFT JOIN sbp_rooms r ON r.id = b.room_id
      WHERE b.shop_id = p_shop_id
        AND b.check_out_date BETWEEN p_from AND p_to
        AND b.status IN ('checked_in', 'checked_out')
    ) d;

  RETURN jsonb_build_object(
    'ok', true,
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'arrivals',   v_arrivals,
    'departures', v_departures,
    'counts', jsonb_build_object(
      'arrivals',   jsonb_array_length(v_arrivals),
      'departures', jsonb_array_length(v_departures)
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_hotel_arrivals_departures(uuid, date, date) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 3. sbp_hotel_in_house(p_shop_id, p_as_of_date)
--    Currently checked-in guests on a given date.
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_hotel_in_house(
  p_shop_id    uuid,
  p_as_of_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_guests jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- In-house = checked in on/before the date AND not yet checked out
  -- (or scheduled check-out > as_of_date for "still staying")
  SELECT COALESCE(jsonb_agg(row_to_jsonb(g) ORDER BY g.room_sort, g.customer_name), '[]'::jsonb)
    INTO v_guests
    FROM (
      SELECT
        b.id                              AS booking_id,
        b.customer_name,
        b.customer_phone,
        b.num_adults,
        b.num_children,
        b.check_in_date,
        b.check_out_date,
        b.num_nights,
        b.room_id,
        r.room_number,
        r.floor,
        b.room_type_snapshot,
        b.rate_per_night,
        b.room_total,
        b.grand_total,
        b.id_proof_type,
        b.id_proof_number,
        b.source,
        b.checked_in_at,
        (p_as_of_date - b.check_in_date)                              AS nights_so_far,
        (b.check_out_date - p_as_of_date)                             AS nights_remaining,
        -- Sort key: numeric room_number when possible, else string
        COALESCE(NULLIF(regexp_replace(COALESCE(r.room_number, ''), '\D', '', 'g'), '')::int, 999999) AS room_sort
      FROM sbp_bookings b
      LEFT JOIN sbp_rooms r ON r.id = b.room_id
      WHERE b.shop_id = p_shop_id
        AND b.status = 'checked_in'
        AND b.check_in_date  <= p_as_of_date
        AND b.check_out_date >  p_as_of_date
    ) g;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_date', p_as_of_date,
    'guests', v_guests,
    'count',  jsonb_array_length(v_guests)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_hotel_in_house(uuid, date) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- End of migration 036
-- ══════════════════════════════════════════════════════════════════
