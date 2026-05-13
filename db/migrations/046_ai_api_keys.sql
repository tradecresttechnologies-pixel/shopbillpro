-- ════════════════════════════════════════════════════════════════════
-- 046_ai_api_keys.sql
-- Admin-managed AI provider API keys (Batch v3.2)
--
-- Adds:
--   • _internal_get_ai_secret(p_key)   — service-role only, decrypts admin_settings value
--   • admin_get_ai_keys_status(token)  — returns which keys are set (no values exposed)
--
-- IDEMPOTENT — safe to re-run. Deploy AFTER 045_admin_website_builder.sql.
--
-- PREREQUISITE — One-time setup (skip if already done for Razorpay key encryption):
--   ALTER DATABASE postgres SET app.encryption_key = 'pick-a-32-char-secret-key-here-ok!';
--   -- Then reconnect (close + reopen SQL editor) so the setting is loaded.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Edge-function-only secret reader ────────────────────────────────
-- SECURITY DEFINER + REVOKE from public/anon/authenticated means only
-- service_role (used by edge functions) can call this.

DROP FUNCTION IF EXISTS _internal_get_ai_secret(text);

CREATE OR REPLACE FUNCTION _internal_get_ai_secret(p_key text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row admin_settings%ROWTYPE;
  v_decrypted text;
BEGIN
  -- Only allow specific known keys (defense in depth)
  IF p_key NOT IN ('anthropic_api_key','groq_api_key') THEN
    RAISE EXCEPTION 'invalid_key';
  END IF;

  SELECT * INTO v_row FROM admin_settings WHERE key = p_key LIMIT 1;
  IF v_row.key IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_row.is_secret AND v_row.value_encrypted IS NOT NULL THEN
    -- Decrypt using app.encryption_key (set via ALTER DATABASE)
    v_decrypted := convert_from(
      pgp_sym_decrypt_bytea(
        v_row.value_encrypted,
        current_setting('app.encryption_key', true)
      ),
      'utf8'
    );
    RETURN v_decrypted;
  END IF;

  -- Plain text fallback (if stored without encryption)
  RETURN v_row.value;
END;
$$;

-- Lock down: revoke from public/anon/authenticated, grant to service_role only.
REVOKE ALL ON FUNCTION _internal_get_ai_secret(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION _internal_get_ai_secret(text) FROM anon;
REVOKE ALL ON FUNCTION _internal_get_ai_secret(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION _internal_get_ai_secret(text) TO service_role;

-- ── 2. Admin status check — returns booleans, never the actual keys ────

DROP FUNCTION IF EXISTS admin_get_ai_keys_status(text);

CREATE OR REPLACE FUNCTION admin_get_ai_keys_status(p_admin_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_anthropic_set boolean;
  v_groq_set      boolean;
  v_anthropic_updated timestamptz;
  v_groq_updated      timestamptz;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT (value_encrypted IS NOT NULL OR (value IS NOT NULL AND length(value) > 0)),
         updated_at
  INTO v_anthropic_set, v_anthropic_updated
  FROM admin_settings WHERE key = 'anthropic_api_key';

  SELECT (value_encrypted IS NOT NULL OR (value IS NOT NULL AND length(value) > 0)),
         updated_at
  INTO v_groq_set, v_groq_updated
  FROM admin_settings WHERE key = 'groq_api_key';

  RETURN jsonb_build_object(
    'ok', true,
    'anthropic_set',         COALESCE(v_anthropic_set, false),
    'anthropic_updated_at',  v_anthropic_updated,
    'groq_set',              COALESCE(v_groq_set, false),
    'groq_updated_at',       v_groq_updated,
    'encryption_configured', current_setting('app.encryption_key', true) IS NOT NULL
                              AND length(current_setting('app.encryption_key', true)) >= 16
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_ai_keys_status(text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy (replace YourAdminPassword with the real one):
--
--   -- 1. Confirm encryption key is configured
--   SELECT admin_get_ai_keys_status('YourAdminPassword');
--   -- expect: encryption_configured=true (or false if you haven't run the
--   --         ALTER DATABASE statement at the top of this file)
--
--   -- 2. After saving a key from the admin UI, verify the edge function
--   --    can read it (run as the postgres superuser):
--   SELECT length(_internal_get_ai_secret('anthropic_api_key'));
--   -- expect: ~100 (length of an Anthropic key)
-- ════════════════════════════════════════════════════════════════════
