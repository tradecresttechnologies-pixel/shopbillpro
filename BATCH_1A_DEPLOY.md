# Batch 1A Deployment Runbook

**Version:** 1A · **Date:** May 2026 · **Risk level:** LOW (all files are net-new — nothing existing is modified)

---

## What This Batch Delivers

Foundation infrastructure for Phase 1 launch, with **zero changes to existing user-facing pages**. Everything in this batch is either:
- A new database migration (additive)
- A new admin page (additive)
- A new shared library file (not yet wired in — happens in Batch 1B)
- A version bump of `service-worker.js` and `admin-db.js` (drop-in replacements)

| Layer | File | Type |
|-------|------|------|
| DB | `db/migrations/003_business_categories.sql` | NEW |
| DB | `db/migrations/004_seo_admin.sql` | NEW |
| DB | `db/migrations/005_beta_logic.sql` | NEW |
| Admin | `admin/admin-db.js` | REPLACE (additive — preserves all existing methods) |
| Admin | `admin/admin-seo-global.html` | NEW |
| Admin | `admin/admin-seo-pages.html` | NEW |
| Admin | `admin/admin-blog.html` | NEW |
| Admin | `admin/admin-categories.html` | NEW |
| Lib | `lib/sidebar-engine.js` | NEW (not yet wired) |
| Lib | `lib/beta-banner.js` | NEW (not yet wired) |
| Lib | `lib/shop-type-wizard.js` | NEW (not yet wired) |
| Root | `service-worker.js` | REPLACE (v1.3.0 → v1.4.0) |

---

## Pre-Deploy Checklist

