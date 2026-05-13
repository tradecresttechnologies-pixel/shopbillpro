-- ════════════════════════════════════════════════════════════════════
-- 047_ai_api_keys_vault.sql
-- Migrate AI API key storage from pgcrypto (broken on Supabase managed PG
-- because ALTER DATABASE requires superuser) to Supabase Vault.
--
-- Vault is Supabase's purpose-built secret store. It uses authenticated
-- encryption via libsodium with a key managed by Supabase infrastructure.
-- No ALTER DATABASE needed; no app.encryption_key setting required.
--
-- Replaces / supersedes parts of 046:
--   • _internal_get_ai_secret      → re-implemented on top of Vault
--   • admin_get_ai_keys_status     → reads from Vault
--   • admin_save_ai_api_key (NEW)  → writes to Vault (used by admin UI)
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Ensure Vault extension is enabled ───────────────────────────────
-- (Enabled by default on new Supabase projects; safe to re-run.)

CREATE EXTENSION IF NOT EXISTS supabase_vault WITH SCHEMA vault CASCADE;

-- ── 2. Replace _internal_get_ai_secret with Vault-backed version ───────

DROP FUNCTION IF EXISTS _internal_get_ai_secret(text);

CREATE OR REPLACE FUNCTION _internal_get_ai_secret(p_key text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = vault, public
AS $$
DECLARE
  v_secret text;
BEGIN
  -- Whitelist allowed key names (defense in depth)
  IF p_key NOT IN ('anthropic_api_key','groq_api_key') THEN
    RAISE EXCEPTION 'invalid_key';
  END IF;

  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets
  WHERE name = p_key
  LIMIT 1;

  RETURN v_secret;  -- NULL if not set
END;
$$;

REVOKE ALL ON FUNCTION _internal_get_ai_secret(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION _internal_get_ai_secret(text) FROM anon;
REVOKE ALL ON FUNCTION _internal_get_ai_secret(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION _internal_get_ai_secret(text) TO service_role;

-- ── 3. Admin RPC: save / update an AI API key ─────────────────────────

DROP FUNCTION IF EXISTS admin_save_ai_api_key(text, text, text);

CREATE OR REPLACE FUNCTION admin_save_ai_api_key(
  p_admin_token text,
  p_key_name    text,   -- 'anthropic_api_key' or 'groq_api_key'
  p_value       text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = vault, public
AS $$
DECLARE
  v_existing_id uuid;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF p_key_name NOT IN ('anthropic_api_key','groq_api_key') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_key_name');
  END IF;

  IF p_value IS NULL OR length(trim(p_value)) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'value_too_short');
  END IF;

  -- Check if a secret with this name already exists in Vault
  SELECT id INTO v_existing_id FROM vault.secrets WHERE name = p_key_name LIMIT 1;

  IF v_existing_id IS NULL THEN
    -- Create new secret
    PERFORM vault.create_secret(
      p_value,
      p_key_name,
      CASE p_key_name
        WHEN 'anthropic_api_key' THEN 'Anthropic Claude API key'
        WHEN 'groq_api_key'      THEN 'Groq API key'
        ELSE ''
      END
    );
  ELSE
    -- Update existing secret using Supabase Vault's update helper
    PERFORM vault.update_secret(v_existing_id, p_value);
  END IF;

  PERFORM admin_log_action(
    p_admin_token, 'set_ai_api_key', 'vault_secret', p_key_name,
    NULL,
    jsonb_build_object('key_name', p_key_name, 'updated', v_existing_id IS NOT NULL),
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'key_name', p_key_name,
    'action', CASE WHEN v_existing_id IS NULL THEN 'created' ELSE 'updated' END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_save_ai_api_key(text, text, text) TO authenticated, anon;

-- ── 4. Replace admin_get_ai_keys_status with Vault-backed version ──────

DROP FUNCTION IF EXISTS admin_get_ai_keys_status(text);

CREATE OR REPLACE FUNCTION admin_get_ai_keys_status(p_admin_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = vault, public
AS $$
DECLARE
  v_anthropic record;
  v_groq      record;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  SELECT id, name, updated_at INTO v_anthropic
  FROM vault.secrets WHERE name = 'anthropic_api_key' LIMIT 1;

  SELECT id, name, updated_at INTO v_groq
  FROM vault.secrets WHERE name = 'groq_api_key' LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'anthropic_set',         v_anthropic.id IS NOT NULL,
    'anthropic_updated_at',  v_anthropic.updated_at,
    'groq_set',              v_groq.id IS NOT NULL,
    'groq_updated_at',       v_groq.updated_at,
    'encryption_configured', true   -- always true with Vault — no setup needed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_get_ai_keys_status(text) TO authenticated, anon;

-- ── 5. Optional: delete an AI key (admin support) ──────────────────────

DROP FUNCTION IF EXISTS admin_delete_ai_api_key(text, text);

CREATE OR REPLACE FUNCTION admin_delete_ai_api_key(
  p_admin_token text,
  p_key_name    text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = vault, public
AS $$
DECLARE v_deleted int;
BEGIN
  IF NOT admin_verify_token(p_admin_token) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_token');
  END IF;

  IF p_key_name NOT IN ('anthropic_api_key','groq_api_key') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_key_name');
  END IF;

  DELETE FROM vault.secrets WHERE name = p_key_name;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  PERFORM admin_log_action(
    p_admin_token, 'delete_ai_api_key', 'vault_secret', p_key_name,
    NULL, jsonb_build_object('rows_deleted', v_deleted), NULL
  );

  RETURN jsonb_build_object('ok', true, 'deleted', v_deleted > 0);
END;
$$;

GRANT EXECUTE ON FUNCTION admin_delete_ai_api_key(text, text) TO authenticated, anon;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy (replace YourAdminPassword with the real one):
--
--   -- 1. Confirm Vault is enabled
--   SELECT * FROM pg_extension WHERE extname = 'supabase_vault';
--
--   -- 2. Status RPC should return encryption_configured=true
--   SELECT admin_get_ai_keys_status('YourAdminPassword');
--
--   -- 3. After saving a key from admin UI, confirm it's in vault.secrets
--   SELECT id, name, created_at, updated_at FROM vault.secrets ORDER BY created_at DESC;
--
--   -- 4. As postgres role (or via the edge function with service_role JWT):
--   SELECT length(_internal_get_ai_secret('anthropic_api_key'));
-- ════════════════════════════════════════════════════════════════════
