-- ════════════════════════════════════════════════════════════════════
-- 010_service_catalog.sql
-- Universal Service Catalog (Layer 2 universal add-on per Master Plan §6.1)
--
-- Closes ~30 verticals to 80%+ in one batch:
--   Beauty & Wellness (9)  · Healthcare (7)  · Education (4)
--   Services (skilled labour, 11)  + others
--
-- API-FIRST DESIGN (per locked rule May 5 2026):
--   - All business logic in PLpgSQL RPCs (this file)
--   - jsonb {ok, error, ...data} envelope on every RPC
--   - SECURITY DEFINER + auth.uid() ownership check on admin RPCs
--   - First PUBLIC STOREFRONT RPC: sbp_get_shop_services_public()
--     anon-callable, gates by sbp_shop_websites.published flag
--   - Extends sbp_shop_websites.content_json convention for about/gallery
--
-- Deploy after: 009_loyalty.sql
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Table ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sbp_services (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id            uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  name               text NOT NULL CHECK (length(trim(name)) > 0),
  description        text,
  category           text,
  price              numeric NOT NULL DEFAULT 0 CHECK (price >= 0),
  duration_minutes   int CHECK (duration_minutes IS NULL OR duration_minutes >= 0),
  gst_rate           numeric NOT NULL DEFAULT 0 CHECK (gst_rate >= 0 AND gst_rate <= 100),
  hsn_sac_code       text,
  image_url          text,
  display_order      int NOT NULL DEFAULT 0,
  active             boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

-- ── 2. Indexes ─────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_sbp_services_shop_active
  ON sbp_services(shop_id, active, display_order)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_sbp_services_shop_all
  ON sbp_services(shop_id, display_order);

CREATE INDEX IF NOT EXISTS idx_sbp_services_category
  ON sbp_services(shop_id, category) WHERE category IS NOT NULL;

-- ── 3. Updated_at trigger ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_services_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sbp_services_updated_at ON sbp_services;
CREATE TRIGGER trg_sbp_services_updated_at
  BEFORE UPDATE ON sbp_services
  FOR EACH ROW EXECUTE FUNCTION sbp_services_set_updated_at();

-- ── 4. RLS ─────────────────────────────────────────────────────────────

ALTER TABLE sbp_services ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_services_owner ON sbp_services;
CREATE POLICY p_services_owner ON sbp_services
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));

-- (Anon access goes through SECURITY DEFINER RPC, not direct table access)

-- ── 5. Admin RPCs ──────────────────────────────────────────────────────

