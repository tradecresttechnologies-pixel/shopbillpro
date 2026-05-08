-- ════════════════════════════════════════════════════════════════════
-- 022_hotel_v2_phase1.sql
-- Batch 021 — Hotel rebuild Phase 1 (8 May 2026)
--
-- Grounded in HOTEL_BUSINESS_MODEL.md v1.0
--
-- This migration ships the most-urgent corrections from the domain audit:
--
--   1. GST per folio line — extras now carry their own gst_rate +
--      hsn_sac_code, room GST is auto-derived from rate slab.
--      (FIXES the bug Vinay flagged: bills generating without GST.)
--
--   2. Advance payment tracking on bookings — small Indian hotels
--      always take ₹500-2000 to confirm a booking. Now first-class.
--
--   3. Foreign guest flag + minimal Form C fields (passport, visa,
--      country) — full Form C generator UI lands in Batch 021B.
--      This is laid down NOW so beta hotels with even one foreign
--      guest can stay legal.
--
--   4. Expanded filter values for sbp_bookings_list:
--      'in_house', 'arrivals', 'departures', 'checked_out_today',
--      'foreign' — what real front-desk staff actually need.
--
--   5. Helper functions sbp_hotel_room_gst_for_rate() and
--      sbp_hotel_extra_gst_for_category() — pure functions for slab
--      lookup, used by app + RPCs.
--
--   6. Rewritten sbp_bookings_check_out — now returns folio with
--      per-line CGST+SGST breakdown + room slab info.
--
-- Idempotent. Safe to re-run. ALL columns nullable or with sensible
-- defaults; existing bookings unaffected.
-- ════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- 1. Extend sbp_booking_extras with GST fields
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE sbp_booking_extras
  ADD COLUMN IF NOT EXISTS gst_rate       numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS hsn_sac_code   text,
  ADD COLUMN IF NOT EXISTS gst_inclusive  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS cgst_amount    numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sgst_amount    numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS taxable_amount numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_with_gst numeric NOT NULL DEFAULT 0;

COMMENT ON COLUMN sbp_booking_extras.gst_rate       IS 'GST percentage for this line (0/5/12/18/28). Default 0 for backward compat; new entries should set this.';
COMMENT ON COLUMN sbp_booking_extras.hsn_sac_code   IS 'HSN/SAC code: 996331 for F&B, 999722 spa, 999719 laundry, etc.';
COMMENT ON COLUMN sbp_booking_extras.gst_inclusive  IS 'If true, unit_price includes GST; computed taxable amount backs out the tax.';

-- ──────────────────────────────────────────────────────────────────
-- 2. Advance payment tracking on bookings
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE sbp_bookings
  ADD COLUMN IF NOT EXISTS advance_amount        numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS advance_paid_at       timestamptz,
  ADD COLUMN IF NOT EXISTS advance_payment_mode  text
    CHECK (advance_payment_mode IS NULL OR advance_payment_mode IN ('cash','upi','card','bank_transfer','ota_prepaid','other')),
  ADD COLUMN IF NOT EXISTS advance_reference     text;

-- ──────────────────────────────────────────────────────────────────
-- 3. Foreign-guest flag + minimum Form C fields
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE sbp_bookings
  ADD COLUMN IF NOT EXISTS is_foreign           boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS guest_country        text,         -- ISO country name for foreign
  ADD COLUMN IF NOT EXISTS passport_number      text,
  ADD COLUMN IF NOT EXISTS passport_expiry      date,
  ADD COLUMN IF NOT EXISTS visa_number          text,
  ADD COLUMN IF NOT EXISTS visa_type            text,
  ADD COLUMN IF NOT EXISTS visa_expiry          date,
  ADD COLUMN IF NOT EXISTS arrival_in_india_date date,
  ADD COLUMN IF NOT EXISTS intended_departure_date date,
  ADD COLUMN IF NOT EXISTS address_abroad       text,
  ADD COLUMN IF NOT EXISTS next_address_in_india text,
  ADD COLUMN IF NOT EXISTS purpose_of_visit     text,
  ADD COLUMN IF NOT EXISTS form_c_submitted_at  timestamptz,
  ADD COLUMN IF NOT EXISTS form_c_reference     text;

