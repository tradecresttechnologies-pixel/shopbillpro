-- ════════════════════════════════════════════════════════════════════
-- 087_1_drop_hospitality_branch.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   Replaces 087's sbp_get_website_generation_context to drop the
--   hospitality branch entirely. Every shop_type now computes
--   highlights_data from sbp_services uniformly.
--
-- WHY (decided 19 May 2026 with no real users yet)
--   • Live audit showed shops.shop_type for actual hotels is plain 'hotel'
--     — NOT the underscored variants (general_hotel/luxury_hotel/etc)
--     that 087's hospitality list checked. So hotels were falling
--     through as non-hospitality anyway. The branch was buggy on arrival.
--   • Even WITH the list right, separate verification proved hotels
--     never had real room/amenity injection (the Edge Function reads
--     ctxResp.data.rooms / .amenities which never existed in the
--     response — it always fell back to "invent 3 plausible rooms").
--   • Simpler, single path is cleaner than preserving a broken
--     special-case. Hotels with services in sbp_services (e.g.
--     "Deluxe Room ₹3,500") now get them. Hotels with empty services
--     fall through to the 088 prompt's "if empty, invent" rule —
--     no worse than the current state.
--   • Proper sbp_room_types injection for hotels is a future task
--     (tracked in roadmap, not in this change).
--
-- WHAT CHANGES vs 087
--   • Removed: v_is_hospitality variable + the 11-shop_type CASE
--   • Removed: is_hospitality field from return
--   • Unchanged: every other field (hero/gallery/services_count/about/
--     hours/tagline/shop_type/highlights_data)
--   • highlights_data computed uniformly for every shop
--
-- DEPLOY ORDER: after 087 (replaces its function).
-- Then 088 (prompt v4) and Edge Function patch. Order matters only
-- because 088's prompt references {HIGHLIGHTS_DATA}; deploy them in
-- this file's order.
-- IDEMPOTENT - safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

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
  -- Owner check
  SELECT owner_id, shop_type INTO v_owner, v_shop_type
  FROM shops WHERE id = p_shop_id;

  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- content_json (gallery, about, hours, tagline) — unchanged from 054/087
  SELECT content_json INTO v_content
  FROM sbp_shop_websites
  WHERE shop_id = p_shop_id
  LIMIT 1;

  v_gallery     := COALESCE(v_content -> 'gallery', '[]'::jsonb);
  v_has_gallery := jsonb_array_length(v_gallery) > 0;
  v_hero_url    := CASE WHEN v_has_gallery THEN v_gallery ->> 0 ELSE '' END;

  -- services count (prompt context) — unchanged
  SELECT COUNT(*) INTO v_services_n
  FROM sbp_services
  WHERE shop_id = p_shop_id AND active = true;

  -- highlights_data: top 8 services for EVERY shop_type (no special-case)
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'name',        s.name,
               'price',       s.price,
               'description', s.description,
               'category',    s.category
             )
             ORDER BY s.display_order, s.created_at
           ),
           '[]'::jsonb
         )
    INTO v_highlights
    FROM (
      SELECT name, price, description, category, display_order, created_at
      FROM sbp_services
      WHERE shop_id = p_shop_id
        AND active = true
        AND COALESCE(is_available, true) = true
      ORDER BY display_order, created_at
      LIMIT 8
    ) s;

  -- COALESCE again at the outer level — jsonb_agg returns NULL when the
  -- subquery has zero rows; the inner COALESCE wraps the agg's body but
  -- not the outer SELECT INTO. Belt-and-braces.
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

-- Verify after deploy:
-- SELECT sbp_get_website_generation_context('<shop-uuid>');
-- → response contains shop_type (string) + highlights_data (array, possibly empty)
-- → no is_hospitality field anymore