-- 5a. Create
CREATE OR REPLACE FUNCTION sbp_services_create(
  p_shop_id uuid,
  p_data jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
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

  -- Auto-assign display_order at end
  SELECT COALESCE(MAX(display_order), -1) + 1 INTO v_max_order
  FROM sbp_services WHERE shop_id = p_shop_id;

  INSERT INTO sbp_services(
    shop_id, name, description, category,
    price, duration_minutes, gst_rate, hsn_sac_code,
    image_url, display_order, active
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
    coalesce((p_data->>'active')::boolean, true)
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_services_create(uuid, jsonb) TO authenticated;

-- 5b. Update (partial patch via jsonb)
CREATE OR REPLACE FUNCTION sbp_services_update(
  p_service_id uuid,
  p_patch jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
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

  -- Validate name if present
  IF p_patch ? 'name' AND length(trim(p_patch->>'name')) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'name_required');
  END IF;

  -- Validate price if present
  IF p_patch ? 'price' AND (p_patch->>'price')::numeric < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_price');
  END IF;

  UPDATE sbp_services SET
    name             = COALESCE(NULLIF(trim(p_patch->>'name'), ''), name),
    description      = CASE WHEN p_patch ? 'description'    THEN NULLIF(trim(p_patch->>'description'), '') ELSE description END,
    category         = CASE WHEN p_patch ? 'category'       THEN NULLIF(trim(p_patch->>'category'), '') ELSE category END,
    price            = COALESCE((p_patch->>'price')::numeric, price),
    duration_minutes = CASE WHEN p_patch ? 'duration_minutes' THEN NULLIF((p_patch->>'duration_minutes')::int, 0) ELSE duration_minutes END,
    gst_rate         = COALESCE((p_patch->>'gst_rate')::numeric, gst_rate),
    hsn_sac_code     = CASE WHEN p_patch ? 'hsn_sac_code'   THEN NULLIF(trim(p_patch->>'hsn_sac_code'), '') ELSE hsn_sac_code END,
    image_url        = CASE WHEN p_patch ? 'image_url'      THEN NULLIF(trim(p_patch->>'image_url'), '') ELSE image_url END,
    display_order    = COALESCE((p_patch->>'display_order')::int, display_order),
    active           = COALESCE((p_patch->>'active')::boolean, active)
  WHERE id = p_service_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_services_update(uuid, jsonb) TO authenticated;

-- 5c. Delete
CREATE OR REPLACE FUNCTION sbp_services_delete(p_service_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
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

  DELETE FROM sbp_services WHERE id = p_service_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_services_delete(uuid) TO authenticated;

-- 5d. Toggle active (one-tap from list)
CREATE OR REPLACE FUNCTION sbp_services_toggle_active(p_service_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_new boolean;
BEGIN
  SELECT shop_id INTO v_shop_id FROM sbp_services WHERE id = p_service_id;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = v_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  UPDATE sbp_services SET active = NOT active
  WHERE id = p_service_id
  RETURNING active INTO v_new;

  RETURN jsonb_build_object('ok', true, 'active', v_new);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_services_toggle_active(uuid) TO authenticated;

-- 5e. Reorder (drag-drop)
CREATE OR REPLACE FUNCTION sbp_services_reorder(
  p_shop_id uuid,
  p_ordered_ids uuid[]
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  i int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF p_ordered_ids IS NULL OR array_length(p_ordered_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'empty_array');
  END IF;

  FOR i IN 1..array_length(p_ordered_ids, 1) LOOP
    UPDATE sbp_services
    SET display_order = i - 1
    WHERE id = p_ordered_ids[i] AND shop_id = p_shop_id;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'count', array_length(p_ordered_ids, 1));
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_services_reorder(uuid, uuid[]) TO authenticated;

-- 5f. List for admin (returns ALL services, active + inactive)
CREATE OR REPLACE FUNCTION sbp_services_list_admin(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.display_order, s.created_at), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, name, description, category, price, duration_minutes,
           gst_rate, hsn_sac_code, image_url, display_order, active,
           created_at, updated_at
    FROM sbp_services
    WHERE shop_id = p_shop_id
    ORDER BY display_order, created_at
  ) s;

  RETURN jsonb_build_object('ok', true, 'services', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_services_list_admin(uuid) TO authenticated;

-- ── 6. PUBLIC STOREFRONT RPC ─ first API-first anon-callable endpoint ──
-- Returns services for a published shop website, by slug.
-- Powers /s/[slug] PSP and any future external/AI-built website.
-- Resilient to abuse: only returns active services for published shops.

CREATE OR REPLACE FUNCTION sbp_get_shop_services_public(p_slug text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_published boolean;
  v_clean_slug text;
  v_rows jsonb;
BEGIN
  v_clean_slug := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean_slug) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_slug');
  END IF;

  -- Resolve slug → shop_id (only if website is published)
  SELECT w.shop_id, w.published
  INTO v_shop_id, v_published
  FROM sbp_shop_websites w
  WHERE w.slug = v_clean_slug;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found', 'services', '[]'::jsonb);
  END IF;

  IF NOT v_published THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_published', 'services', '[]'::jsonb);
  END IF;

  -- Return ONLY active services, public-safe columns only
  SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.display_order), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, name, description, category, price, duration_minutes,
           image_url, display_order
    FROM sbp_services
    WHERE shop_id = v_shop_id AND active = true
    ORDER BY display_order
  ) s;

  RETURN jsonb_build_object('ok', true, 'services', v_rows);
END;
$$;

-- Anon access — this is the public storefront entry point
GRANT EXECUTE ON FUNCTION sbp_get_shop_services_public(text) TO anon;
GRANT EXECUTE ON FUNCTION sbp_get_shop_services_public(text) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- Verification (run manually in Supabase SQL Editor):
--
-- -- 1. Table exists
-- SELECT count(*) FROM sbp_services;
--
-- -- 2. RLS enabled
-- SELECT tablename, rowsecurity FROM pg_tables WHERE tablename = 'sbp_services';
--
-- -- 3. RPCs exist
-- SELECT proname, prosecdef FROM pg_proc WHERE proname LIKE 'sbp_services%' OR proname = 'sbp_get_shop_services_public';
--
-- -- 4. Public RPC works (anon, replace 'glitz-glam' with real slug)
-- SELECT sbp_get_shop_services_public('glitz-glam');
--
-- -- 5. Smoke create (replace UUID with real shop_id)
-- SELECT sbp_services_create(
--   'YOUR-SHOP-ID-UUID',
--   '{"name":"Haircut","price":300,"duration_minutes":30,"gst_rate":18,"category":"Hair"}'::jsonb
-- );
-- ════════════════════════════════════════════════════════════════════
