# Batch 1A — Fix 1 Deployment

**Issue:** Migrations 003 and 005 referenced a non-existent table `sbp_shop`. Your real table is named `shops` (no prefix).

**Impact:** Migration 003 errored out and rolled back. Nothing was created in your DB. Clean slate.

**Fix:** This zip contains corrected versions of `003_business_categories.sql` and `005_beta_logic.sql`. Migration 004 is unchanged and still works.

---

## Files In This Fix

| File | Change |
|---|---|
| `003_business_categories.sql` | `sbp_shop` → `shops` (8 places) |
| `005_beta_logic.sql` | `sbp_shop` → `shops` (24 places) |

No frontend code needs to change — all the lib/admin files call RPCs by name, not table names. The fix lives entirely in SQL.

---

## Step 1 — Replace the 2 SQL files in your repo

In your local repo:
1. Open `db/migrations/003_business_categories.sql` — **replace its contents** with the new `003_business_categories.sql` from this zip
2. Open `db/migrations/005_beta_logic.sql` — **replace its contents** with the new `005_beta_logic.sql` from this zip

Commit and push:
```bash
git add db/migrations/003_business_categories.sql db/migrations/005_beta_logic.sql
git commit -m "Batch 1A Fix 1: correct sbp_shop → shops in migrations 003 and 005"
git push
```

(The push only updates the SQL files — Vercel doesn't serve them, so no live-site impact.)

---

## Step 2 — Run all 3 migrations in Supabase, in order

> Important: even though only 003 and 005 changed, you must run **all three in order** because none of them have actually applied to your DB yet (003 errored and rolled back everything before any tables got created).

Open Supabase SQL Editor → New query for each.

### Run Migration 003 (corrected)
1. Open `db/migrations/003_business_categories.sql` in your repo, view raw on GitHub, copy all
2. Paste into a new Supabase SQL Editor query
3. Click **Run**
4. Wait for "Success. No rows returned." (~3 sec)

**Verify:**
```sql
SELECT count(*) AS macros FROM sbp_macro_categories;        -- expect 12
SELECT count(*) AS biz_cats FROM sbp_business_categories;   -- expect 80
SELECT count(DISTINCT profile) FROM sbp_module_profiles;    -- expect 18
SELECT column_name FROM information_schema.columns
  WHERE table_name = 'shops' AND column_name = 'shop_type'; -- expect 1 row
```

### Run Migration 004 (unchanged)
Same process. This one didn't need fixing.

**Verify:**
```sql
SELECT count(*) FROM sbp_seo_pages;       -- expect 14
SELECT count(*) FROM sbp_blog_posts;      -- expect 5
SELECT site_name FROM sbp_seo_global;     -- expect "ShopBill Pro"
```

### Run Migration 005 (corrected)
Same process.

**Verify:**
```sql
SELECT * FROM get_beta_config();
SELECT key, value FROM admin_settings WHERE key LIKE 'beta_%' ORDER BY key;
-- expect 5 beta_* rows
SELECT column_name FROM information_schema.columns
  WHERE table_name = 'shops' AND column_name IN ('is_beta_signup', 'beta_grace_until', 'plan_pre_beta');
-- expect 3 rows
```

---

## Step 3 — Verify the new admin pages work

Open in incognito: `https://app.shopbillpro.in/admin-login.html` → log in.

Visit each new page and confirm it loads with real data (not errors):

1. **`/admin-categories.html`** — should show 12 macro sections, 80 business types, 18 module profiles. Click a card → drawer shows enabled modules.
2. **`/admin-seo-global.html`** — should show "ShopBill Pro" in Site Name, all fields populated. Make a tiny edit and save → "✅ All changes saved"
3. **`/admin-seo-pages.html`** — table with 14 seeded pages
4. **`/admin-blog.html`** — list with 5 draft posts

If all four work, **Batch 1A is fully deployed.**

---

## What Stays The Same From Original Runbook

Everything else from `BATCH_1A_DEPLOY.md`:
- Service worker v1.4.0 verification (DevTools → Application → Service Workers)
- Optional: set hard beta end-date via `UPDATE admin_settings SET value = '2026-09-01' WHERE key = 'beta_end_date';`
- Optional: schedule nightly `process_beta_transitions()` cron

---

## Why This Happened — One-Sentence Lessons

The project memory note "shops are stored in `sbp_shop` table" was incorrect — the actual production schema uses unprefixed names (`shops`, `bills`, `customers`, `products`). Going forward, **Batch 1B will use the same naming convention** (no `sbp_` prefix on existing tables; `sbp_` only on the new platform-layer tables this batch introduced like `sbp_macro_categories`, `sbp_seo_pages`, etc.).

I'll update my mental model of your schema accordingly so we don't hit this in Batch 1B.
