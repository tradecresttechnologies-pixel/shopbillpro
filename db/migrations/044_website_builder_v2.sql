-- ════════════════════════════════════════════════════════════════════
-- 044_website_builder_v2.sql
-- AI Website Builder v2 — extends sbp_shop_websites; no new table.
--
-- Replaces broken migrations 042 + 043 from previous chat (those used
-- LONGTEXT, ON CONFLICT without unique constraint, wrong table refs).
--
-- Tier policy:
--   free     → 1 generation lifetime  (locks first AI draft, no regens)
--   pro      → 2 generations / month
--   business → 5 generations / month
--   (enterprise normalises to business everywhere)
--
-- IDEMPOTENT — safe to re-run. Deploy AFTER 008_public_shop_page.sql.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Extend sbp_shop_websites with AI columns ────────────────────────

ALTER TABLE sbp_shop_websites
  ADD COLUMN IF NOT EXISTS ai_generated_html      TEXT,
  ADD COLUMN IF NOT EXISTS ai_design_style        VARCHAR(50),
  ADD COLUMN IF NOT EXISTS ai_color_primary       VARCHAR(50),
  ADD COLUMN IF NOT EXISTS ai_color_primary_hex   VARCHAR(7),
  ADD COLUMN IF NOT EXISTS ai_color_accent        VARCHAR(50),
  ADD COLUMN IF NOT EXISTS ai_color_accent_hex    VARCHAR(7),
  ADD COLUMN IF NOT EXISTS ai_headline            VARCHAR(160),
  ADD COLUMN IF NOT EXISTS ai_description         TEXT,
  ADD COLUMN IF NOT EXISTS ai_business_type       VARCHAR(50),
  ADD COLUMN IF NOT EXISTS ai_published           BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ai_regenerations_used  INT     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ai_regen_period_start  DATE,
  ADD COLUMN IF NOT EXISTS ai_last_generated_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ai_provider            VARCHAR(20),
  ADD COLUMN IF NOT EXISTS ai_total_lifetime_gens INT     NOT NULL DEFAULT 0;

-- ── 2. Tier-limit helper ───────────────────────────────────────────────
-- Returns {monthly_limit, lifetime_limit_free} for current normalised plan.

DROP FUNCTION IF EXISTS _sbp_website_tier_limits(text);

