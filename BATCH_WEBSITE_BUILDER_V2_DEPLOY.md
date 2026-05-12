# Batch Website Builder v2 — DEPLOY

Replaces the broken AI Website Builder from the previous chat. All five
files from that batch had show-stopping bugs (wrong table, MySQL syntax,
fake `/api/*` endpoints, edge function wrapped in a JS string).

## DEPLOY PATHS

```
DELETE  db/migrations/042_ai_website_builder.sql        ← broken, do NOT run
DELETE  db/migrations/043_website_builder_rpcs.sql      ← broken, do NOT run
DELETE  supabase/functions/generate-website/index.ts    ← not valid Deno
        (also remove the whole supabase/functions/generate-website/ folder)

NEW     db/migrations/044_website_builder_v2.sql                       (15 KB)
NEW     supabase/functions/generate-ai-website/index.ts                 (5 KB)
REPLACE website-builder.html                                            (12 KB)
REPLACE lib/website-builder.js                                          (11 KB)
REPLACE lib/sidebar-engine.js                                           (one-line href change)
REPLACE s.html                                                          (AI fork at top of renderShop)
```

If 042/043 were never deployed to Supabase, they're harmless on disk —
just remove them so future audits don't get confused. Migration 044
also runs cleanup `DROP TABLE / DROP FUNCTION` statements that wipe any
artifacts in case 042 was partially run.

## DEPLOY ORDER

### 1. SQL migration (FIRST — per locked rule)

Open Supabase SQL Editor and run:

```
db/migrations/044_website_builder_v2.sql
```

You should see at the end: `Query returned successfully` + the NOTIFY.

Verify:
```sql
SELECT * FROM _sbp_website_tier_limits('pro');
-- Expected: {"plan":"pro","monthly_limit":2,"lifetime_free_limit":1}

SELECT sbp_get_website_builder_state();
-- (Logged-in user only — run from the SQL Editor as your own session
--  or test via the app after step 3)
```

### 2. Edge function

```bash
# Set the secret (one time)
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...

# Deploy
supabase functions deploy generate-ai-website --no-verify-jwt=false
```

`--no-verify-jwt=false` keeps the default behaviour: edge function requires
a valid JWT. The Supabase JS client adds it automatically when calling
`_sb.functions.invoke('generate-ai-website', ...)`.

### 3. Front-end

Copy the 4 front-end files into the repo:
```
website-builder.html        → repo root
lib/website-builder.js      → repo lib/
lib/sidebar-engine.js       → repo lib/  (REPLACE, one-line change)
s.html                      → repo root  (REPLACE, AI fork added)
```

Then push to GitHub → Vercel auto-deploys.

### 4. (Optional) Delete the broken files

```bash
rm db/migrations/042_ai_website_builder.sql
rm db/migrations/043_website_builder_rpcs.sql
rm -rf supabase/functions/generate-website
git add -A && git commit -m "Remove broken Phase 5a v1 files; superseded by Batch Website Builder v2"
git push
```

## VERIFY

After deploy:

1. Log in as test shop owner (Vinay / sars0558). Open dashboard.
2. Sidebar shows **🌐 Website [BIZ]**. Click it.
3. **Expected:** `/website-builder.html` opens with shop name pre-filled,
   form ready, plan info banner shows correct tier + quota.
4. Pick a color → live preview on right updates instantly.
5. Click **Save Draft** → toast "Draft saved ✓".
6. Click **Generate with AI ✨** → loading overlay 15–30s → page reloads
   with the generated draft saved. Tier banner shows used count +1.
7. Click **Publish** → toast "Website published ✓". A green "View Live ↗"
   button appears in the topbar.
8. Click "View Live ↗" → opens `/s/{your-slug}` → AI-generated HTML
   renders inside a sandboxed iframe.
9. Free user: limited to 1 lifetime generation. Try a second → server
   returns `quota_exhausted`. UI shows upgrade prompt.

## ARCHITECTURE NOTES

- **No new tables.** Extends existing `sbp_shop_websites` from migration
  008 with `ai_*` columns. Same row, same slug, same `/s/{slug}` URL.
- **AI HTML is optional.** When `ai_published=false` OR
  `ai_generated_html IS NULL`, `s.html` falls back to the legacy
  content_json renderer (existing about + gallery + services flow).
- **Server-side quota.** `sbp_record_ai_website_generation` re-checks
  quota inside the same transaction that increments the counter. Even
  if the front-end is bypassed, free users cannot exceed 1 generation.
- **Plan normalisation.** `enterprise → business` and expired plans →
  `free`, consistently. No legacy plan name leaks into limit math.
- **JWT-scoped.** Edge function calls Supabase with the user's JWT, so
  every RPC sees the correct `auth.uid()`. No service-role escalation.
- **Bilingual.** All UI strings have `<span class="lang-en">` +
  `<span class="lang-hi">` pairs.
- **FOUC fix applied.** Pre-paint theme script in `<head>`.

## OPEN ITEMS (out of scope for this batch)

- Admin panel UI to view generated sites + quota usage per shop (Phase 5b).
- Multi-page support — current MVP is single-page HTML. The `pages_count`
  column is in 042 (dropped) but not yet in 044; add when designing the
  multi-page editor.
- Edit-in-place (visual editor) — for now regeneration is the only way
  to change the AI output. Acceptable for v2; defer to Phase 5c.
- Custom domain wiring — `sbp_shop_websites.custom_domain` exists from
  008 but no admin UI hooks it up.

## ROLLBACK

If something goes wrong, the AI feature can be disabled instantly without
any code change by running:

```sql
UPDATE sbp_shop_websites SET ai_published = false;
```

All shop pages will revert to the legacy content_json renderer
(unchanged from before this batch).
