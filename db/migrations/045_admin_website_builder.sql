-- ════════════════════════════════════════════════════════════════════
-- 045_admin_website_builder.sql
-- Admin Panel integration for Website Builder v2 (Batch v3, Scope B).
--
-- Adds:
--   • ai_prompt_templates  — versioned prompt management
--   • ai_generation_log    — every generation attempt (success + failure)
--   • Admin RPCs:
--       admin_list_websites          — paginated list with filters
--       admin_get_website_detail     — full record + HTML for one shop
--       admin_force_unpublish_website
--       admin_grant_website_quota    — bonus generations for support
--       admin_website_stats          — aggregate metrics
--       admin_list_generation_failures
--       admin_get_ai_provider_config — read provider + active prompt
--       admin_set_ai_provider_config — save provider + prompt
--       admin_list_prompt_templates  — version history
--       admin_save_prompt_template   — new version
--       admin_activate_prompt_template
--       log_ai_generation            — used by edge function to log
--
-- IDEMPOTENT — safe to re-run. Deploy AFTER 044_website_builder_v2.sql.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. AI prompt templates (versioned) ─────────────────────────────────

CREATE TABLE IF NOT EXISTS ai_prompt_templates (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,                  -- e.g. 'website_v1'
  version       int  NOT NULL,                  -- monotonic per name
  provider      text NOT NULL DEFAULT 'claude', -- 'claude' | 'groq'
  prompt_text   text NOT NULL,
  is_active     boolean NOT NULL DEFAULT false,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text,
  UNIQUE(name, version)
);

CREATE INDEX IF NOT EXISTS idx_ai_prompt_templates_active ON ai_prompt_templates(name, is_active) WHERE is_active = true;

-- Seed v1 of website prompt (the same one currently hardcoded in edge function)
INSERT INTO ai_prompt_templates (name, version, provider, prompt_text, is_active, notes, created_by)
SELECT
  'website_v1', 1, 'claude',
  $PROMPT$You are an expert web designer. Generate a single self-contained HTML5 website.

BUSINESS:
- Name: {SHOP_NAME}
- Type: {BUSINESS_TYPE}
- Headline: {HEADLINE}
- Description: {DESCRIPTION}
- Style: {DESIGN_STYLE}

COLORS (use exactly these):
- Primary: {COLOR_PRIMARY} ({COLOR_PRIMARY_HEX})
- Accent:  {COLOR_ACCENT}  ({COLOR_ACCENT_HEX})

REQUIREMENTS:
- Single HTML file. All CSS inside one <style> tag. No external CSS/JS frameworks.
- Mobile-first responsive. Works at 320px width.
- WCAG AA contrast on text.
- Sections: sticky header with shop name, hero with headline + CTA, services/products list (3-6 items inferred from business type), about block, contact (WhatsApp + email + address placeholders), footer with "Powered by ShopBill Pro".
- Use {COLOR_PRIMARY_HEX} for header/hero background. Use {COLOR_ACCENT_HEX} for buttons and links.
- Clean Outfit/Inter style typography (use system-ui font stack).
- No JavaScript needed beyond a smooth-scroll snippet.
- Output ONLY the raw HTML, starting with <!DOCTYPE html>. No markdown fences, no commentary.$PROMPT$,
  true, 'Initial template — extracted from edge function v1', 'system'
WHERE NOT EXISTS (SELECT 1 FROM ai_prompt_templates WHERE name='website_v1' AND version=1);

-- ── 2. AI generation log (every attempt, success + failure) ────────────

