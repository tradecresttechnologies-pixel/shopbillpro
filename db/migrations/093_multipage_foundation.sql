-- ════════════════════════════════════════════════════════════════════
-- 093_multipage_foundation.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT (DESIGN_02 phase M0)
--   Foundation for per-vertical multi-page websites. THIS MIGRATION
--   ADDS SCHEMA AND DUAL-WRITES; it does not change visible behavior
--   yet. Existing /s/{slug} flows continue to work unchanged.
--
--   1. New table sbp_website_pages — one row per (shop, page_slug).
--      Stores per-page generated HTML, prompt version used, timestamps,
--      and (future) AI-images-used metadata.
--   2. ai_prompt_templates: add page_slug column (NULL = legacy default,
--      applies to home page if no row exists for that page_slug).
--      Existing v6 prompt becomes the active prompt for page_slug='home'.
--   3. sbp_record_ai_website_generation: DUAL-WRITE — keeps writing
--      legacy ai_generated_html column AND writes new row to
--      sbp_website_pages with page_slug='home'. Zero change to caller.
--   4. New RPC sbp_resolve_shop_page(p_slug, p_page_slug) — mirrors
--      sbp_resolve_shop_slug return shape EXACTLY, but resolves the
--      specific page. Falls back to legacy ai_generated_html when no
--      sbp_website_pages row exists for that page (preserves existing
--      shops generated before this migration).
--
-- WHY
--   Single source of truth for multi-page generation; clean per-page
--   versioning; the legacy column stays as fallback during transition.
--   When M2 ships Business-tier per-page generation, that flow inserts
--   into sbp_website_pages for /menu, /about, /gallery, /contact —
--   home stays where M0+M1 put it.
--
-- DEPLOY ORDER: AFTER 092 (v6 prompt active). Pairs with the
--   M1 client+config changes (s.html + vercel.json) shipped alongside.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. sbp_website_pages table ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS sbp_website_pages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  page_slug       text NOT NULL,            -- 'home','menu','about','gallery','contact','rooms','services','products'...
  page_label      text,                     -- 'Home','Our Menu','About Us'... shown in nav
  generated_html  text,
  generated_at    timestamptz,
  prompt_version  int,                      -- ai_prompt_templates.version used
  display_order   int NOT NULL DEFAULT 0,   -- order in nav
  is_active       boolean NOT NULL DEFAULT true,
  ai_images_used  jsonb NOT NULL DEFAULT '[]'::jsonb,  -- for M2/V3 image-gen
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, page_slug)
);

CREATE INDEX IF NOT EXISTS idx_website_pages_shop
  ON sbp_website_pages (shop_id, is_active, display_order);

CREATE INDEX IF NOT EXISTS idx_website_pages_page
  ON sbp_website_pages (shop_id, page_slug)
  WHERE is_active = true;

-- RLS: pages are public-readable (joined by slug via the SECURITY DEFINER
-- resolver RPC, which is the only intended public read path). Direct
-- table reads are restricted; writes are restricted to shop owners.
ALTER TABLE sbp_website_pages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "website_pages_owner_all" ON sbp_website_pages;
CREATE POLICY "website_pages_owner_all"
ON sbp_website_pages
FOR ALL
TO authenticated
USING (
  EXISTS (SELECT 1 FROM shops WHERE shops.id = sbp_website_pages.shop_id AND shops.owner_id = auth.uid())
)
WITH CHECK (
  EXISTS (SELECT 1 FROM shops WHERE shops.id = sbp_website_pages.shop_id AND shops.owner_id = auth.uid())
);

-- ── 2. ai_prompt_templates: add page_slug column ───────────────────
ALTER TABLE ai_prompt_templates
  ADD COLUMN IF NOT EXISTS page_slug text;

-- Backfill existing rows: name='website_v1' versions are all for the
-- 'home' page (that's all we generate today). Set them all explicitly
-- so the resolver RPC can query by page_slug cleanly.
UPDATE ai_prompt_templates
SET page_slug = 'home'
WHERE name = 'website_v1' AND page_slug IS NULL;

-- Unique per (name, page_slug, version) so we can have multiple page
-- prompts in the same template family.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE indexname = 'idx_ai_prompt_templates_name_page_version'
  ) THEN
    CREATE UNIQUE INDEX idx_ai_prompt_templates_name_page_version
      ON ai_prompt_templates (name, COALESCE(page_slug, 'home'), version);
  END IF;
END $$;

