-- ════════════════════════════════════════════════════════════════════
-- 089_signature_services.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   Implements DESIGN_01 Decision 1 — "is_featured" toggle on sbp_services.
--
--   1. ALTER TABLE sbp_services ADD COLUMN is_featured boolean DEFAULT false.
--   2. Update sbp_services_create / sbp_services_update to accept is_featured
--      (and is_available — closes the 066 gap where the column was added
--      to the table but never wired into these RPCs).
--   3. Update sbp_get_website_generation_context to prefer is_featured=true
--      services for highlights_data, falling back to top-N by display_order
--      when the shop has no featured items.
--
-- WHY
--   Current site renders ALL services (top 8 by display_order) as featured
--   cards on the home page. Restaurant Indian Curry test showed this means
--   the home page reads as the full menu, not a curated showcase.
--   DESIGN_01 fix: owner explicitly marks 3 best dishes/services as
--   "signature" via a ⭐ toggle on each service. Those become the home-page
--   featured cards.
--
-- FALLBACK
--   If a shop has no services with is_featured=true, the RPC returns the
--   first N by display_order (same behaviour as today). No empty-state
--   sites. Existing shops are not penalised for not curating.
--
-- DEPLOY ORDER
--   After 088 (prompt v4 active). Idempotent.
--
-- VERIFY AFTER DEPLOY
--   1. Run: SELECT sbp_get_website_generation_context('<shop-uuid>');
--      → highlights_data should be ≤ 8 items, prefers is_featured=true ones.
--   2. In services.html UI, toggle ⭐ on a service → save → re-query →
--      that service appears first in highlights_data.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. New column ───────────────────────────────────────────────────
ALTER TABLE sbp_services
  ADD COLUMN IF NOT EXISTS is_featured boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_sbp_services_featured
  ON sbp_services (shop_id, is_featured)
  WHERE is_featured = true;