CREATE OR REPLACE FUNCTION _sbp_website_tier_limits(p_plan text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_plan text := lower(coalesce(p_plan, 'free'));
BEGIN
  IF v_plan = 'enterprise' THEN v_plan := 'business'; END IF;

  RETURN CASE v_plan
    WHEN 'free'     THEN jsonb_build_object('plan','free',     'monthly_limit', 0, 'lifetime_free_limit', 1)
    WHEN 'pro'      THEN jsonb_build_object('plan','pro',      'monthly_limit', 2, 'lifetime_free_limit', 1)
    WHEN 'business' THEN jsonb_build_object('plan','business', 'monthly_limit', 5, 'lifetime_free_limit', 1)
    ELSE                 jsonb_build_object('plan','free',     'monthly_limit', 0, 'lifetime_free_limit', 1)
  END;
END;
$$;

-- ── 3. Get builder state (form prefill + tier + remaining quota) ──────

DROP FUNCTION IF EXISTS sbp_get_website_builder_state();

CREATE OR REPLACE FUNCTION sbp_get_website_builder_state()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop      record;
  v_website   record;
  v_plan      text;
  v_limits    jsonb;
  v_monthly   int;
  v_lifetime  int;
  v_used_mo   int;
  v_used_life int;
  v_can_gen   boolean;
  v_reason    text;
BEGIN
  -- Resolve current user's shop
  SELECT s.id, s.name, s.shop_type, s.plan, s.plan_expires_at
    INTO v_shop
  FROM shops s
  WHERE s.owner_id = auth.uid()
  LIMIT 1;

  IF v_shop.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- Normalise plan (enterprise→business, expired→free)
  v_plan := lower(coalesce(v_shop.plan, 'free'));
  IF v_plan = 'enterprise' THEN v_plan := 'business'; END IF;
  IF v_shop.plan_expires_at IS NOT NULL
     AND v_plan <> 'free'
     AND v_shop.plan_expires_at < now()
  THEN
    v_plan := 'free';
  END IF;

  -- Fetch existing website row (if any)
  SELECT * INTO v_website
  FROM sbp_shop_websites
  WHERE shop_id = v_shop.id;

  v_limits   := _sbp_website_tier_limits(v_plan);
  v_monthly  := (v_limits->>'monthly_limit')::int;
  v_lifetime := (v_limits->>'lifetime_free_limit')::int;

  -- Reset monthly counter if calendar month rolled
  v_used_mo := COALESCE(v_website.ai_regenerations_used, 0);
  IF v_website.ai_regen_period_start IS NULL
     OR date_trunc('month', v_website.ai_regen_period_start) < date_trunc('month', now())
  THEN
    v_used_mo := 0;
  END IF;

  v_used_life := COALESCE(v_website.ai_total_lifetime_gens, 0);

  -- Decide can_generate
  IF v_plan = 'free' THEN
    v_can_gen := v_used_life < v_lifetime;
    v_reason  := CASE WHEN v_can_gen THEN '' ELSE 'free_lifetime_exhausted' END;
  ELSE
    v_can_gen := v_used_mo < v_monthly;
    v_reason  := CASE WHEN v_can_gen THEN '' ELSE 'monthly_quota_exhausted' END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'shop', jsonb_build_object(
      'id',         v_shop.id,
      'name',       v_shop.name,
      'shop_type',  COALESCE(v_shop.shop_type, ''),
      'plan',       v_plan
    ),
    'tier', jsonb_build_object(
      'plan',                 v_plan,
      'monthly_limit',        v_monthly,
      'lifetime_free_limit',  v_lifetime,
      'used_this_month',      v_used_mo,
      'used_lifetime',        v_used_life,
      'can_generate',         v_can_gen,
      'block_reason',         v_reason
    ),
    'website', CASE WHEN v_website.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id',                v_website.id,
      'slug',              v_website.slug,
      'has_ai_draft',      v_website.ai_generated_html IS NOT NULL,
      'ai_published',      COALESCE(v_website.ai_published, false),
      'design_style',      COALESCE(v_website.ai_design_style, 'modern'),
      'color_primary',     COALESCE(v_website.ai_color_primary, 'orange'),
      'color_primary_hex', COALESCE(v_website.ai_color_primary_hex, '#FF6B35'),
      'color_accent',      COALESCE(v_website.ai_color_accent, 'navy'),
      'color_accent_hex',  COALESCE(v_website.ai_color_accent_hex, '#001F3F'),
      'headline',          COALESCE(v_website.ai_headline, ''),
      'description',       COALESCE(v_website.ai_description, ''),
      'business_type',     COALESCE(v_website.ai_business_type, v_shop.shop_type, ''),
      'last_generated_at', v_website.ai_last_generated_at
    ) END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_website_builder_state() TO authenticated;

-- ── 4. Save a draft (no AI call — just persist form fields) ───────────

DROP FUNCTION IF EXISTS sbp_save_website_builder_draft(jsonb);