- [ ] Latest code pulled to local from GitHub
- [ ] Supabase project `jfqeirfrkjdkqqixivru` accessible (you can log into the dashboard)
- [ ] Vercel project linked and auto-deploying on push
- [ ] Admin master password handy (you'll need to log in to test new admin pages)
- [ ] You have ~30 mins for the full deploy + verification

---

## Step 1 — Run SQL Migrations (5 mins)

Open the **Supabase SQL Editor** for project `jfqeirfrkjdkqqixivru` and run the three migrations **in this exact order**:

### 1a. Migration 003 — Business Categories
1. Open `db/migrations/003_business_categories.sql`
2. Copy the entire file contents
3. Paste into Supabase SQL Editor → **New query**
4. Click **Run**
5. Wait for "Success. No rows returned." (takes ~2-3 seconds)

**Verify:**
```sql
SELECT count(*) AS macros FROM sbp_macro_categories;        -- expect 12
SELECT count(*) AS biz_cats FROM sbp_business_categories;   -- expect 80
SELECT count(DISTINCT profile) FROM sbp_module_profiles;    -- expect 18
SELECT * FROM get_macro_categories() LIMIT 5;               -- expect 5 rows
```

### 1b. Migration 004 — SEO Admin
1. Open `db/migrations/004_seo_admin.sql`
2. Copy entire contents
3. Paste into a new Supabase SQL Editor query
4. Click **Run**

**Verify:**
```sql
SELECT count(*) FROM sbp_seo_pages;       -- expect 14
SELECT count(*) FROM sbp_blog_posts;      -- expect 5
SELECT site_name FROM sbp_seo_global;     -- expect "ShopBill Pro"
SELECT * FROM get_page_seo('/');          -- expect 1 row with title
```

### 1c. Migration 005 — Beta Logic
1. Open `db/migrations/005_beta_logic.sql`
2. Copy, paste, run.

**Verify:**
```sql
SELECT * FROM get_beta_config();          -- expect 1 row, is_active=true
SELECT is_beta_mode_active();             -- expect true
SELECT key, value FROM admin_settings WHERE key LIKE 'beta_%' ORDER BY key;
-- expect 5 rows: beta_announcement, beta_duration_days, beta_end_date, beta_grace_days, beta_mode_active
```

If any verification query returns wrong counts, **STOP** and check the SQL editor output for errors before proceeding.

---

## Step 2 — Copy Files to Repo (10 mins)

From the unpacked `batch1a` directory, copy files into your repo at these paths:

### 2a. New folders to create at repo root
```
your-repo/
├── db/
│   └── migrations/        # NEW folder
├── lib/                   # NEW folder
└── (existing files...)
```

### 2b. File map (source → destination)

| Source | Destination |
|--------|-------------|
| `db/migrations/003_business_categories.sql` | `db/migrations/003_business_categories.sql` |
| `db/migrations/004_seo_admin.sql` | `db/migrations/004_seo_admin.sql` |
| `db/migrations/005_beta_logic.sql` | `db/migrations/005_beta_logic.sql` |
| `admin/admin-db.js` | `admin-db.js` ⚠️ **REPLACES existing** |
| `admin/admin-seo-global.html` | `admin-seo-global.html` |
| `admin/admin-seo-pages.html` | `admin-seo-pages.html` |
| `admin/admin-blog.html` | `admin-blog.html` |
| `admin/admin-categories.html` | `admin-categories.html` |
| `lib/sidebar-engine.js` | `lib/sidebar-engine.js` |
| `lib/beta-banner.js` | `lib/beta-banner.js` |
| `lib/shop-type-wizard.js` | `lib/shop-type-wizard.js` |
| `service-worker.js` | `service-worker.js` ⚠️ **REPLACES existing** |

> ⚠️ **`admin-db.js` REPLACEMENT NOTE:** The new file is fully additive — it preserves all 18 existing methods (getMetrics, listShops, listSubscriptions, approveSubscription, rejectSubscription, changePlan, suspendShop, getSettings, setSetting, getWebhookEvents, getAuditLog, getRevenueChart, _mock, etc.) and appends the new SEO/blog/redirects/categories/beta methods. No existing admin page will break.

### 2c. Commit and push

```bash
git add db/ lib/ admin-db.js admin-seo-global.html admin-seo-pages.html admin-blog.html admin-categories.html service-worker.js
git commit -m "Batch 1A: foundation — SQL migrations, SEO admin pages, shared libs, SW v1.4.0"
git push
```

Vercel auto-deploys. Wait ~60-90 seconds for green build.

---

## Step 3 — Verify Live Deploy (10 mins)

### 3a. Smoke test — site still works
- Open `https://app.shopbillpro.in/` in an incognito window
- Confirm landing page loads, sign up button works
- Open `https://app.shopbillpro.in/dashboard.html` (existing user) — should load normally

If anything is broken at this step, do a **Vercel rollback** to the previous deploy. Nothing in Batch 1A should affect existing pages — if it does, the migration files may not have run cleanly.

### 3b. Test new admin pages

Log into the admin panel: `https://app.shopbillpro.in/admin-login.html` (master password)

Visit each new page and confirm it loads without errors:

1. **`/admin-seo-global.html`**
   - Should load and show "✅ Loaded" status
   - Site Name field should show "ShopBill Pro"
   - Org Name should show "TradeCrest Technologies Pvt. Ltd."
   - Make a tiny edit (e.g., update Site Tagline), click Save → should toast "✅ All changes saved"

2. **`/admin-seo-pages.html`**
   - Should display 14 seeded pages in a table
   - Click any row → edit modal opens with full SEO fields
   - Try **＋ New Page** → modal opens fresh

3. **`/admin-blog.html`**
   - Should show 5 draft posts
   - Click any post → edit modal opens with markdown editor
   - Switch to **👁️ Preview** tab → renders the markdown

4. **`/admin-categories.html`**
   - Should show 12 macro sections, each with cards
   - Stats row shows: 12 macros, 80 types, 18 profiles
   - Click any business type card → drawer slides in with module list

### 3c. Service worker version check

In any user-facing page (e.g. dashboard), open DevTools → Application → Service Workers:
- **Old SW** (`shopbillpro-v1.3.0-20260427`) should show as redundant
- **New SW** (`shopbillpro-v1.4.0-20260504`) should show as activated
- DevTools → Application → Cache Storage should now contain `shopbillpro-v1.4.0-20260504`

If the user's browser still shows v1.3.0 after a hard refresh, click **Update** in DevTools.

### 3d. RPC sanity test

In Supabase SQL Editor, run:
```sql
-- Should return module rows for the standard profile
SELECT * FROM get_shop_modules('00000000-0000-0000-0000-000000000000');
-- Returns standard fallback if shop ID doesn't exist (which it shouldn't with that UUID)

-- Test admin RPCs (replace TOKEN with your actual admin token from sessionStorage)
SELECT * FROM admin_get_seo_global('YOUR_ADMIN_TOKEN_HERE');
SELECT count(*) FROM admin_list_seo_pages('YOUR_ADMIN_TOKEN_HERE');
SELECT * FROM admin_get_beta_stats('YOUR_ADMIN_TOKEN_HERE');
```

---

## Step 4 — Post-Deploy Configuration (5 mins)

### 4a. Set up beta hard end-date (optional but recommended)

If you want all beta users to expire on the same day (instead of staggered 60-day from-signup):

```sql
-- Set hard beta end date (example: Sept 1 2026)
UPDATE admin_settings SET value = '2026-09-01' WHERE key = 'beta_end_date';
```

To leave it date-from-signup (60 days each), keep `beta_end_date` blank.

### 4b. Tweak beta duration if needed

```sql
-- Default is 60 days. Change if you want longer/shorter beta.
UPDATE admin_settings SET value = '90' WHERE key = 'beta_duration_days';
```

### 4c. Schedule nightly beta transition (Supabase pg_cron — optional)

If you want auto-downgrade after grace period without manual intervention:

```sql
-- Run this once in Supabase SQL Editor
SELECT cron.schedule(
  'sbp-process-beta-transitions',
  '5 0 * * *',                              -- 00:05 UTC daily (~ 05:35 IST)
  $$ SELECT public.process_beta_transitions(); $$
);
```

If you don't schedule it, you can run `SELECT process_beta_transitions();` manually from the SQL editor when you want to clean up expired betas.

---

## Step 5 — Mark Batch 1A Complete

When all of the above passes, you've successfully deployed:
- ✅ 12 macro categories + 80+ business types + 18 module profiles in DB
- ✅ Full SEO admin panel (global, pages, blog, redirects)
- ✅ Beta plan logic with countdown banners ready
- ✅ Smart sidebar engine ready (not yet wired into pages)
- ✅ Shop type signup wizard ready (not yet wired into signup flow)
- ✅ Service worker v1.4.0 caching new lib files

**Nothing existing has changed in user-facing pages.** Existing users will see no difference — that's the goal of this batch.

---

## Troubleshooting

### "Migration 003 fails with 'sbp_shop does not exist'"
Migration 003 references `sbp_shop` table. Run `audit_round_db_patch.sql` and `admin_panel_full.sql` first if they haven't been deployed.

### "Migration 004 fails on 'admin_verify_token does not exist'"
Migration 004 uses `admin_verify_token` from `admin_panel_full.sql`. Run that file first.

### Admin SEO Global page shows "❌ No SEO global row"
Migration 004 didn't run, or the singleton `INSERT INTO sbp_seo_global (id) VALUES (1)` didn't fire. Re-run migration 004.

### Admin Categories page shows "Loading..." forever
Browser console will show a Supabase RPC error. Most common cause: migration 003 not run, or `sbp_module_profiles` table empty. Re-check Step 1a verification.

### Service worker still v1.3.0 after deploy
- Hard refresh (Ctrl+Shift+R / Cmd+Shift+R)
- DevTools → Application → Service Workers → click "Unregister", then reload
- The next load picks up the new version

### Need to roll back?
This batch only adds files. To roll back:
1. `git revert HEAD` and push (removes the file changes)
2. SQL migrations are idempotent — they can stay applied without harm
3. Or, if you really want to drop the new tables:
   ```sql
   DROP TABLE IF EXISTS sbp_seo_redirects CASCADE;
   DROP TABLE IF EXISTS sbp_blog_posts CASCADE;
   DROP TABLE IF EXISTS sbp_seo_pages CASCADE;
   DROP TABLE IF EXISTS sbp_seo_global CASCADE;
   DROP TABLE IF EXISTS sbp_module_profiles CASCADE;
   DROP TABLE IF EXISTS sbp_business_categories CASCADE;
   DROP TABLE IF EXISTS sbp_macro_categories CASCADE;
   ALTER TABLE sbp_shop DROP COLUMN IF EXISTS shop_type;
   ALTER TABLE sbp_shop DROP COLUMN IF EXISTS is_beta_signup;
   ALTER TABLE sbp_shop DROP COLUMN IF EXISTS beta_grace_until;
   ALTER TABLE sbp_shop DROP COLUMN IF EXISTS plan_pre_beta;
   DELETE FROM admin_settings WHERE key LIKE 'beta_%';
   ```
   (Don't run this unless you really need to start over — destroys all data in those tables.)

---

## Next Step: Batch 1B Integration

After Batch 1A is verified working in production, Batch 1B will:
1. Wire `lib/sidebar-engine.js` into all 18 user-facing pages (replaces inconsistent inline sidebar markup)
2. Wire `lib/beta-banner.js` at top of every user-facing page
3. Wire `lib/shop-type-wizard.js` into the signup flow in `index.html`
4. Add Hindi `lang-en`/`lang-hi` spans to `billing.html`, `subscription.html`, `team.html`
5. Add mobile hamburger button so Plans/Team are reachable from any page on mobile
6. Modify `subscription.html` to show beta countdown + hide upgrade CTAs during beta
7. Add `apply_beta_plan(shop_id)` RPC call after shop creation in signup

Batch 1B touches existing files — that's why it's a separate deploy after we verify 1A is solid.

---

**Questions or issues during deploy?** Take screenshots of any errors and we'll debug them together before moving to 1B.
