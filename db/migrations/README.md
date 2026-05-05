# ShopBill Pro — SQL Migrations

This folder is the source-of-truth for all Supabase schema changes. Every SQL change to the production database should go through a numbered file here, in the order it was deployed.

## Deploy order

Migrations must be applied to a fresh database in the exact order below:

| # | File | What it does | Date deployed |
|---|---|---|---|
| 1 | `audit_round_db_patch.sql` | Atomic invoice counter, plan expiry trigger, schema additions | Apr 2026 |
| 2 | `admin_panel_full.sql` | 10 admin RPCs, encrypted settings (pgcrypto), admin master token, Razorpay webhook handler | Apr 2026 |
| 3 | `003_categories.sql` | 12 macros + 80+ business types + 18 module profiles | May 4, 2026 (Batch 1A) |
| 4 | `004_seo.sql` | Admin-driven SEO panel: global settings, per-page SEO, blog CMS, redirects | May 4, 2026 (Batch 1A) |
| 5 | `005_beta.sql` | 60-day Business beta + 7-day grace + auto-downgrade | May 4, 2026 (Batch 1A) |
| 6 | `006_admin_hotfix.sql` | **MISSING** — admin settings hotfix deployed inline | May 4, 2026 |
| 7 | `007_pricing_fix.sql` | **MISSING** — pricing fix ₹199 → ₹499 deployed inline | May 4, 2026 (Batch 1B-B) |
| 8 | `008_public_shop_page.sql` | ✅ HERE — Public Shop Page table + smart slugs + RPCs + RLS + backfill | May 5, 2026 (Batch PSP-MVP) |

### Missing files (006, 007)

These were deployed as inline SQL in Supabase Editor without saving copies. They are already applied to production. If you have copies in your Supabase migration history (Supabase Dashboard → Database → Migrations), download them and add to this folder for completeness.

If not, no immediate action needed — the production database is correct, this is just version-control housekeeping.

## Idempotency rule

Every migration in this folder must be **idempotent** — safe to re-run multiple times without errors. Patterns we use:

- `CREATE TABLE IF NOT EXISTS`
- `INSERT ... ON CONFLICT DO NOTHING`
- `CREATE OR REPLACE FUNCTION`
- `DROP TRIGGER IF EXISTS` then `CREATE TRIGGER`
- `DROP POLICY IF EXISTS` then `CREATE POLICY`
- `CREATE INDEX IF NOT EXISTS`

This means if a migration fails partway through, you can safely re-run it from the top.

## How to add a new migration

1. Pick the next sequential number (next will be `009_...sql`)
2. Use a descriptive name: `009_short_description.sql`
3. Add a header block at the top:
   ```sql
   -- ════════════════════════════════════════════════════════════════════
   -- 009_short_description.sql
   -- One-line description of what this does
   --
   -- Master Plan reference: Section X.Y
   -- Deploy after: 008_public_shop_page.sql
   -- IDEMPOTENT — safe to re-run.
   -- ════════════════════════════════════════════════════════════════════
   ```
4. End with verification queries as commented-out SQL the user can run after deploy
5. Save here BEFORE running in Supabase
6. Update the table at top of this README with the new entry
7. Commit + push to GitHub before running in Supabase Editor

## Recovery / rollback

Most migrations include a rollback section at the bottom (commented out). If a migration causes issues:

1. First try re-running the migration — idempotency means it might fix itself
2. If that fails, check the migration file for a `-- ROLLBACK:` section and run those statements
3. Last resort: restore from Supabase daily backup (Pro plan only)

## Backfills

Some migrations include `DO $$ ... END $$` blocks that backfill existing data. These run as part of the migration but only INSERT rows that don't exist (`ON CONFLICT DO NOTHING`). Safe to re-run.

Example: `008_public_shop_page.sql` backfills website rows for shops that signed up before the migration was deployed.
