# Batch v3.2 — AI API Key Management via Admin Panel

Lets you paste/rotate Anthropic + Groq API keys directly from
`/admin-websites.html` → Provider & Prompts tab. No more CLI required.

## DEPLOY PATHS

```
NEW      db/migrations/046_ai_api_keys.sql
REPLACE  admin-websites.html                                 ← repo root
REPLACE  supabase/functions/generate-ai-website/index.ts     ← redeploy via CLI
```

## ⚠️ ONE-TIME PREREQUISITE (skip if Razorpay key encryption already works)

The encryption uses pgcrypto + a Postgres-level secret. If you've already
saved a Razorpay secret successfully via admin-settings.html, this is set
and you can skip to step 1.

Otherwise — paste this in Supabase SQL Editor first:
```sql
ALTER DATABASE postgres SET app.encryption_key = 'pick-any-strong-32-char-secret!';
```
Then **close + reopen** the SQL editor tab (so the setting is loaded into
the new session). Pick any random 32+ char string — you only need it once;
it never leaves the DB.

To verify it's set:
```sql
SELECT current_setting('app.encryption_key', true) IS NOT NULL AS ok;
-- expected: ok = true
```

---

## DEPLOY ORDER

### 1. SQL migration
Run `db/migrations/046_ai_api_keys.sql` in Supabase SQL Editor.

It adds 2 functions:
- `_internal_get_ai_secret(text)` — service-role only, used by edge function
- `admin_get_ai_keys_status(text)` — used by admin UI to show ✅/⚪ status

### 2. Edge function (replace)
```bash
supabase functions deploy generate-ai-website --no-verify-jwt=false
```
The new version reads the API key from DB first, falls back to env var.

### 3. Front-end
Copy `admin-websites.html` to repo root, commit + push → Vercel auto-deploys.

---

## USE

1. Open `/admin-websites.html` → click **Provider & Prompts** tab
2. New **🔑 AI Provider API Keys** card at the top
3. If you see a red banner "Encryption key not set" → go do the prerequisite above
4. Paste your Anthropic key (starts with `sk-ant-…`) → click **Save Keys**
5. Status row updates: ✅ Anthropic: set · updated just now
6. Click **🧪 Test Anthropic key** — runs a real generation against the test shop
   - ✅ Toast: "Anthropic key works! Generated XXXX chars via claude"
   - ❌ If error: check the **Failures** tab for the exact error message

After saving the key in admin UI, you can **remove the Supabase secret**
if you set it before:
```bash
supabase secrets unset ANTHROPIC_API_KEY    # optional cleanup
```
The edge function will use DB-stored keys exclusively from this point.

---

## SECURITY MODEL

- API keys are encrypted at rest via pgcrypto (`pgp_sym_encrypt_bytea`)
  with the `app.encryption_key` database setting.
- `_internal_get_ai_secret(p_key)`:
  - `SECURITY DEFINER` (runs as DB owner, can read encrypted column)
  - `REVOKE` from `public`, `anon`, `authenticated`
  - `GRANT` only to `service_role`
  - Whitelist of allowed keys hardcoded (`anthropic_api_key`, `groq_api_key`)
    — any other key throws `invalid_key`
- The edge function uses `SUPABASE_SERVICE_ROLE_KEY` (auto-set by Supabase
  in every edge function) to call this RPC.
- `admin_get_ai_keys_status` returns **booleans + timestamps only**, never
  the actual key values, even to the admin UI.
- Browser DevTools "Network" tab will never see the decrypted key — the
  decryption happens server-side, key flows DB → Edge Function → Anthropic
  API, never back to the browser.

---

## ROLLBACK

If anything breaks:
```sql
-- Clear the stored key (reverts to env-var fallback)
DELETE FROM admin_settings WHERE key = 'anthropic_api_key';
DELETE FROM admin_settings WHERE key = 'groq_api_key';

-- Or temporarily kill DB key resolution by revoking service_role access:
REVOKE EXECUTE ON FUNCTION _internal_get_ai_secret(text) FROM service_role;
```
Then re-set the env var as before:
```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```
