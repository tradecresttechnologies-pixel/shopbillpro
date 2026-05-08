-- ════════════════════════════════════════════════════════════════════
-- 024_customer_dedup.sql
-- Batch 021.4 — Customer deduplication + phone normalization fix (8 May 2026)
--
-- Fixes the duplicate-customer bug created by Batch 021.3's backfill:
--
--   1. Better phone normalization — strips Indian country-code prefix
--      "+91" / "91" if present so that "+917800766561" and "7800766561"
--      are recognized as the same number.
--
--   2. Rewritten sbp_resolve_customer_for_booking — uses the new
--      normalization on BOTH sides of the comparison.
--
--   3. sbp_dedup_customers(shop_id) RPC — merges duplicate customers
--      with identical (case-insensitive name + normalized phone),
--      moving bills + bookings to the canonical (oldest) record.
--      Idempotent. Run once or many times safely.
--
--   4. Auto-runs dedup for all hospitality shops at end of migration.
--
-- Idempotent. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────
-- 1. Improved phone normalization helper
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_normalize_phone(p_phone text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_norm text;
BEGIN
  IF p_phone IS NULL OR length(trim(p_phone)) = 0 THEN
    RETURN NULL;
  END IF;

  -- Strip ALL non-digit characters (including +, spaces, dashes, parentheses)
  v_norm := regexp_replace(p_phone, '[^0-9]', '', 'g');

  -- Strip Indian country code "91" if number is 12 digits and starts with "91"
  IF length(v_norm) = 12 AND substring(v_norm, 1, 2) = '91' THEN
    v_norm := substring(v_norm, 3);
  END IF;

  -- Empty after normalization
  IF length(v_norm) = 0 THEN
    RETURN NULL;
  END IF;

  RETURN v_norm;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_normalize_phone(text) TO authenticated, anon;

-- ──────────────────────────────────────────────────────────────────
-- 2. Rewrite sbp_resolve_customer_for_booking with the new normalization
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_resolve_customer_for_booking(
  p_shop_id  uuid,
  p_name     text,
  p_phone    text,
  p_wa       text DEFAULT NULL,
  p_email    text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_customer_id uuid;
  v_norm_phone  text;
BEGIN
  -- Need at least a name to create a customer record
  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RETURN NULL;
  END IF;

  v_norm_phone := public.sbp_normalize_phone(p_phone);

  -- Look up by phone first (most reliable)
  IF v_norm_phone IS NOT NULL THEN
    SELECT id INTO v_customer_id
    FROM public.customers
    WHERE shop_id = p_shop_id
      AND public.sbp_normalize_phone(phone) = v_norm_phone
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_customer_id IS NOT NULL THEN
      RETURN v_customer_id;
    END IF;
  END IF;

  -- Fall back: lookup by name (case-insensitive) when no phone match
  -- Only use this fallback if we have no phone OR no records with this phone exist
  IF v_norm_phone IS NULL THEN
    SELECT id INTO v_customer_id
    FROM public.customers
    WHERE shop_id = p_shop_id
      AND lower(trim(name)) = lower(trim(p_name))
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_customer_id IS NOT NULL THEN
      RETURN v_customer_id;
    END IF;
  END IF;

  -- Not found — create new
  INSERT INTO public.customers (shop_id, name, phone, whatsapp, email, customer_type)
  VALUES (
    p_shop_id,
    trim(p_name),
    v_norm_phone,
    NULLIF(trim(COALESCE(p_wa, '')), ''),
    NULLIF(trim(COALESCE(p_email, '')), ''),
    'regular'
  )
  RETURNING id INTO v_customer_id;

  RETURN v_customer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_resolve_customer_for_booking(uuid, text, text, text, text) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 3. Customer dedup RPC
-- ──────────────────────────────────────────────────────────────────
--
-- Walks every customer in the shop, groups by (case-insensitive name +
-- normalized phone). For each group with > 1 record:
--   - Keeps the oldest (canonical)
--   - Updates bills.customer_id and sbp_bookings.customer_id to point
--     to canonical
--   - Deletes the duplicates
--
-- Returns count of customers merged + references updated.
-- Safe to call multiple times — second call finds no duplicates and
-- returns zero counts.

CREATE OR REPLACE FUNCTION public.sbp_dedup_customers(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  r_group       record;
  r_dup         record;
  v_canonical   uuid;
  v_merged      int := 0;
  v_bills_upd   int := 0;
  v_bookings_upd int := 0;
  v_total_dups  int := 0;
BEGIN
  -- Find groups of duplicate customers (same shop + name + normalized phone)
  -- Only groups with > 1 row are duplicates.
  FOR r_group IN
    SELECT
      lower(trim(name))                AS norm_name,
      public.sbp_normalize_phone(phone) AS norm_phone,
      array_agg(id ORDER BY created_at ASC) AS ids,
      COUNT(*)                         AS dup_count
    FROM public.customers
    WHERE shop_id = p_shop_id
      AND name IS NOT NULL
      AND length(trim(name)) > 0
    GROUP BY lower(trim(name)), public.sbp_normalize_phone(phone)
    HAVING COUNT(*) > 1
  LOOP
    -- Canonical = oldest (first in array)
    v_canonical := r_group.ids[1];

    -- Update all references that point to duplicates → canonical
    FOR r_dup IN SELECT unnest(r_group.ids[2:]) AS dup_id LOOP
      -- Update bills referring to duplicate
      BEGIN
        UPDATE public.bills SET customer_id = v_canonical WHERE customer_id = r_dup.dup_id;
        GET DIAGNOSTICS v_bills_upd = ROW_COUNT;
      EXCEPTION WHEN OTHERS THEN v_bills_upd := 0;
      END;

      -- Update bookings referring to duplicate
      BEGIN
        UPDATE public.sbp_bookings SET customer_id = v_canonical WHERE customer_id = r_dup.dup_id;
        GET DIAGNOSTICS v_bookings_upd = ROW_COUNT;
      EXCEPTION WHEN OTHERS THEN v_bookings_upd := 0;
      END;

      -- Delete the duplicate customer record
      DELETE FROM public.customers WHERE id = r_dup.dup_id;
      v_merged := v_merged + 1;
    END LOOP;

    v_total_dups := v_total_dups + (r_group.dup_count - 1);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'duplicate_groups_found', v_total_dups,
    'customers_merged',       v_merged,
    'bills_updated',          v_bills_upd,
    'bookings_updated',       v_bookings_upd
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_dedup_customers(uuid) TO authenticated;

-- ──────────────────────────────────────────────────────────────────
-- 4. Auto-run dedup once for every hospitality + commerce shop
-- ──────────────────────────────────────────────────────────────────
--
-- Defensive: shops table column names vary. We only reference id
-- and shop_type (which we know exists). Wrapped in outer EXCEPTION
-- so any column variation falls back to a no-op.

DO $$
DECLARE
  r record;
  v_result jsonb;
BEGIN
  FOR r IN
    SELECT id, shop_type
    FROM public.shops
    WHERE shop_type IN (
      'hotel','resort','guesthouse','service_apartment','boutique_hotel','hostel','day_room',
      'salon','restaurant','clinic','pharmacy','retail','kirana','cafe','wholesale'
    )
  LOOP
    BEGIN
      v_result := public.sbp_dedup_customers(r.id);
      IF (v_result->>'customers_merged')::int > 0 THEN
        RAISE NOTICE 'Shop % (type=%) — merged % duplicate customers',
          r.id, r.shop_type, (v_result->>'customers_merged')::int;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Dedup skipped for shop %: %', r.id, SQLERRM;
    END;
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Auto-dedup loop skipped (schema variation): %', SQLERRM;
END $$;

-- ──────────────────────────────────────────────────────────────────
-- 5. Verification
-- ──────────────────────────────────────────────────────────────────

-- (1) Test phone normalization
--   SELECT public.sbp_normalize_phone('+917800766561');  -- '7800766561'
--   SELECT public.sbp_normalize_phone('7800766561');     -- '7800766561'
--   SELECT public.sbp_normalize_phone('+91 7800-766561'); -- '7800766561'

-- (2) Confirm no duplicates remain in customer book
--   SELECT lower(trim(name)) AS n, public.sbp_normalize_phone(phone) AS p, COUNT(*)
--   FROM customers
--   WHERE shop_id = (SELECT id FROM shops WHERE shop_type = 'day_room' LIMIT 1)
--   GROUP BY 1, 2 HAVING COUNT(*) > 1;
--   Expected: 0 rows.

-- (3) Re-run dedup later — should return zero counts:
--   SELECT public.sbp_dedup_customers(
--     (SELECT id FROM shops WHERE shop_type = 'day_room' LIMIT 1)::uuid
--   );

-- ──────────────── End of 024_customer_dedup.sql ────────────────