-- ── 2a. sbp_services_create — accept is_featured + is_available ────
DROP FUNCTION IF EXISTS sbp_services_create(uuid, jsonb);
CREATE OR REPLACE FUNCTION sbp_services_create(
  p_shop_id uuid,
  p_data    jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_id uuid;
  v_name text;
  v_price numeric;
  v_max_order int;
BEGIN
  -- Ownership check
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Validate required fields
  v_name := trim(coalesce(p_data->>'name', ''));
  IF length(v_name) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_required');
  END IF;

  v_price := coalesce((p_data->>'price')::numeric, 0);
  IF v_price < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_price');
  END IF;

  SELECT COALESCE(MAX(display_order), -1) + 1 INTO v_max_order
  FROM sbp_services WHERE shop_id = p_shop_id;

  INSERT INTO sbp_services(
    shop_id, name, description, category,
    price, duration_minutes, gst_rate, hsn_sac_code,
    image_url, display_order, active,
    is_available, is_featured
  ) VALUES (
    p_shop_id,
    v_name,
    NULLIF(trim(coalesce(p_data->>'description', '')), ''),
    NULLIF(trim(coalesce(p_data->>'category', '')), ''),
    v_price,
    NULLIF((p_data->>'duration_minutes')::int, 0),
    coalesce((p_data->>'gst_rate')::numeric, 0),
    NULLIF(trim(coalesce(p_data->>'hsn_sac_code', '')), ''),
    NULLIF(trim(coalesce(p_data->>'image_url', '')), ''),
    coalesce((p_data->>'display_order')::int, v_max_order),
    coalesce((p_data->>'active')::boolean, true),
    coalesce((p_data->>'is_available')::boolean, true),
    coalesce((p_data->>'is_featured')::boolean, false)
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'service_id', v_id);
END;
$$;

-- ── 2b. sbp_services_update — accept is_featured + is_available ────
DROP FUNCTION IF EXISTS sbp_services_update(uuid, jsonb);
CREATE OR REPLACE FUNCTION sbp_services_update(
  p_service_id uuid,
  p_patch      jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
BEGIN
  SELECT shop_id INTO v_shop_id FROM sbp_services WHERE id = p_service_id;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = v_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'patch_must_be_object');
  END IF;

  IF p_patch ? 'name' AND length(trim(p_patch->>'name')) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_required');
  END IF;
  IF p_patch ? 'price' AND (p_patch->>'price')::numeric < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_price');
  END IF;

  UPDATE sbp_services SET
    name             = COALESCE(NULLIF(trim(p_patch->>'name'), ''), name),
    description      = CASE WHEN p_patch ? 'description'      THEN NULLIF(trim(p_patch->>'description'), '') ELSE description END,
    category         = CASE WHEN p_patch ? 'category'         THEN NULLIF(trim(p_patch->>'category'), '') ELSE category END,
    price            = COALESCE((p_patch->>'price')::numeric, price),
    duration_minutes = CASE WHEN p_patch ? 'duration_minutes' THEN NULLIF((p_patch->>'duration_minutes')::int, 0) ELSE duration_minutes END,
    gst_rate         = COALESCE((p_patch->>'gst_rate')::numeric, gst_rate),
    hsn_sac_code     = CASE WHEN p_patch ? 'hsn_sac_code'     THEN NULLIF(trim(p_patch->>'hsn_sac_code'), '') ELSE hsn_sac_code END,
    image_url        = CASE WHEN p_patch ? 'image_url'        THEN NULLIF(trim(p_patch->>'image_url'), '') ELSE image_url END,
    display_order    = COALESCE((p_patch->>'display_order')::int, display_order),
    active           = COALESCE((p_patch->>'active')::boolean, active),
    is_available     = COALESCE((p_patch->>'is_available')::boolean, is_available),
    is_featured      = COALESCE((p_patch->>'is_featured')::boolean, is_featured),
    updated_at       = now()
  WHERE id = p_service_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── 3. sbp_get_website_generation_context — prefer featured ────────
--   Strategy: get featured services first (ordered), then top-up to 8
--   with non-featured services by display_order. Old behaviour preserved
--   for shops without any featured items.
DROP FUNCTION IF EXISTS sbp_get_website_generation_context(uuid);
CREATE OR REPLACE FUNCTION sbp_get_website_generation_context(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_owner       uuid;
  v_shop_type   text;
  v_content     jsonb;
  v_gallery     jsonb;
  v_hero_url    text;
  v_has_gallery boolean;
  v_services_n  int;
  v_highlights  jsonb;
BEGIN
  SELECT owner_id, shop_type INTO v_owner, v_shop_type
  FROM shops WHERE id = p_shop_id;

  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  SELECT content_json INTO v_content
  FROM sbp_shop_websites WHERE shop_id = p_shop_id LIMIT 1;

  v_gallery     := COALESCE(v_content -> 'gallery', '[]'::jsonb);
  v_has_gallery := jsonb_array_length(v_gallery) > 0;
  v_hero_url    := CASE WHEN v_has_gallery THEN v_gallery ->> 0 ELSE '' END;

  SELECT COUNT(*) INTO v_services_n
  FROM sbp_services
  WHERE shop_id = p_shop_id AND active = true;

  -- Featured-first, then fill to 8 by display_order. Single SELECT,
  -- ORDER BY (is_featured DESC, display_order ASC) does exactly this.
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'name',        s.name,
               'price',       s.price,
               'description', s.description,
               'category',    s.category,
               'is_featured', s.is_featured
             )
             ORDER BY s.is_featured DESC, s.display_order ASC, s.created_at ASC
           ),
           '[]'::jsonb
         )
    INTO v_highlights
    FROM (
      SELECT name, price, description, category, is_featured,
             display_order, created_at
      FROM sbp_services
      WHERE shop_id = p_shop_id
        AND active = true
        AND COALESCE(is_available, true) = true
      ORDER BY is_featured DESC, display_order ASC, created_at ASC
      LIMIT 8
    ) s;

  v_highlights := COALESCE(v_highlights, '[]'::jsonb);

  RETURN jsonb_build_object(
    'ok',              true,
    'hero_image_url',  v_hero_url,
    'has_gallery',     v_has_gallery,
    'gallery_count',   jsonb_array_length(v_gallery),
    'services_count',  v_services_n,
    'about',           COALESCE(v_content ->> 'about', ''),
    'hours',           COALESCE(v_content ->> 'hours', ''),
    'tagline',         COALESCE(v_content ->> 'tagline', ''),
    'shop_type',       COALESCE(v_shop_type, ''),
    'highlights_data', v_highlights
  );
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