CREATE OR REPLACE FUNCTION sbp_save_website_builder_draft(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id    uuid;
  v_website_id uuid;
  v_slug       text;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- Ensure a website row exists (with generated slug)
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

  UPDATE sbp_shop_websites
  SET ai_design_style      = COALESCE(p_payload->>'design_style', ai_design_style),
      ai_color_primary     = COALESCE(p_payload->>'color_primary', ai_color_primary),
      ai_color_primary_hex = COALESCE(p_payload->>'color_primary_hex', ai_color_primary_hex),
      ai_color_accent      = COALESCE(p_payload->>'color_accent', ai_color_accent),
      ai_color_accent_hex  = COALESCE(p_payload->>'color_accent_hex', ai_color_accent_hex),
      ai_headline          = COALESCE(p_payload->>'headline', ai_headline),
      ai_description       = COALESCE(p_payload->>'description', ai_description),
      ai_business_type     = COALESCE(p_payload->>'business_type', ai_business_type),
      updated_at           = now()
  WHERE id = v_website_id;

  RETURN jsonb_build_object('ok', true, 'website_id', v_website_id, 'slug', v_slug);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_save_website_builder_draft(jsonb) TO authenticated;

-- ── 5. Record completed AI generation (called by Edge Function) ───────
-- Edge function authenticates via service-role; here we accept the
-- shop_id from the JWT user context, NOT from payload.

DROP FUNCTION IF EXISTS sbp_record_ai_website_generation(jsonb);

CREATE OR REPLACE FUNCTION sbp_record_ai_website_generation(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id     uuid;
  v_website_id  uuid;
  v_slug        text;
  v_plan        text;
  v_limits      jsonb;
  v_used_mo     int;
  v_used_life   int;
  v_period      date;
  v_state       jsonb;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- Server-side quota check (defense in depth — never trust client)
  v_state := sbp_get_website_builder_state();
  IF NOT COALESCE((v_state->'tier'->>'can_generate')::boolean, false) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'quota_exhausted',
      'reason', v_state->'tier'->>'block_reason'
    );
  END IF;

  -- Ensure website row exists
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

  -- Compute new monthly counter (reset if month rolled)
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

  UPDATE sbp_shop_websites
  SET ai_generated_html      = p_payload->>'generated_html',
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

  RETURN jsonb_build_object(
    'ok', true,
    'website_id', v_website_id,
    'slug',       v_slug
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_record_ai_website_generation(jsonb) TO authenticated;

-- ── 6. Publish / unpublish AI website ─────────────────────────────────

DROP FUNCTION IF EXISTS sbp_set_ai_website_published(boolean);

CREATE OR REPLACE FUNCTION sbp_set_ai_website_published(p_published boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_shop_id uuid;
  v_slug    text;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  UPDATE sbp_shop_websites
  SET ai_published = p_published,
      updated_at   = now()
  WHERE shop_id = v_shop_id
  RETURNING slug INTO v_slug;

  IF v_slug IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_website');
  END IF;

  RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'published', p_published);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_set_ai_website_published(boolean) TO authenticated;

-- ── 7. Color palette + recommendations (server source of truth) ──────

DROP FUNCTION IF EXISTS sbp_get_website_color_palette();

CREATE OR REPLACE FUNCTION sbp_get_website_color_palette()
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('ok', true, 'total', 18,
    'warm', jsonb_build_array(
      jsonb_build_object('key','orange',   'name','Orange',   'hex','#FF6B35', 'icon','🟠', 'vibes','Bold, Modern, Energetic'),
      jsonb_build_object('key','red',      'name','Red',      'hex','#E63946', 'icon','🔴', 'vibes','Premium, Luxury, Powerful'),
      jsonb_build_object('key','pink',     'name','Pink',     'hex','#FF006E', 'icon','💗', 'vibes','Playful, Trendy, Beauty'),
      jsonb_build_object('key','coral',    'name','Coral',    'hex','#FF7F50', 'icon','🪸', 'vibes','Friendly, Warm, Inviting'),
      jsonb_build_object('key','gold',     'name','Gold',     'hex','#FFD700', 'icon','✨', 'vibes','Premium, Luxury, Elegant')
    ),
    'cool', jsonb_build_array(
      jsonb_build_object('key','blue',     'name','Blue',     'hex','#0066CC', 'icon','🔵', 'vibes','Professional, Trust'),
      jsonb_build_object('key','navy',     'name','Navy',     'hex','#001F3F', 'icon','🌊', 'vibes','Formal, Corporate, Serious'),
      jsonb_build_object('key','cyan',     'name','Cyan',     'hex','#00D9FF', 'icon','💫', 'vibes','Modern, Tech, Fresh'),
      jsonb_build_object('key','teal',     'name','Teal',     'hex','#20B2AA', 'icon','🏞️', 'vibes','Calm, Balanced, Natural'),
      jsonb_build_object('key','purple',   'name','Purple',   'hex','#9D4EDD', 'icon','💜', 'vibes','Creative, Premium')
    ),
    'natural', jsonb_build_array(
      jsonb_build_object('key','green',    'name','Green',    'hex','#2D6A4F', 'icon','🌿', 'vibes','Eco-friendly, Health'),
      jsonb_build_object('key','sage',     'name','Sage',     'hex','#9CAF88', 'icon','🍃', 'vibes','Wellness, Calm, Organic'),
      jsonb_build_object('key','brown',    'name','Brown',    'hex','#8B4513', 'icon','🏠', 'vibes','Earthy, Traditional'),
      jsonb_build_object('key','charcoal', 'name','Charcoal', 'hex','#36454F', 'icon','⚫', 'vibes','Minimalist, Sophisticated'),
      jsonb_build_object('key','taupe',    'name','Taupe',    'hex','#B38B6D', 'icon','🤎', 'vibes','Elegant, Timeless')
    ),
    'vibrant', jsonb_build_array(
      jsonb_build_object('key','magenta',  'name','Magenta',  'hex','#FF10F0', 'icon','🎆', 'vibes','Bold, Trendy, Eye-catching'),
      jsonb_build_object('key','lime',     'name','Lime',     'hex','#00FF00', 'icon','🍋', 'vibes','Energetic, Fun, Youth'),
      jsonb_build_object('key','indigo',   'name','Indigo',   'hex','#4B0082', 'icon','💎', 'vibes','Luxury, Mystical')
    ),
    'recommendations', jsonb_build_object(
      'retail',       jsonb_build_array('orange','blue','navy','gold'),
      'food',         jsonb_build_array('orange','red','coral','green'),
      'salon',        jsonb_build_array('pink','purple','gold','magenta'),
      'hospitality',  jsonb_build_array('navy','gold','teal','taupe'),
      'healthcare',   jsonb_build_array('teal','blue','green','sage'),
      'services',     jsonb_build_array('blue','navy','orange','charcoal'),
      'education',    jsonb_build_array('blue','navy','purple','green'),
      'online_brand', jsonb_build_array('indigo','magenta','cyan','gold')
    ),
    'accent_pairs', jsonb_build_object(
      'orange','#001F3F','red','#FFD700','pink','#9D4EDD','coral','#20B2AA','gold','#001F3F',
      'blue','#00D9FF','navy','#FFD700','cyan','#001F3F','teal','#FF7F50','purple','#FFD700',
      'green','#9CAF88','sage','#20B2AA','brown','#FFFDD0','charcoal','#00D9FF','taupe','#FFD700',
      'magenta','#001F3F','lime','#001F3F','indigo','#FFD700'
    )
  );
$$;

GRANT EXECUTE ON FUNCTION sbp_get_website_color_palette() TO authenticated, anon;

-- ── 8. Extend sbp_resolve_shop_slug to surface AI HTML when published ─

DROP FUNCTION IF EXISTS sbp_resolve_shop_slug(text);

CREATE OR REPLACE FUNCTION sbp_resolve_shop_slug(p_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_redirect record;
  v_website  record;
  v_clean    text;
BEGIN
  v_clean := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_slug');
  END IF;

  -- 12-month redirect check
  SELECT r.* INTO v_redirect
  FROM sbp_slug_redirects r
  WHERE r.old_slug = v_clean AND r.expires_at > now();

  IF FOUND THEN
    SELECT w.slug INTO v_clean
    FROM sbp_shop_websites w
    WHERE w.shop_id = v_redirect.shop_id;
    RETURN jsonb_build_object('ok', true, 'redirect', true, 'new_slug', v_clean);
  END IF;

  SELECT
    w.slug, w.content_json, w.design_tokens, w.updated_at,
    w.ai_generated_html, w.ai_published,
    s.name AS shop_name, s.shop_type, s.plan
  INTO v_website
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = v_clean AND w.published = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'slug', v_website.slug,
    'content', v_website.content_json,
    'design',  v_website.design_tokens,
    'shop_name', v_website.shop_name,
    'shop_type', v_website.shop_type,
    'plan',      v_website.plan,
    'updated_at', v_website.updated_at,
    'ai_html', CASE WHEN v_website.ai_published = true AND v_website.ai_generated_html IS NOT NULL
                    THEN v_website.ai_generated_html ELSE NULL END,
    'ai_mode', COALESCE(v_website.ai_published, false)
                AND v_website.ai_generated_html IS NOT NULL
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_resolve_shop_slug(text) TO anon, authenticated;

-- ── 9. Cleanup orphan tables from migration 042 (if previously run) ──
-- The websites table was created with wrong schema and never queried by app.

DROP TABLE IF EXISTS websites CASCADE;
DROP FUNCTION IF EXISTS sbp_generate_website(jsonb);
DROP FUNCTION IF EXISTS sbp_publish_website(uuid, varchar);
DROP FUNCTION IF EXISTS sbp_get_website();
DROP FUNCTION IF EXISTS _sbp_generate_website_html(jsonb, varchar);
DROP FUNCTION IF EXISTS sbp_get_color_recommendations(varchar);
DROP FUNCTION IF EXISTS sbp_get_color_palette();
DROP FUNCTION IF EXISTS sbp_validate_website_form(jsonb);
DROP FUNCTION IF EXISTS sbp_get_website_tier_info();
DROP FUNCTION IF EXISTS sbp_get_accent_color(varchar);
DROP FUNCTION IF EXISTS sbp_can_regenerate_website();

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--   SELECT * FROM _sbp_website_tier_limits('pro');
--   SELECT sbp_get_website_builder_state();   -- (logged-in user only)
-- ════════════════════════════════════════════════════════════════════
