-- ════════════════════════════════════════════════════════════════════
-- 016_change_shop_type.sql
-- Batch 016 — Allow shop owners to change their business type (6 May 2026)
--
-- Until now, the business type chosen at signup (via SBPWizard) was
-- locked forever. If a shopkeeper tapped the wrong category by mistake
-- — or pivoted their business — there was no way to fix it.
--
-- This migration adds:
--   1. shops.shop_type_changed_at column for rate-limiting
--   2. sbp_change_shop_type(shop_id, new_type) RPC with:
--        - owner check
--        - new type validation (must exist in sbp_business_categories)
--        - 24-hour rate limit (locked decision per Vinay)
--        - returns full new category info for client UI refresh
--   3. NO plan gate — basic identity should always be editable
--
-- API-FIRST per locked rule. jsonb {ok,error,...} envelope, idempotent
-- where possible, owner-checked, safe to retry.
-- ════════════════════════════════════════════════════════════════════


-- ── 1. Add tracking column for rate-limit ──────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'shops' AND column_name = 'shop_type_changed_at'
  ) THEN
    ALTER TABLE shops ADD COLUMN shop_type_changed_at timestamptz;
    COMMENT ON COLUMN shops.shop_type_changed_at IS
      'Timestamp of last shop_type change via sbp_change_shop_type. NULL means never changed since signup. Used for 24h rate-limit.';
  END IF;
END $$;


-- ── 2. RPC: Change shop type ───────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_change_shop_type(
  p_shop_id       uuid,
  p_new_shop_type text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id     uuid;
  v_shop        record;
  v_cat         record;
  v_old_cat     record;
  v_hours_since numeric;
BEGIN
  -- ── Auth
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  -- ── Param validation
  IF p_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_id_required');
  END IF;
  IF p_new_shop_type IS NULL OR length(trim(p_new_shop_type)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_type_required');
  END IF;

  -- ── Load shop + verify ownership
  SELECT id, owner_id, shop_type, shop_type_changed_at
    INTO v_shop
    FROM shops
   WHERE id = p_shop_id;

  IF v_shop.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_shop.owner_id <> v_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- ── No-op check: same type as current
  IF v_shop.shop_type = p_new_shop_type THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'no_change',
      'current', p_new_shop_type
    );
  END IF;

  -- ── Rate limit: once per 24 hours (locked decision)
  IF v_shop.shop_type_changed_at IS NOT NULL THEN
    v_hours_since := EXTRACT(EPOCH FROM (now() - v_shop.shop_type_changed_at)) / 3600.0;
    IF v_hours_since < 24 THEN
      RETURN jsonb_build_object(
        'ok',              false,
        'error',           'rate_limited',
        'hours_remaining', ROUND((24 - v_hours_since)::numeric, 1),
        'last_changed_at', v_shop.shop_type_changed_at,
        'message',         'You can change business type once every 24 hours'
      );
    END IF;
  END IF;

  -- ── Validate new shop_type exists in catalog
  SELECT code, name_en, name_hi, emoji, macro_code, module_profile
    INTO v_cat
    FROM sbp_business_categories
   WHERE code = p_new_shop_type;

  IF v_cat.code IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'invalid_shop_type',
      'attempted', p_new_shop_type
    );
  END IF;

  -- ── Get old category info (for response — useful for "changed from X to Y" message)
  SELECT code, name_en, emoji, macro_code, module_profile
    INTO v_old_cat
    FROM sbp_business_categories
   WHERE code = v_shop.shop_type;

  -- ── Apply the change
  UPDATE shops
     SET shop_type            = p_new_shop_type,
         shop_type_changed_at = now()
   WHERE id = p_shop_id;

  -- ── Return rich response so client can update localStorage + UI without re-fetching
  RETURN jsonb_build_object(
    'ok', true,
    'old', jsonb_build_object(
      'code',           v_shop.shop_type,
      'name_en',        v_old_cat.name_en,
      'emoji',          v_old_cat.emoji,
      'macro_code',     v_old_cat.macro_code,
      'module_profile', v_old_cat.module_profile
    ),
    'new', jsonb_build_object(
      'code',           v_cat.code,
      'name_en',        v_cat.name_en,
      'name_hi',        v_cat.name_hi,
      'emoji',          v_cat.emoji,
      'macro_code',     v_cat.macro_code,
      'module_profile', v_cat.module_profile
    ),
    'changed_at', now(),
    'next_change_allowed_at', now() + interval '24 hours'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_change_shop_type(uuid, text) TO authenticated;


-- ── 3. RPC: Get current shop_type with rich category info ──────────
-- Lightweight read used by settings.html to display current type info
-- without making the client do a JOIN against the categories table.

CREATE OR REPLACE FUNCTION sbp_get_my_shop_type(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_user_id uuid;
  v_shop    record;
  v_cat     record;
  v_can_change_now boolean := true;
  v_hours_remaining numeric := 0;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  SELECT id, owner_id, shop_type, shop_type_changed_at
    INTO v_shop
    FROM shops
   WHERE id = p_shop_id;

  IF v_shop.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_shop.owner_id <> v_user_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Rate-limit status
  IF v_shop.shop_type_changed_at IS NOT NULL THEN
    v_hours_remaining := 24 - EXTRACT(EPOCH FROM (now() - v_shop.shop_type_changed_at)) / 3600.0;
    IF v_hours_remaining > 0 THEN
      v_can_change_now := false;
    ELSE
      v_hours_remaining := 0;
    END IF;
  END IF;

  -- Lookup category
  SELECT code, name_en, name_hi, emoji, macro_code, module_profile
    INTO v_cat
    FROM sbp_business_categories
   WHERE code = v_shop.shop_type;

  RETURN jsonb_build_object(
    'ok', true,
    'shop_type',       v_shop.shop_type,
    'name_en',         COALESCE(v_cat.name_en, v_shop.shop_type),
    'name_hi',         v_cat.name_hi,
    'emoji',           COALESCE(v_cat.emoji, '🏪'),
    'macro_code',      v_cat.macro_code,
    'module_profile',  COALESCE(v_cat.module_profile, 'standard'),
    'last_changed_at', v_shop.shop_type_changed_at,
    'can_change_now',  v_can_change_now,
    'hours_remaining', ROUND(v_hours_remaining::numeric, 1)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_my_shop_type(uuid) TO authenticated;


-- ── Verification (paste in Supabase SQL Editor):
--
-- (1) Column added:
--     SELECT column_name FROM information_schema.columns
--     WHERE table_name = 'shops' AND column_name = 'shop_type_changed_at';
--
-- (2) RPCs registered:
--     SELECT proname FROM pg_proc
--     WHERE proname IN ('sbp_change_shop_type','sbp_get_my_shop_type');
--     -- Expected: 2 rows
--
-- (3) Smoke test (replace with real UUIDs):
--     SELECT sbp_get_my_shop_type('<shop-uuid>');
--     SELECT sbp_change_shop_type('<shop-uuid>', 'kirana');


-- ════════════════════════════════════════════════════════════════════
-- DONE
-- ════════════════════════════════════════════════════════════════════