-- ── 3. sbp_record_ai_website_generation: DUAL-WRITE ────────────────
-- Continues writing legacy ai_generated_html AND writes new pages row.
-- Zero behavior change for existing callers; the home page now exists
-- in both places.
DROP FUNCTION IF EXISTS sbp_record_ai_website_generation(jsonb);
CREATE OR REPLACE FUNCTION sbp_record_ai_website_generation(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id     uuid;
  v_website_id  uuid;
  v_slug        text;
  v_used_mo     int;
  v_used_life   int;
  v_period      date;
  v_state       jsonb;
  v_html        text;
  v_prompt_ver  int;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  v_state := sbp_get_website_builder_state();
  IF NOT COALESCE((v_state->'tier'->>'can_generate')::boolean, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'quota_exhausted',
      'reason', v_state->'tier'->>'block_reason'
    );
  END IF;

  SELECT id, slug INTO v_website_id, v_slug
  FROM sbp_shop_websites WHERE shop_id = v_shop_id;

  IF v_website_id IS NULL THEN
    v_slug := sbp_generate_slug(
      (SELECT name FROM shops WHERE id = v_shop_id),
      (SELECT city FROM shops WHERE id = v_shop_id)
    );
    INSERT INTO sbp_shop_websites (shop_id, slug, content_json)
    VALUES (v_shop_id, v_slug, sbp_default_website_content(v_shop_id))
    RETURNING id INTO v_website_id;
  END IF;

  SELECT
    CASE
      WHEN ai_regen_period_start IS NULL
        OR date_trunc('month', ai_regen_period_start) < date_trunc('month', now())
      THEN 0
      ELSE COALESCE(ai_regenerations_used, 0)
    END,
    COALESCE(ai_total_lifetime_gens, 0)
  INTO v_used_mo, v_used_life
  FROM sbp_shop_websites WHERE id = v_website_id;

  v_period := current_date;
  v_html   := p_payload->>'generated_html';

  -- Look up which prompt version is active for the home page
  SELECT version INTO v_prompt_ver
  FROM ai_prompt_templates
  WHERE name = 'website_v1'
    AND COALESCE(page_slug, 'home') = 'home'
    AND is_active = true
  ORDER BY version DESC
  LIMIT 1;

  -- Legacy write (unchanged) — keeps sbp_resolve_shop_slug working
  UPDATE sbp_shop_websites
  SET ai_generated_html      = v_html,
      ai_design_style        = COALESCE(p_payload->>'design_style', ai_design_style),
      ai_color_primary       = COALESCE(p_payload->>'color_primary', ai_color_primary),
      ai_color_primary_hex   = COALESCE(p_payload->>'color_primary_hex', ai_color_primary_hex),
      ai_color_accent        = COALESCE(p_payload->>'color_accent', ai_color_accent),
      ai_color_accent_hex    = COALESCE(p_payload->>'color_accent_hex', ai_color_accent_hex),
      ai_headline            = COALESCE(p_payload->>'headline', ai_headline),
      ai_description         = COALESCE(p_payload->>'description', ai_description),
      ai_business_type       = COALESCE(p_payload->>'business_type', ai_business_type),
      ai_provider            = COALESCE(p_payload->>'provider', 'claude'),
      ai_regenerations_used  = v_used_mo + 1,
      ai_regen_period_start  = v_period,
      ai_total_lifetime_gens = v_used_life + 1,
      ai_last_generated_at   = now(),
      updated_at             = now()
  WHERE id = v_website_id;

  -- New write — pages table
  INSERT INTO sbp_website_pages (
    shop_id, page_slug, page_label,
    generated_html, generated_at, prompt_version, display_order, is_active
  ) VALUES (
    v_shop_id, 'home', 'Home',
    v_html, now(), v_prompt_ver, 0, true
  )
  ON CONFLICT (shop_id, page_slug) DO UPDATE
  SET generated_html  = EXCLUDED.generated_html,
      generated_at    = EXCLUDED.generated_at,
      prompt_version  = EXCLUDED.prompt_version,
      is_active       = true,
      updated_at      = now();

  RETURN jsonb_build_object(
    'ok', true,
    'website_id', v_website_id,
    'slug',       v_slug,
    'page_slug',  'home'
  );
END;
$$;

-- ── 4. sbp_resolve_shop_page: new resolver for /s/{slug}/{page} ────
-- Mirrors sbp_resolve_shop_slug return shape so s.html can switch RPC
-- with minimal structural change. Behavior:
--   • If sbp_website_pages row exists for (slug→shop_id, page_slug),
--     returns that page's HTML.
--   • If page_slug='home' and no pages row exists yet, falls back to
--     sbp_shop_websites.ai_generated_html (legacy path, for shops
--     generated before this migration).
--   • Returns 'page_status' field:
--       'real'         — actual generated HTML
--       'legacy_home'  — served from legacy column
--       'business_only'— page not generated; UI should show interstitial
--       'not_found'    — page_slug not in the known list for this vertical
DROP FUNCTION IF EXISTS sbp_resolve_shop_page(text, text);
CREATE OR REPLACE FUNCTION sbp_resolve_shop_page(p_slug text, p_page_slug text DEFAULT 'home')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_row record;
  v_page_html text;
  v_merged jsonb;
  v_status text;
  v_page text;
BEGIN
  v_page := COALESCE(NULLIF(trim(p_page_slug), ''), 'home');

  SELECT
    w.id                 AS website_id,
    w.shop_id,
    w.slug,
    w.published          AS legacy_published,
    w.ai_published,
    w.ai_generated_html,
    w.content_json,
    w.updated_at,
    s.name               AS shop_name,
    s.shop_type,
    s.phone              AS shop_phone,
    s.wa                 AS shop_wa,
    s.email              AS shop_email,
    s.city               AS shop_city,
    s.address            AS shop_address,
    s.plan               AS shop_plan
  INTO v_row
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = p_slug
    AND (
      COALESCE(w.published, false) = true
      OR (COALESCE(w.ai_published, false) = true AND w.ai_generated_html IS NOT NULL)
    )
  LIMIT 1;

  IF v_row.website_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found', 'slug', p_slug);
  END IF;

  -- Look up the requested page in sbp_website_pages
  SELECT generated_html INTO v_page_html
  FROM sbp_website_pages
  WHERE shop_id = v_row.shop_id
    AND page_slug = v_page
    AND is_active = true
  LIMIT 1;

  IF v_page_html IS NOT NULL THEN
    v_status := 'real';
  ELSIF v_page = 'home' AND v_row.ai_generated_html IS NOT NULL THEN
    -- Legacy fallback for shops generated before M0
    v_page_html := v_row.ai_generated_html;
    v_status := 'legacy_home';
  ELSE
    -- Page not generated. Caller (s.html) will show interstitial.
    v_page_html := NULL;
    v_status := 'business_only';
  END IF;

  -- Merge content (same logic as sbp_resolve_shop_slug for consistency)
  v_merged := COALESCE(v_row.content_json, '{}'::jsonb)
    || jsonb_strip_nulls(jsonb_build_object(
         'name',     v_row.shop_name,
         'address',  NULLIF(trim(COALESCE(v_row.shop_address, '')), ''),
         'city',     NULLIF(trim(COALESCE(v_row.shop_city, '')), ''),
         'phone',    NULLIF(trim(COALESCE(v_row.shop_phone, '')), ''),
         'whatsapp', NULLIF(trim(COALESCE(v_row.shop_wa, '')), ''),
         'email',    NULLIF(trim(COALESCE(v_row.shop_email, '')), '')
       ));

  IF NULLIF(trim(COALESCE(v_merged->>'address','')), '') IS NULL THEN
    v_merged := v_merged || jsonb_build_object('address', '');
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'shop_name',  v_row.shop_name,
    'slug',       v_row.slug,
    'shop_id',    v_row.shop_id,
    'shop_type',  v_row.shop_type,
    'plan',       v_row.shop_plan,
    'page_slug',  v_page,
    'page_status',v_status,
    'ai_mode',    (COALESCE(v_row.ai_published, false) = true AND v_page_html IS NOT NULL),
    'ai_html',    v_page_html,
    'content',    v_merged,
    'updated_at', v_row.updated_at
  );
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--
--   -- 1. New table exists
--   SELECT count(*) FROM sbp_website_pages;  -- 0 initially
--
--   -- 2. ai_prompt_templates extended
--   SELECT version, page_slug, is_active, length(prompt_text)
--   FROM ai_prompt_templates
--   WHERE name = 'website_v1'
--   ORDER BY version DESC LIMIT 5;
--   -- All rows should have page_slug='home' set
--
--   -- 3. Legacy resolver still works for existing shops
--   SELECT (sbp_resolve_shop_slug('indian-curry'))->>'ok';  -- 'true'
--
--   -- 4. New resolver works, falls back to legacy
--   SELECT (sbp_resolve_shop_page('indian-curry','home'))->>'page_status';
--   -- 'legacy_home' if shop generated pre-M0, 'real' after next regen
--
--   -- 5. New resolver reports business_only for ungenerated pages
--   SELECT (sbp_resolve_shop_page('indian-curry','menu'))->>'page_status';
--   -- 'business_only'
--
-- After deploy, regenerate one shop to see the dual-write in action:
--   SELECT page_slug, generated_at, prompt_version
--   FROM sbp_website_pages
--   WHERE shop_id = '<your-shop-uuid>';
--   -- Should show home row created.
-- ════════════════════════════════════════════════════════════════════
