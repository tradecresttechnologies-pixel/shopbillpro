-- ════════════════════════════════════════════════════════════════════
-- 099_reservation_polish.sql  (v2 — corrected for actual schema)
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   Polishes the existing reservation system with:
--   1. Per-shop settings: block window before/after arrival, no-show timeout
--   2. Reservation columns: notification tracking + auto-release timestamp
--   3. RPCs:
--      • sbp_reservation_notify_sent(p_id) — record notify click (shop_id resolved from auth)
--      • sbp_reservations_blocked_tables(p_shop_id) — currently-blocked
--        table_ids with reservation context (for tables.html visual state)
--      • sbp_reservation_auto_release_no_shows() — sweep function (no args,
--        runs across ALL shops, callable by cron OR manually)
--      • sbp_update_reservation_settings(p_block_before, p_block_after, p_no_show)
--      • sbp_get_reservation_settings()
--   4. pg_cron job that calls sbp_reservation_auto_release_no_shows every 5 min
--
-- SCHEMA NOTES (per reservations.html v1 audit, 22-May-26):
--   • Reservation table is `sbp_table_reservations`
--   • Columns used: id, shop_id, customer_name, customer_phone, customer_email,
--     reservation_date (date), time_slot (text "HH:MM" or "HH:MM:SS"),
--     party_size, status, table_id, occasion, source, notes, confirmation_code,
--     table_preference
--   • The "expected arrival" is constructed as: reservation_date + time_slot::time
--     interpreted as IST (Asia/Kolkata).
--   • RPC JSON outputs use neutral keys `guest_name` / `phone` (mapped from
--     customer_name / customer_phone) so the API surface stays clean.
--
-- DEPENDENCIES
--   • sbp_table_reservations table exists with the columns above.
--   • shops table has owner_id column.
--   • pg_cron extension installed (Supabase: enable via dashboard).
--
-- DEPLOY ORDER
--   1. Verify schema:
--        SELECT to_regclass('public.sbp_table_reservations');     -- not null
--        SELECT column_name FROM information_schema.columns
--        WHERE table_name='sbp_table_reservations'
--          AND column_name IN ('customer_name','customer_phone',
--              'reservation_date','time_slot','status','party_size','table_id');
--        -- expected: 7 rows
--   2. Enable pg_cron in Supabase Dashboard → Database → Extensions
--   3. Run this migration
--   4. Verify cron job:
--        SELECT * FROM cron.job WHERE jobname='sbp_reservation_no_show_sweep';
--
-- ROLLBACK
--   SELECT cron.unschedule('sbp_reservation_no_show_sweep');
--   ALTER TABLE shops
--     DROP COLUMN IF EXISTS reservation_block_before_min,
--     DROP COLUMN IF EXISTS reservation_block_after_min,
--     DROP COLUMN IF EXISTS reservation_no_show_min;
--   ALTER TABLE sbp_table_reservations
--     DROP COLUMN IF EXISTS notified_at,
--     DROP COLUMN IF EXISTS notification_count,
--     DROP COLUMN IF EXISTS auto_released_at;
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 0. SCHEMA SAFETY CHECKS ───────────────────────────────────────
DO $$
BEGIN
  IF to_regclass('public.sbp_table_reservations') IS NULL THEN
    RAISE EXCEPTION 'sbp_table_reservations table does not exist. Deploy earlier reservation migrations first.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sbp_table_reservations'
      AND column_name='customer_name'
  ) THEN
    RAISE EXCEPTION 'sbp_table_reservations.customer_name column missing. Check reservation schema deployment.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sbp_table_reservations'
      AND column_name='reservation_date'
  ) THEN
    RAISE EXCEPTION 'sbp_table_reservations.reservation_date column missing. Check reservation schema deployment.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sbp_table_reservations'
      AND column_name='time_slot'
  ) THEN
    RAISE EXCEPTION 'sbp_table_reservations.time_slot column missing. Check reservation schema deployment.';
  END IF;
END $$;

-- ── 1. SHOP SETTINGS COLUMNS ──────────────────────────────────────
ALTER TABLE shops
  ADD COLUMN IF NOT EXISTS reservation_block_before_min int NOT NULL DEFAULT 15,
  ADD COLUMN IF NOT EXISTS reservation_block_after_min  int NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS reservation_no_show_min      int NOT NULL DEFAULT 30;

