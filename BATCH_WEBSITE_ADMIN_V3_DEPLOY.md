# Batch v3 — Website Builder Admin Panel (Scope B)

Adds full admin integration for the AI Website Builder. Pairs with Batch v2
(044 migration + builder UI). After this batch, you can manage every aspect
of the feature from `/admin-websites.html` without touching SQL.

---

## DEPLOY PATHS

```
NEW      db/migrations/045_admin_website_builder.sql
NEW      admin-websites.html                                  ← repo root
REPLACE  admin-dashboard.html                                  ← adds "Websites" menu item
REPLACE  supabase/functions/generate-ai-website/index.ts       ← DB-driven prompt + logging
```

---

## DEPLOY ORDER

### 1. SQL migration (FIRST — per locked rule)

Run in Supabase SQL Editor:
```
db/migrations/045_admin_website_builder.sql
```

This creates 2 new tables (`ai_prompt_templates`, `ai_generation_log`), 12 new RPCs,
and seeds the initial prompt template + default provider setting.

Verify with:
```sql
-- Should return 1 row with the seeded prompt
SELECT name, version, is_active FROM ai_prompt_templates;

-- Should return a 4-element JSONB with ok=true
SELECT get_active_ai_prompt('website_v1');

-- Replace 'YourAdminPassword' with the actual password you set earlier
SELECT admin_list_websites('YourAdminPassword', NULL, 'all', 5, 0);
SELECT admin_website_stats('YourAdminPassword', 'month');
```

### 2. Edge function (replace existing)

```bash
# (Optional) if you want Groq fallback:
supabase secrets set GROQ_API_KEY=gsk_...

# Redeploy with the new index.ts
supabase functions deploy generate-ai-website --no-verify-jwt=false
```

The new version reads the prompt from DB on every call and logs every attempt
(success + failure) to `ai_generation_log` for admin visibility.

### 3. Front-end (push to GitHub)

Copy these into your repo:
```
admin-websites.html      → repo root  (NEW)
admin-dashboard.html     → repo root  (REPLACE — one-line nav addition)
```

Push to GitHub → Vercel auto-deploys ~30 sec.

---

## VERIFY (after all 3 steps)

1. Login at `/admin-login.html` → land on admin dashboard
2. Left sidebar now shows **🌐 Websites** between Users and Revenue
3. Click **Websites** → 4 tabs visible: List · Analytics · Provider & Prompts · Failures
4. **List tab** — shows all shops with AI website state. Empty if no one has generated yet.
   - Click **View** on any row → modal with full detail + live preview iframe
   - **Force unpublish** button (requires reason, logged to audit)
   - **Grant bonus generations** button (decrements monthly counter)
5. **Analytics tab** — pick period dropdown:
   - 5 KPI cards (sites, published, generations, cost, avg gen time)
   - Daily generation bar chart (last 30 days)
   - Top business types donut + provider pie
6. **Provider & Prompts tab**:
   - Switch active AI provider (Claude / Groq)
   - Edit the master prompt template
   - Save as new version → it activates immediately for next generation
   - Version history with one-click rollback
7. **Failures tab** — empty if all is healthy. If a generation fails, the error
   message + provider + shop appears here.

### End-to-end test

1. Go to `/website-builder.html` as a test shop owner → generate a website
2. As admin, click **Websites** → see the new site in the list
3. Click **Analytics** → counter incremented, cost shown
4. Edit prompt → save new version → activate → regenerate as shop → confirm new version was used (check `ai_generation_log.prompt_template`)

---

## ARCHITECTURE NOTES

### Prompt versioning
- All prompts stored in `ai_prompt_templates` table, keyed by `(name, version)`
- Only one version per `name` can be `is_active=true` at a time
- Edge function calls `get_active_ai_prompt('website_v1')` on every generation
- **Change a prompt without redeploying** the edge function

### Cost tracking
- Claude Sonnet 4 pricing: $3/M input tokens, $15/M output tokens
- Edge function captures token counts from Claude API response and passes them to `log_ai_generation`
- `log_ai_generation` RPC computes the dollar amount and stores it
- Aggregated in `admin_website_stats` for analytics dashboard

### Failure logging
- Edge function wraps the whole generation in try/catch
- On any error, calls `log_ai_generation` with `status='failure'` + error message
- Surfaces in admin **Failures** tab for debugging
- Best-effort — if logging itself fails, the user error response is still returned

### Quota bonus mechanism
- `admin_grant_website_quota` decrements `ai_regenerations_used` by N (floor at 0)
- This effectively grants N free regenerations this month
- Audit logged automatically with the admin's reason

### Force unpublish
- Sets `ai_published = false` on `sbp_shop_websites`
- Public `/s/{slug}` page immediately reverts to legacy `content_json` renderer
- Audit logged with reason (≥5 chars required)
- Reversible: shopkeeper can re-publish from their own builder UI

### Audit trail
- Every admin action (unpublish, quota grant, prompt save/activate, provider change)
  → row in `admin_audit_log` via `admin_log_action()` RPC
- Visible in **Audit Logs** admin page (`admin-audit.html`)

---

## ROLLBACK

To disable any admin function temporarily without code change:
```sql
REVOKE EXECUTE ON FUNCTION admin_force_unpublish_website(text, uuid, text) FROM authenticated, anon;
```

To revert to v1 prompt:
```sql
-- Find the version you want
SELECT id, version, notes FROM ai_prompt_templates WHERE name='website_v1' ORDER BY version;
-- Activate it (replace UUID)
SELECT admin_activate_prompt_template('YourAdminPassword', '<uuid>');
```

To switch back to Claude if Groq misbehaves:
```sql
SELECT admin_set_ai_provider_config('YourAdminPassword', 'claude');
```

---

## OUT OF SCOPE (defer to future batches)

- Bulk operations on multiple shops at once
- Email notifications to admin on failures
- Per-prompt A/B testing (assign different prompts to different shops)
- Cost budget alerts (auto-disable feature when monthly cost > $X)
- Per-shop generation history export (CSV)
- Admin-side "regenerate as user" feature (impersonation workflow)
