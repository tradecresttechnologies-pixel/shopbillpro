# Batch v3.3 — Switch to Supabase Vault for AI API Keys

Replaces the broken pgcrypto encryption path from Batch v3.2 with
**Supabase Vault** — purpose-built secret storage that doesn't need
`ALTER DATABASE` superuser permissions.

## Why this batch

Batch v3.2 tried to use `app.encryption_key` set via `ALTER DATABASE`.
But Supabase's managed Postgres SQL Editor runs as a role that **cannot**
do `ALTER DATABASE` (gets `42501: permission denied`). So pgcrypto-based
encryption was a dead end on Supabase. Vault is the official Supabase
solution.

---

## DEPLOY PATHS

```
NEW      db/migrations/047_ai_api_keys_vault.sql
REPLACE  admin-websites.html                                  ← repo root
```

The edge function **doesn't change** — the v3.2 `index.ts` already calls
`_internal_get_ai_secret(p_key)`, and migration 047 replaces that function's
implementation. So the existing deployed edge function will Just Work
once migration 047 runs.

## SKIP these steps from v3.2

❌ **Do NOT run** `ALTER DATABASE postgres SET app.encryption_key = ...`
   — not needed anymore.

❌ Migration 046 (`046_ai_api_keys.sql`) is now superseded. If you already
   ran it, that's fine — migration 047 replaces the relevant functions.

---

## DEPLOY ORDER

### 1. SQL migration (Supabase SQL Editor)

Run `db/migrations/047_ai_api_keys_vault.sql`.

It does:
1. `CREATE EXTENSION IF NOT EXISTS supabase_vault` — enables Vault if not on
2. Replaces `_internal_get_ai_secret` to read from `vault.decrypted_secrets`
3. Adds `admin_save_ai_api_key(token, key_name, value)` for the admin UI
4. Updates `admin_get_ai_keys_status` to read from `vault.secrets`
5. Adds `admin_delete_ai_api_key` for rotation

**If you get an error about Vault not being available:**
- Go to Supabase Dashboard → Database → Extensions
- Search for "vault" → toggle ON
- Re-run the migration

### 2. Front-end

Copy `admin-websites.html` to repo root, commit + push → Vercel auto-deploys.

### 3. (Skip if v3.2 edge function already deployed)

The edge function from v3.2 already works. Migration 047 swaps the
backing store transparently. No `supabase functions deploy` needed.

If you never deployed the v3.2 edge function, do it now:
```bash
supabase functions deploy generate-ai-website --no-verify-jwt=false
```

---

## VERIFY

1. Open `/admin-websites.html` → **Provider & Prompts** tab
2. Red banner should be **gone** ✅ (Vault auto-configured)
3. Status row shows: ⚪ Anthropic: not set · ⚪ Groq: not set
4. Paste your Anthropic key (`sk-ant-…`) → click **💾 Save Keys**
5. Toast: "Saved: Anthropic ✓"
6. Status updates: ✅ Anthropic: set · updated just now
7. Click **🧪 Test Anthropic key** → wait ~20 sec → toast:
   "✅ Anthropic key works! Generated XXXX chars via claude"

You can also verify via SQL:
```sql
-- Should show your saved secret(s)
SELECT name, created_at, updated_at FROM vault.secrets;

-- Decrypted access (only postgres role can do this)
SELECT name, length(decrypted_secret) FROM vault.decrypted_secrets;
```

---

## SECURITY MODEL

- **At-rest encryption:** Supabase Vault uses libsodium authenticated
  encryption. Each project has its own root key managed by Supabase
  infrastructure (encrypted with project-specific KEK).
- **Access control:**
  - `vault.secrets` table — only `postgres` role can read directly
  - `vault.decrypted_secrets` view — same restriction
  - Our `_internal_get_ai_secret` RPC is `SECURITY DEFINER` so it runs
    as the function owner (which can read Vault), but we `REVOKE` it
    from `anon` and `authenticated`. Only `service_role` (used by edge
    functions) can call it.
- **Key whitelist:** `_internal_get_ai_secret` and `admin_save_ai_api_key`
  both reject any key name other than `anthropic_api_key` or `groq_api_key`,
  so even if compromised, they can't be used to leak other Vault secrets.
- **Audit trail:** every save goes through `admin_log_action()` → row in
  `admin_audit_log` table (viewable in `admin-audit.html`).

---

## ROLLBACK

If anything breaks, the edge function falls back to env vars:
```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```
That works without any DB changes — the edge function only reads from
Vault first, then falls back to `Deno.env.get("ANTHROPIC_API_KEY")`.

To completely revert the function to env-only:
```sql
-- Cripple the Vault read path
REVOKE EXECUTE ON FUNCTION _internal_get_ai_secret(text) FROM service_role;
```

---

## NOTES FOR FUTURE BATCHES

The Razorpay secrets in `admin-settings.html` still use the pgcrypto path
from `admin_panel_full.sql`. They'll hit the **same** `ALTER DATABASE`
permission error if/when you try to save a Razorpay secret. When we build
Batch Razorpay v1 next, we'll migrate those to Vault too — the pattern
in this batch will be the template.