COMMENT ON COLUMN shops.reservation_block_before_min IS 'Minutes BEFORE expected arrival that table is reserved-blocked';
COMMENT ON COLUMN shops.reservation_block_after_min  IS 'Minutes AFTER expected arrival that table stays reserved-blocked';
COMMENT ON COLUMN shops.reservation_no_show_min      IS 'Minutes after expected arrival to auto-mark no-show (0 = never)';

-- ── 2. RESERVATION COLUMNS ────────────────────────────────────────
ALTER TABLE sbp_table_reservations
  ADD COLUMN IF NOT EXISTS notified_at         timestamptz,
  ADD COLUMN IF NOT EXISTS notification_count  int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS auto_released_at    timestamptz;

COMMENT ON COLUMN sbp_table_reservations.notified_at        IS 'Last time WhatsApp/SMS notify button was clicked';
COMMENT ON COLUMN sbp_table_reservations.notification_count IS 'How many notifications sent (first + reminders)';
COMMENT ON COLUMN sbp_table_reservations.auto_released_at   IS 'When the no-show cron auto-released this reservation';

CREATE INDEX IF NOT EXISTS idx_sbp_reservations_no_show_sweep
  ON sbp_table_reservations(shop_id, status, reservation_date)
  WHERE status = 'confirmed' AND auto_released_at IS NULL;

-- ── 3. HELPER: CONSTRUCT EXPECTED ARRIVAL TIMESTAMPTZ ─────────────
-- Combines reservation_date (date) + time_slot (text "HH:MM" or "HH:MM:SS")
-- as IST and returns timestamptz. Returns NULL if either is missing/invalid.
DROP FUNCTION IF EXISTS _sbp_reservation_expected_at(date, text);
CREATE OR REPLACE FUNCTION _sbp_reservation_expected_at(p_date date, p_time text)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_ts timestamp;
BEGIN
  IF p_date IS NULL OR p_time IS NULL OR p_time = '' THEN
    RETURN NULL;
  END IF;
  BEGIN
    v_ts := (p_date::text || ' ' || p_time)::timestamp;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
  RETURN v_ts AT TIME ZONE 'Asia/Kolkata';
END;
$$;

GRANT EXECUTE ON FUNCTION _sbp_reservation_expected_at(date, text) TO authenticated;

