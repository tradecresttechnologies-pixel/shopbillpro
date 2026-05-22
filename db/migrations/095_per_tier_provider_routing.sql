-- ════════════════════════════════════════════════════════════════════
-- 095_per_tier_provider_routing.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   Adds proper admin-panel provider switching that the Edge Function
--   actually honors at runtime.
--
--   Discovery in this session: admin-websites.html → Provider tab already
--   has a dropdown to switch provider, backed by admin_get/set_ai_provider_config
--   RPCs (045). BUT the Edge Function doesn't read this setting — it
--   reads `provider` from the prompt template row. Result: the dropdown
--   is cosmetic. Setting it to "groq" does nothing.
--
--   This migration closes that gap and adds per-tier routing on top.
--
-- CHANGES
--   1. Seed three admin_settings rows (idempotent INSERTs):
--        - active_ai_provider   — global default (already exists from 045 usage; ensure exists)
--        - ai_provider_pro      — provider for Pro plan shops
--        - ai_provider_business — provider for Business plan shops
--
--      Resolution order at generation time (handled in Edge Function v3.7):
--        if shop.plan = 'business' AND ai_provider_business is set → use it
--        elif shop.plan = 'pro' AND ai_provider_pro is set → use it
--        elif active_ai_provider is set → use it (global default)
--        else → 'claude' (hard default)
--
--   2. New RPC _internal_get_provider_config() — service-role only,
--      called by Edge Function on every generation to resolve which
--      provider to use for the given shop's plan.
--
--   3. Two new admin RPCs for the UI to read/set per-tier values:
--        admin_get_provider_tier_config(token)
--        admin_set_provider_tier_config(token, p_pro, p_business)
--
-- BACKWARD COMPATIBILITY
--   The existing `admin_get_ai_provider_config` / `admin_set_ai_provider_config`
--   (from 045) are UNTOUCHED — they continue to read/write `active_ai_provider`
--   for the existing admin UI dropdown. The new per-tier RPCs are additive.
--
-- DEPLOY ORDER
--   AFTER 045 (which defines admin_settings infrastructure).
--   Idempotent — safe to re-run. New admin_settings rows use ON CONFLICT.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Seed admin_settings rows for provider configuration ─────────
-- These rows are created on first deploy; on re-runs they're left as-is
-- (so admin's chosen values survive re-running this migration).

INSERT INTO admin_settings (key, value, is_secret, description)
VALUES
  ('active_ai_provider',   'claude', false,
   'Global default AI provider (used when no per-tier override is set). Valid: claude, groq.'),
  ('ai_provider_pro',      '',       false,
   'AI provider for Pro plan shops. Blank = fall back to active_ai_provider. Valid: claude, groq, or blank.'),
  ('ai_provider_business', '',       false,
   'AI provider for Business plan shops. Blank = fall back to active_ai_provider. Valid: claude, groq, or blank.')
ON CONFLICT (key) DO NOTHING;

-- ── 2. Internal resolver — called by Edge Function on every gen ────
-- Service-role only. Returns the resolved provider for a given plan.
-- The Edge Function passes the shop's normalized plan (free/pro/business);
-- this RPC returns the provider name to use.

DROP FUNCTION IF EXISTS _internal_resolve_ai_provider(text);
CREATE OR REPLACE FUNCTION _internal_resolve_ai_provider(p_plan text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_per_tier text;
  v_default  text;
  v_plan     text;
BEGIN
  -- Normalize plan input
  v_plan := lower(COALESCE(NULLIF(trim(p_plan), ''), 'free'));
  IF v_plan = 'enterprise' THEN v_plan := 'business'; END IF;  -- legacy alias

  -- Per-tier lookup
  IF v_plan = 'business' THEN
    SELECT value INTO v_per_tier FROM admin_settings WHERE key = 'ai_provider_business' LIMIT 1;
  ELSIF v_plan = 'pro' THEN
    SELECT value INTO v_per_tier FROM admin_settings WHERE key = 'ai_provider_pro' LIMIT 1;
  END IF;

  IF v_per_tier IS NOT NULL AND trim(v_per_tier) <> '' AND v_per_tier IN ('claude','groq') THEN
    RETURN v_per_tier;
  END IF;

  -- Global default fallback
  SELECT value INTO v_default FROM admin_settings WHERE key = 'active_ai_provider' LIMIT 1;
  IF v_default IS NOT NULL AND trim(v_default) <> '' AND v_default IN ('claude','groq') THEN
    RETURN v_default;
  END IF;

  -- Hard fallback if no admin config at all
  RETURN 'claude';
END;
$$;

REVOKE ALL ON FUNCTION _internal_resolve_ai_provider(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION _internal_resolve_ai_provider(text) TO service_role;

-- ── 3. Admin RPC: read per-tier config ─────────────────────────────
DROP FUNCTION IF EXISTS admin_get_provider_tier_config(text);
CREATE OR REPLACE FUNCTION admin_get_provider_tier_config(p_admin_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_default  text;
  v_pro      text;
  v_business text;
  v_anthropic_set boolean;
  v_groq_set      boolean;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT value INTO v_default  FROM admin_settings WHERE key = 'active_ai_provider'   LIMIT 1;
  SELECT value INTO v_pro      FROM admin_settings WHERE key = 'ai_provider_pro'      LIMIT 1;
  SELECT value INTO v_business FROM admin_settings WHERE key = 'ai_provider_business' LIMIT 1;

  -- Key-availability badges (no values exposed — just is_set boolean)
  SELECT (value_encrypted IS NOT NULL OR (value IS NOT NULL AND length(value) > 10))
    INTO v_anthropic_set FROM admin_settings WHERE key = 'anthropic_api_key' LIMIT 1;
  SELECT (value_encrypted IS NOT NULL OR (value IS NOT NULL AND length(value) > 10))
    INTO v_groq_set      FROM admin_settings WHERE key = 'groq_api_key' LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'global_default',    COALESCE(NULLIF(trim(v_default), ''),  'claude'),
    'pro_provider',      COALESCE(NULLIF(trim(v_pro), ''),      ''),
    'business_provider', COALESCE(NULLIF(trim(v_business), ''), ''),
    'available_providers', jsonb_build_array('claude','groq'),
    'keys_status', jsonb_build_object(
      'claude', COALESCE(v_anthropic_set, false),
      'groq',   COALESCE(v_groq_set, false)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_provider_tier_config(text) TO authenticated, anon;

-- ── 4. Admin RPC: set per-tier config ──────────────────────────────
-- Accepts blank string to clear an override (means "use global default").
-- Validates each provider value if non-blank.
DROP FUNCTION IF EXISTS admin_set_provider_tier_config(text, text, text, text);
CREATE OR REPLACE FUNCTION admin_set_provider_tier_config(
  p_admin_token     text,
  p_global_default  text DEFAULT NULL,
  p_pro_provider    text DEFAULT NULL,
  p_business_provider text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_changes jsonb := '{}'::jsonb;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  -- Validate non-NULL non-blank values
  IF p_global_default IS NOT NULL AND trim(p_global_default) <> '' AND p_global_default NOT IN ('claude','groq') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_global_default', 'value', p_global_default);
  END IF;
  IF p_pro_provider IS NOT NULL AND trim(p_pro_provider) <> '' AND p_pro_provider NOT IN ('claude','groq') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_pro_provider', 'value', p_pro_provider);
  END IF;
  IF p_business_provider IS NOT NULL AND trim(p_business_provider) <> '' AND p_business_provider NOT IN ('claude','groq') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_provider', 'value', p_business_provider);
  END IF;

  -- Update only the fields that were explicitly passed (NULL = leave unchanged)
  IF p_global_default IS NOT NULL THEN
    INSERT INTO admin_settings (key, value, is_secret, description)
    VALUES ('active_ai_provider', trim(p_global_default), false, 'Global default AI provider')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    v_changes := v_changes || jsonb_build_object('global_default', trim(p_global_default));
  END IF;

  IF p_pro_provider IS NOT NULL THEN
    INSERT INTO admin_settings (key, value, is_secret, description)
    VALUES ('ai_provider_pro', trim(p_pro_provider), false, 'AI provider for Pro plan shops')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    v_changes := v_changes || jsonb_build_object('pro_provider', trim(p_pro_provider));
  END IF;

  IF p_business_provider IS NOT NULL THEN
    INSERT INTO admin_settings (key, value, is_secret, description)
    VALUES ('ai_provider_business', trim(p_business_provider), false, 'AI provider for Business plan shops')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    v_changes := v_changes || jsonb_build_object('business_provider', trim(p_business_provider));
  END IF;

  PERFORM admin_log_action(
    p_admin_token, 'set_provider_tier_config', 'setting', 'provider_tier_config',
    NULL, v_changes, NULL
  );

  RETURN jsonb_build_object('ok', true, 'changes', v_changes);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_set_provider_tier_config(text, text, text, text) TO authenticated, anon;

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--
--   SELECT key, value, description FROM admin_settings
--   WHERE key IN ('active_ai_provider','ai_provider_pro','ai_provider_business')
--   ORDER BY key;
--   -- Should show 3 rows. Initial values: active_ai_provider='claude',
--   -- ai_provider_pro='', ai_provider_business=''.
--
--   -- Test the resolver:
--   SELECT _internal_resolve_ai_provider('free');      -- 'claude' (global default)
--   SELECT _internal_resolve_ai_provider('pro');       -- 'claude' (no Pro override, falls back)
--   SELECT _internal_resolve_ai_provider('business');  -- 'claude' (no Business override)
--
--   -- Set per-tier:
--   SELECT admin_set_provider_tier_config(
--     '<admin_token>',
--     'claude',  -- global default
--     'groq',    -- Pro tier uses groq
--     'claude'   -- Business tier uses claude
--   );
--
--   -- Verify resolution:
--   SELECT _internal_resolve_ai_provider('pro');       -- 'groq' now
--   SELECT _internal_resolve_ai_provider('business');  -- 'claude'
--
-- The Edge Function v3.7 (separate deploy) will call _internal_resolve_ai_provider
-- on every generation with the shop's plan, and use the returned value to
-- choose callClaude() or callGroq().
-- ════════════════════════════════════════════════════════════════════
