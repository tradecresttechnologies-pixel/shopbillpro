-- ════════════════════════════════════════════════════════════════════
-- Migration 037 — Hotfix for 036 (row_to_jsonb → to_jsonb)
--
-- Bug: Migration 036 used `row_to_jsonb(alias)` which fails with
--   "function row_to_jsonb(record) does not exist"
-- in this Supabase setup. The codebase has standardized on `to_jsonb()`
-- (22 existing call sites, 0 row_to_jsonb call sites). This hotfix
-- replaces both affected RPCs to use to_jsonb instead.
--
-- Only sbp_hotel_arrivals_departures + sbp_hotel_in_house affected.
-- sbp_hotel_kpis is untouched (does not use row_to_jsonb).
-- ════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════
-- Replace sbp_hotel_arrivals_departures (use to_jsonb)
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

  -- Arrivals
  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.check_in_date, a.customer_name), '[]'::jsonb)
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

  -- Departures
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.check_out_date, d.customer_name), '[]'::jsonb)
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
-- Replace sbp_hotel_in_house (use to_jsonb)
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

  SELECT COALESCE(jsonb_agg(to_jsonb(g) ORDER BY g.room_sort, g.customer_name), '[]'::jsonb)
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


-- ════════════════════════════════════════════════════════════════════
-- End of migration 037
-- ════════════════════════════════════════════════════════════════════