-- ── 4. NOTIFY-SENT RPC ────────────────────────────────────────────
-- Resolves shop_id internally from auth.uid() (owner OR authorized user).
-- Reservation must belong to caller's shop or the call fails.
DROP FUNCTION IF EXISTS sbp_reservation_notify_sent(uuid);
DROP FUNCTION IF EXISTS sbp_reservation_notify_sent(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_reservation_notify_sent(
  p_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now       timestamptz := now();
  v_new_count int;
BEGIN
  -- Restrict to reservations owned by the caller's shop (or shops they
  -- have authorized-user access to)
  UPDATE sbp_table_reservations r
  SET notified_at        = v_now,
      notification_count = notification_count + 1
  WHERE r.id = p_id
    AND (
      EXISTS (SELECT 1 FROM shops s WHERE s.id = r.shop_id AND s.owner_id = auth.uid())
      OR EXISTS (SELECT 1 FROM sbp_authorized_users au
                 WHERE au.shop_id = r.shop_id AND au.user_id = auth.uid())
    )
  RETURNING notification_count INTO v_new_count;

  IF v_new_count IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reservation_not_found_or_unauthorized');
  END IF;

  RETURN jsonb_build_object(
    'ok',                 true,
    'notified_at',        v_now,
    'notification_count', v_new_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_reservation_notify_sent(uuid) TO authenticated;

-- ── 5. BLOCKED-TABLES LIST RPC ────────────────────────────────────
-- JSON output keys use neutral names (guest_name, phone) mapped from
-- customer_name / customer_phone columns.
DROP FUNCTION IF EXISTS sbp_reservations_blocked_tables(uuid);
CREATE OR REPLACE FUNCTION sbp_reservations_blocked_tables(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id   uuid;
  v_before_min int;
  v_after_min  int;
  v_now        timestamptz := now();
  v_blocked    jsonb;
BEGIN
  SELECT owner_id, reservation_block_before_min, reservation_block_after_min
    INTO v_owner_id, v_before_min, v_after_min
  FROM shops WHERE id = p_shop_id;

  IF v_owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_owner_id <> auth.uid() THEN
    IF NOT EXISTS (
      SELECT 1 FROM sbp_authorized_users
      WHERE shop_id = p_shop_id AND user_id = auth.uid()
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
    END IF;
  END IF;

  v_before_min := COALESCE(v_before_min, 15);
  v_after_min  := COALESCE(v_after_min, 120);

  SELECT jsonb_agg(jsonb_build_object(
    'reservation_id',  r.id,
    'table_id',        r.table_id,
    'guest_name',      r.customer_name,
    'party_size',      r.party_size,
    'expected_at',     _sbp_reservation_expected_at(r.reservation_date, r.time_slot),
    'block_starts_at', _sbp_reservation_expected_at(r.reservation_date, r.time_slot)
                         - (v_before_min || ' minutes')::interval,
    'block_ends_at',   _sbp_reservation_expected_at(r.reservation_date, r.time_slot)
                         + (v_after_min  || ' minutes')::interval,
    'phone',           r.customer_phone,
    'notified',        (r.notified_at IS NOT NULL)
  ))
  INTO v_blocked
  FROM sbp_table_reservations r
  WHERE r.shop_id = p_shop_id
    AND r.status = 'confirmed'
    AND r.table_id IS NOT NULL
    AND r.auto_released_at IS NULL
    AND _sbp_reservation_expected_at(r.reservation_date, r.time_slot) IS NOT NULL
    AND v_now >= _sbp_reservation_expected_at(r.reservation_date, r.time_slot)
                   - (v_before_min || ' minutes')::interval
    AND v_now <  _sbp_reservation_expected_at(r.reservation_date, r.time_slot)
                   + (v_after_min  || ' minutes')::interval;

  RETURN jsonb_build_object(
    'ok',      true,
    'blocked', COALESCE(v_blocked, '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_reservations_blocked_tables(uuid) TO authenticated;

-- ── 6. AUTO-RELEASE NO-SHOWS (CRON SWEEP) ─────────────────────────
DROP FUNCTION IF EXISTS sbp_reservation_auto_release_no_shows();
CREATE OR REPLACE FUNCTION sbp_reservation_auto_release_no_shows()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now      timestamptz := now();
  v_swept    int := 0;
  v_shops    int := 0;
BEGIN
  WITH to_release AS (
    SELECT r.id, r.shop_id
    FROM sbp_table_reservations r
    JOIN shops s ON s.id = r.shop_id
    WHERE r.status = 'confirmed'
      AND r.auto_released_at IS NULL
      AND s.reservation_no_show_min > 0
      AND _sbp_reservation_expected_at(r.reservation_date, r.time_slot) IS NOT NULL
      AND _sbp_reservation_expected_at(r.reservation_date, r.time_slot)
            + (s.reservation_no_show_min || ' minutes')::interval < v_now
  ),
  upd AS (
    UPDATE sbp_table_reservations
    SET status = 'no_show',
        auto_released_at = v_now
    WHERE id IN (SELECT id FROM to_release)
      AND status = 'confirmed'
    RETURNING shop_id
  )
  SELECT count(*), count(DISTINCT shop_id)
  INTO v_swept, v_shops
  FROM upd;

  RETURN jsonb_build_object(
    'ok',              true,
    'swept_count',     v_swept,
    'shops_affected',  v_shops,
    'ran_at',          v_now
  );
END;
$$;

-- Service-role function. No GRANT to authenticated.

-- ── 7. UPDATE SETTINGS RPC ────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_update_reservation_settings(int, int, int);
CREATE OR REPLACE FUNCTION sbp_update_reservation_settings(
  p_block_before_min int,
  p_block_after_min  int,
  p_no_show_min      int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shop_id uuid;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop_for_user');
  END IF;

  IF p_block_before_min < 0 OR p_block_before_min > 240 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'block_before_out_of_range', 'min', 0, 'max', 240);
  END IF;
  IF p_block_after_min < 0 OR p_block_after_min > 480 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'block_after_out_of_range', 'min', 0, 'max', 480);
  END IF;
  IF p_no_show_min < 0 OR p_no_show_min > 240 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_show_out_of_range', 'min', 0, 'max', 240);
  END IF;

  UPDATE shops
  SET reservation_block_before_min = p_block_before_min,
      reservation_block_after_min  = p_block_after_min,
      reservation_no_show_min      = p_no_show_min
  WHERE id = v_shop_id;

  RETURN jsonb_build_object(
    'ok',                            true,
    'reservation_block_before_min',  p_block_before_min,
    'reservation_block_after_min',   p_block_after_min,
    'reservation_no_show_min',       p_no_show_min
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_update_reservation_settings(int, int, int) TO authenticated;

-- ── 8. GET SETTINGS RPC ───────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_get_reservation_settings();
CREATE OR REPLACE FUNCTION sbp_get_reservation_settings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec record;
BEGIN
  SELECT reservation_block_before_min,
         reservation_block_after_min,
         reservation_no_show_min
  INTO v_rec
  FROM shops WHERE owner_id = auth.uid() LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop_for_user');
  END IF;

  RETURN jsonb_build_object(
    'ok',                            true,
    'reservation_block_before_min',  COALESCE(v_rec.reservation_block_before_min, 15),
    'reservation_block_after_min',   COALESCE(v_rec.reservation_block_after_min, 120),
    'reservation_no_show_min',       COALESCE(v_rec.reservation_no_show_min, 30)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_reservation_settings() TO authenticated;

-- ── 9. PG_CRON JOB — 5 MIN SWEEP ──────────────────────────────────
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('sbp_reservation_no_show_sweep');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    PERFORM cron.schedule(
      'sbp_reservation_no_show_sweep',
      '*/5 * * * *',
      $cron$SELECT public.sbp_reservation_auto_release_no_shows();$cron$
    );
    RAISE NOTICE 'pg_cron job sbp_reservation_no_show_sweep scheduled (every 5 min)';
  EXCEPTION WHEN undefined_function THEN
    RAISE WARNING 'pg_cron extension not installed. Enable it via Supabase Dashboard → Database → Extensions, then re-run only the cron.schedule block.';
  WHEN insufficient_privilege THEN
    RAISE WARNING 'pg_cron requires superuser role. In Supabase, the postgres user has it — re-run from SQL Editor as postgres.';
  WHEN OTHERS THEN
    RAISE WARNING 'pg_cron schedule failed: %', SQLERRM;
  END;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- POST-DEPLOY VERIFICATION
-- ════════════════════════════════════════════════════════════════════
-- 1. New columns exist on shops:
--    SELECT reservation_block_before_min, reservation_block_after_min, reservation_no_show_min
--    FROM shops LIMIT 1;
--
-- 2. New columns exist on sbp_table_reservations:
--    SELECT notified_at, notification_count, auto_released_at
--    FROM sbp_table_reservations LIMIT 1;
--
-- 3. RPCs registered (expect 6 rows):
--    SELECT proname FROM pg_proc WHERE proname IN (
--      '_sbp_reservation_expected_at',
--      'sbp_reservation_notify_sent',
--      'sbp_reservations_blocked_tables',
--      'sbp_reservation_auto_release_no_shows',
--      'sbp_update_reservation_settings',
--      'sbp_get_reservation_settings'
--    );
--
-- 4. Cron job scheduled:
--    SELECT jobname, schedule, command FROM cron.job
--    WHERE jobname = 'sbp_reservation_no_show_sweep';
--
-- 5. Manual sweep test (returns {"ok":true, "swept_count":0, ...}):
--    SELECT sbp_reservation_auto_release_no_shows();
--
-- 6. Settings round-trip (as logged-in user):
--    SELECT sbp_get_reservation_settings();
--    SELECT sbp_update_reservation_settings(20, 90, 45);
--    SELECT sbp_get_reservation_settings();
-- ════════════════════════════════════════════════════════════════════