CREATE TABLE IF NOT EXISTS ai_generation_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id           uuid REFERENCES shops(id) ON DELETE SET NULL,
  shop_name         text,
  provider          text,                    -- 'claude' | 'groq'
  prompt_template   text,                    -- e.g. 'website_v1'
  status            text NOT NULL,           -- 'success' | 'failure'
  error_message     text,
  input_tokens      int,
  output_tokens     int,
  estimated_cost_usd numeric(10, 6),         -- input*$3/M + output*$15/M for Claude Sonnet
  generation_time_ms int,
  request_payload   jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_gen_log_shop      ON ai_generation_log(shop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_gen_log_status    ON ai_generation_log(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_gen_log_created   ON ai_generation_log(created_at DESC);

-- ── 3. Logger RPC (called by edge function) ────────────────────────────

DROP FUNCTION IF EXISTS log_ai_generation(jsonb);

CREATE OR REPLACE FUNCTION log_ai_generation(p_payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id uuid;
  v_in  int := COALESCE((p_payload->>'input_tokens')::int, 0);
  v_out int := COALESCE((p_payload->>'output_tokens')::int, 0);
  v_cost numeric(10,6);
BEGIN
  -- Claude Sonnet 4 pricing: $3/M input, $15/M output
  v_cost := (v_in::numeric * 3 + v_out::numeric * 15) / 1000000.0;

  INSERT INTO ai_generation_log (
    shop_id, shop_name, provider, prompt_template, status, error_message,
    input_tokens, output_tokens, estimated_cost_usd, generation_time_ms, request_payload
  ) VALUES (
    NULLIF(p_payload->>'shop_id','')::uuid,
    p_payload->>'shop_name',
    COALESCE(p_payload->>'provider','claude'),
    COALESCE(p_payload->>'prompt_template','website_v1'),
    COALESCE(p_payload->>'status','success'),
    p_payload->>'error_message',
    v_in, v_out, v_cost,
    NULLIF(p_payload->>'generation_time_ms','')::int,
    p_payload->'request_payload'
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION log_ai_generation(jsonb) TO authenticated, anon;

-- ── 4. Admin: list websites (paginated, filterable) ────────────────────

DROP FUNCTION IF EXISTS admin_list_websites(text, text, text, int, int);

CREATE OR REPLACE FUNCTION admin_list_websites(
  p_admin_token text,
  p_search      text DEFAULT NULL,        -- search shop name / slug
  p_filter      text DEFAULT 'all',       -- 'all'|'published'|'unpublished'|'has_ai'|'free'|'pro'|'business'
  p_limit       int  DEFAULT 50,
  p_offset      int  DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total int;
  v_rows  jsonb;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  WITH base AS (
    SELECT w.id, w.shop_id, w.slug, w.published, w.ai_published,
           w.ai_generated_html IS NOT NULL AS has_ai_draft,
           w.ai_design_style, w.ai_color_primary, w.ai_color_accent,
           w.ai_headline, w.ai_business_type, w.ai_provider,
           w.ai_regenerations_used, w.ai_total_lifetime_gens,
           w.ai_last_generated_at, w.created_at, w.updated_at,
           s.name AS shop_name, s.plan, s.shop_type, s.owner_id, s.city,
           s.plan_expires_at
    FROM sbp_shop_websites w
    JOIN shops s ON s.id = w.shop_id
    WHERE
      (p_search IS NULL OR p_search = '' OR
        s.name ILIKE '%'||p_search||'%' OR
        w.slug ILIKE '%'||p_search||'%')
      AND CASE p_filter
            WHEN 'published'   THEN w.ai_published = true
            WHEN 'unpublished' THEN COALESCE(w.ai_published, false) = false
            WHEN 'has_ai'      THEN w.ai_generated_html IS NOT NULL
            WHEN 'free'        THEN lower(s.plan) IN ('free')
            WHEN 'pro'         THEN lower(s.plan) IN ('pro')
            WHEN 'business'    THEN lower(s.plan) IN ('business','enterprise')
            ELSE true
          END
  )
  SELECT count(*), COALESCE(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
  INTO v_total, v_rows
  FROM (
    SELECT * FROM base ORDER BY ai_last_generated_at DESC NULLS LAST, updated_at DESC
    LIMIT GREATEST(p_limit, 1) OFFSET GREATEST(p_offset, 0)
  ) b;

  RETURN jsonb_build_object(
    'ok', true,
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'rows', v_rows
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_list_websites(text, text, text, int, int) TO authenticated, anon;

-- ── 5. Admin: get full website detail ──────────────────────────────────

DROP FUNCTION IF EXISTS admin_get_website_detail(text, uuid);

CREATE OR REPLACE FUNCTION admin_get_website_detail(
  p_admin_token text,
  p_shop_id     uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row jsonb;
  v_log jsonb;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT to_jsonb(t) INTO v_row FROM (
    SELECT w.id, w.shop_id, w.slug, w.published, w.ai_published,
           w.ai_generated_html, w.ai_design_style,
           w.ai_color_primary, w.ai_color_primary_hex,
           w.ai_color_accent,  w.ai_color_accent_hex,
           w.ai_headline, w.ai_description, w.ai_business_type,
           w.ai_provider, w.ai_regenerations_used, w.ai_total_lifetime_gens,
           w.ai_regen_period_start, w.ai_last_generated_at,
           w.content_json, w.created_at, w.updated_at,
           s.name AS shop_name, s.plan, s.shop_type, s.owner_id,
           s.city, s.phone, s.email, s.plan_expires_at
    FROM sbp_shop_websites w
    JOIN shops s ON s.id = w.shop_id
    WHERE w.shop_id = p_shop_id
  ) t;

  IF v_row IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Recent generation log for this shop (last 20)
  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.created_at DESC), '[]'::jsonb)
  INTO v_log
  FROM (
    SELECT id, provider, prompt_template, status, error_message,
           input_tokens, output_tokens, estimated_cost_usd,
           generation_time_ms, created_at
    FROM ai_generation_log
    WHERE shop_id = p_shop_id
    ORDER BY created_at DESC
    LIMIT 20
  ) l;

  RETURN jsonb_build_object(
    'ok', true,
    'website', v_row,
    'generation_log', v_log
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_website_detail(text, uuid) TO authenticated, anon;

-- ── 6. Admin: force unpublish ─────────────────────────────────────────

DROP FUNCTION IF EXISTS admin_force_unpublish_website(text, uuid, text);

CREATE OR REPLACE FUNCTION admin_force_unpublish_website(
  p_admin_token text,
  p_shop_id     uuid,
  p_reason      text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_slug text;
  v_prev boolean;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 5 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reason_required',
      'message', 'Provide a reason (≥ 5 chars) — it goes into the audit log.');
  END IF;

  SELECT slug, ai_published INTO v_slug, v_prev
  FROM sbp_shop_websites WHERE shop_id = p_shop_id;

  IF v_slug IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  UPDATE sbp_shop_websites
  SET ai_published = false, updated_at = now()
  WHERE shop_id = p_shop_id;

  PERFORM admin_log_action(
    p_admin_token,
    'force_unpublish_website',
    'shop',
    p_shop_id::text,
    jsonb_build_object('ai_published', v_prev),
    jsonb_build_object('ai_published', false),
    p_reason
  );

  RETURN jsonb_build_object('ok', true, 'slug', v_slug);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_force_unpublish_website(text, uuid, text) TO authenticated, anon;

-- ── 7. Admin: grant bonus generation quota ────────────────────────────
-- Implementation: decrement ai_regenerations_used by N (floor 0).
-- This effectively grants N free re-generations for this month.

DROP FUNCTION IF EXISTS admin_grant_website_quota(text, uuid, int, text);

CREATE OR REPLACE FUNCTION admin_grant_website_quota(
  p_admin_token text,
  p_shop_id     uuid,
  p_bonus_count int,
  p_reason      text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_used int;
  v_new  int;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF p_bonus_count < 1 OR p_bonus_count > 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_bonus',
      'message', 'Bonus count must be between 1 and 20.');
  END IF;

  SELECT COALESCE(ai_regenerations_used, 0)
  INTO v_used FROM sbp_shop_websites WHERE shop_id = p_shop_id;

  IF v_used IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  v_new := GREATEST(0, v_used - p_bonus_count);

  UPDATE sbp_shop_websites
  SET ai_regenerations_used = v_new, updated_at = now()
  WHERE shop_id = p_shop_id;

  PERFORM admin_log_action(
    p_admin_token,
    'grant_website_quota',
    'shop',
    p_shop_id::text,
    jsonb_build_object('ai_regenerations_used', v_used),
    jsonb_build_object('ai_regenerations_used', v_new, 'bonus', p_bonus_count),
    COALESCE(p_reason, 'Bonus quota granted by admin')
  );

  RETURN jsonb_build_object(
    'ok', true,
    'previous_used', v_used,
    'new_used',      v_new,
    'bonus_granted', p_bonus_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_grant_website_quota(text, uuid, int, text) TO authenticated, anon;

-- ── 8. Admin: aggregate stats ─────────────────────────────────────────

DROP FUNCTION IF EXISTS admin_website_stats(text, text);

CREATE OR REPLACE FUNCTION admin_website_stats(
  p_admin_token text,
  p_period      text DEFAULT 'month'   -- 'today' | 'week' | 'month' | 'all'
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_since      timestamptz;
  v_daily      jsonb;
  v_totals     jsonb;
  v_top_biz    jsonb;
  v_providers  jsonb;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  v_since := CASE p_period
    WHEN 'today' THEN date_trunc('day', now())
    WHEN 'week'  THEN now() - interval '7 days'
    WHEN 'month' THEN date_trunc('month', now())
    ELSE '1970-01-01'::timestamptz
  END;

  -- Aggregate totals
  SELECT jsonb_build_object(
    'total_websites',        (SELECT count(*) FROM sbp_shop_websites WHERE ai_generated_html IS NOT NULL),
    'published_count',       (SELECT count(*) FROM sbp_shop_websites WHERE ai_published = true),
    'generations_in_period', (SELECT count(*) FROM ai_generation_log WHERE created_at >= v_since AND status='success'),
    'failures_in_period',    (SELECT count(*) FROM ai_generation_log WHERE created_at >= v_since AND status='failure'),
    'total_cost_usd',        (SELECT COALESCE(sum(estimated_cost_usd),0)::numeric(10,4) FROM ai_generation_log WHERE created_at >= v_since AND status='success'),
    'total_input_tokens',    (SELECT COALESCE(sum(input_tokens),0)::int FROM ai_generation_log WHERE created_at >= v_since AND status='success'),
    'total_output_tokens',   (SELECT COALESCE(sum(output_tokens),0)::int FROM ai_generation_log WHERE created_at >= v_since AND status='success'),
    'avg_gen_time_ms',       (SELECT COALESCE(avg(generation_time_ms),0)::int FROM ai_generation_log WHERE created_at >= v_since AND status='success')
  ) INTO v_totals;

  -- Daily series for last 30 days (chart-ready)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'date',  to_char(d, 'YYYY-MM-DD'),
    'count', cnt,
    'cost',  cost
  ) ORDER BY d), '[]'::jsonb)
  INTO v_daily
  FROM (
    SELECT date_trunc('day', l.created_at)::date AS d,
           count(*) AS cnt,
           COALESCE(sum(estimated_cost_usd), 0)::numeric(10,4) AS cost
    FROM ai_generation_log l
    WHERE l.created_at >= now() - interval '30 days'
      AND l.status = 'success'
    GROUP BY 1
  ) ds;

  -- Top business types
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'business_type', biz, 'count', cnt
  ) ORDER BY cnt DESC), '[]'::jsonb)
  INTO v_top_biz
  FROM (
    SELECT COALESCE(ai_business_type, 'unknown') AS biz, count(*) AS cnt
    FROM sbp_shop_websites
    WHERE ai_generated_html IS NOT NULL
    GROUP BY 1
    ORDER BY 2 DESC
    LIMIT 8
  ) tb;

  -- Provider breakdown
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'provider', COALESCE(provider,'unknown'),
    'count',    cnt,
    'cost',     cost
  ) ORDER BY cnt DESC), '[]'::jsonb)
  INTO v_providers
  FROM (
    SELECT provider, count(*) AS cnt, COALESCE(sum(estimated_cost_usd),0)::numeric(10,4) AS cost
    FROM ai_generation_log
    WHERE created_at >= v_since AND status='success'
    GROUP BY 1
  ) p;

  RETURN jsonb_build_object(
    'ok', true,
    'period', p_period,
    'since',  v_since,
    'totals', v_totals,
    'daily_series', v_daily,
    'top_business_types', v_top_biz,
    'providers', v_providers
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_website_stats(text, text) TO authenticated, anon;

-- ── 9. Admin: list generation failures (for debugging) ────────────────

DROP FUNCTION IF EXISTS admin_list_generation_failures(text, int, int);

CREATE OR REPLACE FUNCTION admin_list_generation_failures(
  p_admin_token text,
  p_limit       int DEFAULT 50,
  p_offset      int DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_rows jsonb; v_total int;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT count(*) INTO v_total FROM ai_generation_log WHERE status='failure';

  SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.created_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, shop_id, shop_name, provider, prompt_template,
           error_message, generation_time_ms, created_at, request_payload
    FROM ai_generation_log
    WHERE status='failure'
    ORDER BY created_at DESC
    LIMIT GREATEST(p_limit,1) OFFSET GREATEST(p_offset,0)
  ) l;

  RETURN jsonb_build_object('ok', true, 'total', v_total, 'rows', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_list_generation_failures(text, int, int) TO authenticated, anon;

-- ── 10. Admin: AI provider config (read/write) ─────────────────────────
-- Stored as plain settings in admin_settings (key='active_ai_provider').

DROP FUNCTION IF EXISTS admin_get_ai_provider_config(text);

CREATE OR REPLACE FUNCTION admin_get_ai_provider_config(p_admin_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_provider text;
  v_active_prompt record;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT value INTO v_provider FROM admin_settings WHERE key='active_ai_provider';

  SELECT name, version, prompt_text, notes, created_at
  INTO v_active_prompt
  FROM ai_prompt_templates WHERE name='website_v1' AND is_active=true LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'active_provider', COALESCE(v_provider, 'claude'),
    'available_providers', jsonb_build_array('claude','groq'),
    'active_prompt', CASE WHEN v_active_prompt.name IS NULL THEN NULL ELSE jsonb_build_object(
      'name',        v_active_prompt.name,
      'version',     v_active_prompt.version,
      'prompt_text', v_active_prompt.prompt_text,
      'notes',       v_active_prompt.notes,
      'created_at',  v_active_prompt.created_at
    ) END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_ai_provider_config(text) TO authenticated, anon;

DROP FUNCTION IF EXISTS admin_set_ai_provider_config(text, text);

CREATE OR REPLACE FUNCTION admin_set_ai_provider_config(
  p_admin_token text,
  p_provider    text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF p_provider NOT IN ('claude','groq') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_provider');
  END IF;

  INSERT INTO admin_settings (key, value, is_secret, description)
  VALUES ('active_ai_provider', p_provider, false, 'Active AI provider for website generation')
  ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value, updated_at=now();

  PERFORM admin_log_action(
    p_admin_token, 'set_ai_provider', 'setting', 'active_ai_provider',
    NULL, jsonb_build_object('provider', p_provider), NULL
  );

  RETURN jsonb_build_object('ok', true, 'provider', p_provider);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_set_ai_provider_config(text, text) TO authenticated, anon;

-- ── 11. Admin: prompt template management ──────────────────────────────

DROP FUNCTION IF EXISTS admin_list_prompt_templates(text, text);

CREATE OR REPLACE FUNCTION admin_list_prompt_templates(
  p_admin_token text,
  p_name        text DEFAULT 'website_v1'
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_rows jsonb;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.version DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT id, name, version, provider, prompt_text, is_active, notes,
           created_at, created_by
    FROM ai_prompt_templates
    WHERE name = p_name
    ORDER BY version DESC
  ) t;

  RETURN jsonb_build_object('ok', true, 'name', p_name, 'versions', v_rows);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_list_prompt_templates(text, text) TO authenticated, anon;

DROP FUNCTION IF EXISTS admin_save_prompt_template(text, text, text, text, text);

CREATE OR REPLACE FUNCTION admin_save_prompt_template(
  p_admin_token text,
  p_name        text,
  p_provider    text,
  p_prompt_text text,
  p_notes       text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_next_version int;
  v_id uuid;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF length(trim(coalesce(p_prompt_text,''))) < 50 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'prompt_too_short');
  END IF;

  SELECT COALESCE(max(version),0) + 1 INTO v_next_version
  FROM ai_prompt_templates WHERE name = p_name;

  INSERT INTO ai_prompt_templates (name, version, provider, prompt_text, is_active, notes, created_by)
  VALUES (p_name, v_next_version, COALESCE(p_provider,'claude'), p_prompt_text, false, p_notes, 'admin')
  RETURNING id INTO v_id;

  PERFORM admin_log_action(
    p_admin_token, 'save_prompt_template', 'prompt', p_name,
    NULL, jsonb_build_object('version', v_next_version, 'provider', p_provider), p_notes
  );

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'name', p_name, 'version', v_next_version);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_save_prompt_template(text, text, text, text, text) TO authenticated, anon;

DROP FUNCTION IF EXISTS admin_activate_prompt_template(text, uuid);

CREATE OR REPLACE FUNCTION admin_activate_prompt_template(
  p_admin_token text,
  p_template_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_name text; v_version int;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT name, version INTO v_name, v_version
  FROM ai_prompt_templates WHERE id = p_template_id;

  IF v_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  UPDATE ai_prompt_templates SET is_active = false WHERE name = v_name AND id <> p_template_id;
  UPDATE ai_prompt_templates SET is_active = true  WHERE id = p_template_id;

  PERFORM admin_log_action(
    p_admin_token, 'activate_prompt_template', 'prompt', v_name,
    NULL, jsonb_build_object('version', v_version, 'id', p_template_id), NULL
  );

  RETURN jsonb_build_object('ok', true, 'name', v_name, 'version', v_version);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_activate_prompt_template(text, uuid) TO authenticated, anon;

-- ── 12. Public-callable RPC for edge function to fetch active prompt ──
-- Anon-safe because it returns only the active prompt text; no secrets.

DROP FUNCTION IF EXISTS get_active_ai_prompt(text);

CREATE OR REPLACE FUNCTION get_active_ai_prompt(p_name text DEFAULT 'website_v1')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_row record;
BEGIN
  SELECT name, version, provider, prompt_text
  INTO v_row
  FROM ai_prompt_templates
  WHERE name = p_name AND is_active = true
  LIMIT 1;

  IF v_row.name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_active_template');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'name',        v_row.name,
    'version',     v_row.version,
    'provider',    v_row.provider,
    'prompt_text', v_row.prompt_text
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_active_ai_prompt(text) TO authenticated, anon;

-- ── 13. Default active provider seed ──────────────────────────────────

INSERT INTO admin_settings (key, value, is_secret, description)
VALUES ('active_ai_provider', 'claude', false, 'Active AI provider for website generation')
ON CONFLICT (key) DO NOTHING;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--   SELECT admin_list_websites('YourAdminPassword', NULL, 'all', 10, 0);
--   SELECT admin_website_stats('YourAdminPassword', 'month');
--   SELECT get_active_ai_prompt('website_v1');
-- ════════════════════════════════════════════════════════════════════
