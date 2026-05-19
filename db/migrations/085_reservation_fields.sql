-- ════════════════════════════════════════════════════════════════════
-- 085_reservation_fields.sql  (CORRECTED v2)
-- ════════════════════════════════════════════════════════════════════
-- BUGFIX NOTE
--   v1 joined sbp_authorized_users ON user_id = created_by.
--   sbp_authorized_users has NO user_id column (real schema: id, shop_id,
--   user_name, auth_role, pin_hash, can_authorize, active — PIN-based,
--   not auth.uid-linked). That bad join made sbp_reservations_list throw
--   → PostgREST HTTP 400 → "Could not load".
--
--   FIX: restore sbp_reservations_list to the exact working 083 form
--   (no join). "Made-by name" is DROPPED — the data model does not
--   cleanly resolve created_by (auth.uid) → a staff name via available
--   tables, and shipping it broke the page. created_by is still stored
--   (083) for future use if a proper identity table is ever wired.
--
-- WHAT THIS MIGRATION DOES (safe, independent of the removed join):
--   1. ADD COLUMN table_preference, occasion (idempotent).
--   2. sbp_reservations_list -> restored to working 083 form. Since it
--      SELECTs tr.* , the two new columns flow to the UI automatically.
--   3. sbp_reservation_create_staff -> accept table_preference + occasion.
--
-- DEPLOY ORDER: after 083 + 084. IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- 1. New columns
ALTER TABLE sbp_table_reservations
  ADD COLUMN IF NOT EXISTS table_preference text,
  ADD COLUMN IF NOT EXISTS occasion         text;

-- 2. List RPC: RESTORE exact working 083 form (no join)
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

-- 3. Staff create RPC: accept table_preference + occasion
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
    table_preference, occasion,
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
    nullif(trim(p_payload->>'table_preference'),''),
    nullif(trim(p_payload->>'occasion'),''),
    'confirmed', 'staff', auth.uid()
  ) RETURNING id INTO v_res_id;

  RETURN jsonb_build_object('ok', true, 'reservation_id', v_res_id,
                            'status', 'confirmed');
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