CREATE INDEX IF NOT EXISTS idx_bookings_foreign
  ON sbp_bookings(shop_id, is_foreign) WHERE is_foreign = true;

COMMENT ON COLUMN sbp_bookings.is_foreign IS 'Triggers Form C compliance flow. Statutory under Immigration & Foreigners Act 2025.';

-- ──────────────────────────────────────────────────────────────────
-- 4. GST helper functions (pure, immutable)
-- ──────────────────────────────────────────────────────────────────

-- Map a room rate to its statutory GST slab (post-Sep-2025 reform)
CREATE OR REPLACE FUNCTION public.sbp_hotel_room_gst_for_rate(p_rate numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_rate IS NULL OR p_rate <= 0 THEN 0
    WHEN p_rate <= 1000  THEN 0      -- Exempt
    WHEN p_rate <= 7500  THEN 5      -- 5% no ITC
    ELSE 18                          -- 18% with ITC
  END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_hotel_room_gst_for_rate(numeric) TO authenticated, anon;

-- Suggested GST per extra category (non-specified premises = our 1-3 star target)
CREATE OR REPLACE FUNCTION public.sbp_hotel_extra_gst_for_category(p_category text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE LOWER(COALESCE(p_category, ''))
    WHEN 'food'      THEN 5      -- F&B in non-specified premises
    WHEN 'laundry'   THEN 18
    WHEN 'minibar'   THEN 18     -- conservative; alcohol is excise but app abstracts
    WHEN 'service'   THEN 18     -- spa, wellness, etc.
    WHEN 'telephone' THEN 18
    WHEN 'transport' THEN 5      -- cab service GST
    WHEN 'other'     THEN 18
    ELSE 18
  END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_hotel_extra_gst_for_category(text) TO authenticated, anon;

-- HSN/SAC code suggestion per category
CREATE OR REPLACE FUNCTION public.sbp_hotel_hsn_for_category(p_category text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE LOWER(COALESCE(p_category, ''))
    WHEN 'food'      THEN '996331'   -- Restaurant services
    WHEN 'laundry'   THEN '999719'   -- Other personal services
    WHEN 'minibar'   THEN '996331'
    WHEN 'service'   THEN '999722'   -- Spa, wellness
    WHEN 'telephone' THEN '998414'   -- Telecom
    WHEN 'transport' THEN '996412'   -- Passenger transport
    ELSE NULL
  END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_hotel_hsn_for_category(text) TO authenticated, anon;

-- ──────────────────────────────────────────────────────────────────
-- 5. Trigger: auto-compute GST amounts on extras when row is written
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_booking_extras_compute_gst()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_line_amount numeric;
  v_taxable     numeric;
  v_gst_total   numeric;
BEGIN
  v_line_amount := COALESCE(NEW.qty, 1) * COALESCE(NEW.unit_price, 0);
  NEW.amount := v_line_amount;

  IF COALESCE(NEW.gst_rate, 0) <= 0 THEN
    NEW.taxable_amount := v_line_amount;
    NEW.cgst_amount    := 0;
    NEW.sgst_amount    := 0;
    NEW.total_with_gst := v_line_amount;
  ELSIF NEW.gst_inclusive THEN
    -- price includes GST; back out the tax
    v_taxable := ROUND((v_line_amount * 100.0 / (100.0 + NEW.gst_rate))::numeric, 2);
    NEW.taxable_amount := v_taxable;
    v_gst_total := v_line_amount - v_taxable;
    NEW.cgst_amount    := ROUND((v_gst_total / 2.0)::numeric, 2);
    NEW.sgst_amount    := v_gst_total - NEW.cgst_amount;
    NEW.total_with_gst := v_line_amount;
  ELSE
    -- exclusive: line amount + GST on top
    NEW.taxable_amount := v_line_amount;
    v_gst_total := ROUND((v_line_amount * NEW.gst_rate / 100.0)::numeric, 2);
    NEW.cgst_amount    := ROUND((v_gst_total / 2.0)::numeric, 2);
    NEW.sgst_amount    := v_gst_total - NEW.cgst_amount;
    NEW.total_with_gst := v_line_amount + v_gst_total;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_booking_extras_compute_gst ON sbp_booking_extras;
CREATE TRIGGER trg_booking_extras_compute_gst
  BEFORE INSERT OR UPDATE ON sbp_booking_extras
  FOR EACH ROW
  EXECUTE FUNCTION public.sbp_booking_extras_compute_gst();

-- Backfill existing rows so they have correct totals
UPDATE sbp_booking_extras
SET unit_price = unit_price
WHERE total_with_gst = 0 AND amount > 0;
-- (No-op assignment fires the trigger and recomputes)

-- ──────────────────────────────────────────────────────────────────
-- 6. Rewrite sbp_booking_extras_add to accept gst_rate
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_booking_extras_add(
  p_shop_id    uuid,
  p_booking_id uuid,
  p_data       jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check     jsonb;
  v_b         sbp_bookings%ROWTYPE;
  v_id        uuid;
  v_category  text;
  v_gst_rate  numeric;
  v_hsn       text;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM sbp_bookings WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;
  IF v_b.status NOT IN ('checked_in','pending','confirmed') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_active', 'status', v_b.status);
  END IF;

  v_category := COALESCE(NULLIF(p_data->>'category', ''), 'service');

  -- Auto-suggest GST rate if caller didn't pass one
  IF p_data ? 'gst_rate' AND (p_data->>'gst_rate') <> '' THEN
    v_gst_rate := (p_data->>'gst_rate')::numeric;
  ELSE
    v_gst_rate := sbp_hotel_extra_gst_for_category(v_category);
  END IF;

  -- Auto-suggest HSN if not provided
  v_hsn := COALESCE(NULLIF(p_data->>'hsn_sac_code', ''),
                    sbp_hotel_hsn_for_category(v_category));

  INSERT INTO sbp_booking_extras(
    shop_id, booking_id, category, description,
    qty, unit_price, gst_rate, hsn_sac_code, gst_inclusive, added_by
  ) VALUES (
    p_shop_id, p_booking_id, v_category,
    COALESCE(NULLIF(p_data->>'description',''), 'Charge'),
    COALESCE((p_data->>'qty')::int, 1),
    COALESCE((p_data->>'unit_price')::numeric, 0),
    v_gst_rate,
    v_hsn,
    COALESCE((p_data->>'gst_inclusive')::boolean, false),
    auth.uid()
  )
  RETURNING id INTO v_id;

  -- Recompute booking's extras_total (sum of total_with_gst for proper roll-up)
  UPDATE sbp_bookings
  SET extras_total = (
    SELECT COALESCE(SUM(total_with_gst), 0)
    FROM sbp_booking_extras
    WHERE booking_id = p_booking_id
  ),
  updated_at = now()
  WHERE id = p_booking_id;

  RETURN jsonb_build_object('ok', true, 'extra_id', v_id, 'gst_rate', v_gst_rate, 'hsn_sac_code', v_hsn);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_booking_extras_add(uuid, uuid, jsonb) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 7. Update sbp_booking_extras_list to return GST fields
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_booking_extras_list(
  p_shop_id    uuid,
  p_booking_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check    jsonb;
  v_extras   jsonb;
  v_total    numeric;
  v_taxable  numeric;
  v_cgst     numeric;
  v_sgst     numeric;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'id',             id,
      'description',    description,
      'category',       category,
      'qty',            qty,
      'unit_price',     unit_price,
      'amount',         amount,
      'gst_rate',       gst_rate,
      'gst_inclusive',  gst_inclusive,
      'hsn_sac_code',   hsn_sac_code,
      'taxable_amount', taxable_amount,
      'cgst_amount',    cgst_amount,
      'sgst_amount',    sgst_amount,
      'total_with_gst', total_with_gst,
      'added_at',       added_at
    ) ORDER BY added_at), '[]'::jsonb),
    COALESCE(SUM(total_with_gst), 0),
    COALESCE(SUM(taxable_amount), 0),
    COALESCE(SUM(cgst_amount), 0),
    COALESCE(SUM(sgst_amount), 0)
  INTO v_extras, v_total, v_taxable, v_cgst, v_sgst
  FROM sbp_booking_extras
  WHERE booking_id = p_booking_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'extras',         v_extras,
    'extras_total',   v_total,
    'extras_taxable', v_taxable,
    'extras_cgst',    v_cgst,
    'extras_sgst',    v_sgst
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_booking_extras_list(uuid, uuid) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 8. Expanded sbp_bookings_list — new filter values
-- ──────────────────────────────────────────────────────────────────
--
-- Old:    'all' | 'today' | 'upcoming' | 'past'
-- New:    'all' | 'today' | 'upcoming' | 'past' |
--         'in_house' | 'arrivals' | 'departures' |
--         'checked_out_today' | 'foreign'
--
-- All existing values keep working. Just adding new ones.

CREATE OR REPLACE FUNCTION public.sbp_bookings_list(
  p_shop_id uuid,
  p_filter  text DEFAULT 'today',
  p_status_filter text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
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
        p_filter = 'all'
        OR (p_filter = 'today'    AND (b.check_in_date = v_today OR b.check_out_date = v_today OR b.status = 'checked_in'))
        OR (p_filter = 'upcoming' AND b.check_in_date >= v_today AND b.status IN ('pending','confirmed'))
        OR (p_filter = 'past'     AND (b.check_out_date < v_today OR b.status IN ('checked_out','cancelled','no_show')))
        -- ── NEW Batch 021 filters ──
        OR (p_filter = 'in_house'      AND b.status = 'checked_in')
        OR (p_filter = 'arrivals'      AND b.check_in_date  = v_today AND b.status IN ('pending','confirmed'))
        OR (p_filter = 'departures'    AND b.check_out_date = v_today AND b.status = 'checked_in')
        OR (p_filter = 'checked_out_today' AND b.status = 'checked_out' AND b.checked_out_at::date = v_today)
        OR (p_filter = 'foreign'       AND b.is_foreign = true)
      )
      AND (p_status_filter IS NULL OR p_status_filter = 'all' OR b.status = p_status_filter)
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                 f.id,
    'customer_name',      f.customer_name,
    'customer_phone',     f.customer_phone,
    'customer_wa',        f.customer_wa,
    'customer_id',        f.customer_id,
    'customer_email',     f.customer_email,
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
    'bill_id',            f.bill_id,
    -- Batch 021 new fields
    'advance_amount',     COALESCE(f.advance_amount, 0),
    'advance_paid_at',    f.advance_paid_at,
    'advance_payment_mode', f.advance_payment_mode,
    'is_foreign',         COALESCE(f.is_foreign, false),
    'guest_country',      f.guest_country,
    'passport_number',    f.passport_number,
    -- Per-rate GST slab (auto-derived)
    'room_gst_rate',      sbp_hotel_room_gst_for_rate(f.rate_per_night)
  ) ORDER BY f.check_in_date DESC, f.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM filtered f;

  RETURN jsonb_build_object('ok', true, 'bookings', v_rows, 'today', v_today);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bookings_list(uuid, text, text) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 9. Rewrite sbp_bookings_check_out — folio with per-line GST
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_bookings_check_out(
  p_shop_id    uuid,
  p_booking_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check        jsonb;
  v_b            sbp_bookings%ROWTYPE;
  v_room_gst     numeric;
  v_room_taxable numeric;
  v_room_cgst    numeric;
  v_room_sgst    numeric;
  v_room_total   numeric;
  v_extras_total numeric;
  v_extras_taxable numeric;
  v_extras_cgst  numeric;
  v_extras_sgst  numeric;
  v_extras       jsonb;
  v_advance      numeric;
  v_grand        numeric;
  v_balance_due  numeric;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT * INTO v_b FROM sbp_bookings WHERE id = p_booking_id AND shop_id = p_shop_id;
  IF v_b.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'booking_not_found');
  END IF;
  IF v_b.status <> 'checked_in' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_checked_in', 'current_status', v_b.status);
  END IF;

  -- ── ROOM CHARGES ──
  -- Auto-derive GST slab from rate (statutory: 0/5/18 by tariff)
  v_room_gst   := sbp_hotel_room_gst_for_rate(v_b.rate_per_night);
  v_room_taxable := v_b.room_total;          -- room_total = rate * nights, exclusive
  IF v_room_gst > 0 THEN
    v_room_cgst := ROUND((v_room_taxable * v_room_gst / 200.0)::numeric, 2);  -- /200 = half of /100
    v_room_sgst := ROUND((v_room_taxable * v_room_gst / 100.0 - v_room_cgst)::numeric, 2);
  ELSE
    v_room_cgst := 0;
    v_room_sgst := 0;
  END IF;
  v_room_total := v_room_taxable + v_room_cgst + v_room_sgst;

  -- ── EXTRAS ──
  SELECT
    COALESCE(SUM(total_with_gst),  0),
    COALESCE(SUM(taxable_amount),  0),
    COALESCE(SUM(cgst_amount),     0),
    COALESCE(SUM(sgst_amount),     0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'id',             id,
      'description',    description,
      'category',       category,
      'qty',            qty,
      'unit_price',     unit_price,
      'amount',         amount,
      'gst_rate',       gst_rate,
      'gst_inclusive',  gst_inclusive,
      'hsn_sac_code',   hsn_sac_code,
      'taxable_amount', taxable_amount,
      'cgst_amount',    cgst_amount,
      'sgst_amount',    sgst_amount,
      'total_with_gst', total_with_gst,
      'added_at',       added_at
    ) ORDER BY added_at), '[]'::jsonb)
  INTO v_extras_total, v_extras_taxable, v_extras_cgst, v_extras_sgst, v_extras
  FROM sbp_booking_extras
  WHERE booking_id = p_booking_id;

  -- ── TOTALS ──
  v_advance     := COALESCE(v_b.advance_amount, 0);
  v_grand       := v_room_total + v_extras_total - COALESCE(v_b.discount_amount, 0);
  v_balance_due := v_grand - v_advance;

  -- ── UPDATE BOOKING ──
  UPDATE sbp_bookings SET
    status         = 'checked_out',
    checked_out_at = now(),
    extras_total   = v_extras_total,
    tax_amount     = v_room_cgst + v_room_sgst + v_extras_cgst + v_extras_sgst,
    grand_total    = v_grand,
    updated_at     = now()
  WHERE id = p_booking_id;

  -- Free the room → cleaning state
  IF v_b.room_id IS NOT NULL THEN
    UPDATE sbp_rooms SET status = 'cleaning', updated_at = now() WHERE id = v_b.room_id;
  END IF;

  -- ── RETURN FOLIO ──
  RETURN jsonb_build_object(
    'ok',         true,
    'booking_id', p_booking_id,
    'folio', jsonb_build_object(
      -- Customer
      'customer_name',   v_b.customer_name,
      'customer_id',     v_b.customer_id,
      'customer_phone',  v_b.customer_phone,
      'customer_wa',     v_b.customer_wa,
      'customer_email',  v_b.customer_email,
      -- Stay
      'check_in_date',   v_b.check_in_date,
      'check_out_date',  v_b.check_out_date,
      'num_nights',      v_b.num_nights,
      'room_number',     COALESCE(v_b.room_number_snapshot, (SELECT room_number FROM sbp_rooms WHERE id = v_b.room_id)),
      'room_type',       COALESCE(v_b.room_type_snapshot,   (SELECT name FROM sbp_room_types WHERE id = v_b.room_type_id)),
      'rate_per_night',  v_b.rate_per_night,
      -- Foreign
      'is_foreign',      v_b.is_foreign,
      'guest_country',   v_b.guest_country,
      -- Room totals (with per-line GST)
      'room', jsonb_build_object(
        'taxable_amount', v_room_taxable,
        'gst_rate',       v_room_gst,
        'cgst_amount',    v_room_cgst,
        'sgst_amount',    v_room_sgst,
        'total_with_gst', v_room_total,
        'hsn_sac_code',   '996311'
      ),
      -- Extras totals
      'extras',          v_extras,
      'extras_total',    v_extras_total,
      'extras_taxable',  v_extras_taxable,
      'extras_cgst',     v_extras_cgst,
      'extras_sgst',     v_extras_sgst,
      -- Bill totals
      'discount_amount', COALESCE(v_b.discount_amount, 0),
      'cgst_total',      v_room_cgst + v_extras_cgst,
      'sgst_total',      v_room_sgst + v_extras_sgst,
      'tax_total',       v_room_cgst + v_room_sgst + v_extras_cgst + v_extras_sgst,
      'grand_total',     v_grand,
      'advance_amount',  v_advance,
      'balance_due',     v_balance_due
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bookings_check_out(uuid, uuid) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 9b. Update sbp_bookings_create — also insert advance + foreign fields
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_bookings_create(p_shop_id uuid, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_check    jsonb;
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
  v_advance  numeric;
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
    -- Batch 021 — advance
    advance_amount, advance_paid_at, advance_payment_mode, advance_reference,
    -- Batch 021 — foreign guest
    is_foreign, guest_country, passport_number, passport_expiry,
    visa_number, visa_type, visa_expiry,
    arrival_in_india_date, intended_departure_date,
    address_abroad, next_address_in_india, purpose_of_visit
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
    p_data->>'notes', p_data->>'internal_notes',
    -- Batch 021 advance
    v_advance,
    CASE WHEN v_advance > 0 THEN now() ELSE NULL END,
    NULLIF(p_data->>'advance_payment_mode',''),
    NULLIF(p_data->>'advance_reference',''),
    -- Batch 021 foreign
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

  RETURN jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_bookings_create(uuid, jsonb) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 10. Verification queries
-- ──────────────────────────────────────────────────────────────────

-- (1) Confirm new columns on extras
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'sbp_booking_extras' AND column_name IN
--     ('gst_rate','hsn_sac_code','gst_inclusive','cgst_amount','sgst_amount','taxable_amount','total_with_gst');
--   Expected: 7 rows.

-- (2) Confirm new columns on bookings
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name = 'sbp_bookings' AND column_name IN
--     ('advance_amount','is_foreign','passport_number','visa_number','guest_country');
--   Expected: 5 rows (full set is 13 new cols).

-- (3) Test GST helper
--   SELECT public.sbp_hotel_room_gst_for_rate(900);    -- 0
--   SELECT public.sbp_hotel_room_gst_for_rate(2500);   -- 5
--   SELECT public.sbp_hotel_room_gst_for_rate(8000);   -- 18
--   SELECT public.sbp_hotel_extra_gst_for_category('food');     -- 5
--   SELECT public.sbp_hotel_extra_gst_for_category('service');  -- 18

-- (4) Test new filter values
--   SELECT public.sbp_bookings_list(
--     (SELECT id FROM shops WHERE shop_type = 'hotel' LIMIT 1)::uuid,
--     'in_house',
--     NULL
--   );

-- ──────────────── End of 022_hotel_v2_phase1.sql ────────────────
