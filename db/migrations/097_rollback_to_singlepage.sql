-- ════════════════════════════════════════════════════════════════════
-- 097_rollback_to_singlepage_v18.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   Rolls back the M2 multi-page experiment (096) and reactivates the
--   single-page architecture. Also activates the new v18 prompt which
--   adds modals + heavy motion + progressive enhancement.
--
-- DEPLOY ORDER:
--   1. Run 097 BEFORE inserting v18 (it deactivates old; v18 inserts new)
--   2. Then run 098 to insert v18
--   3. Deploy Edge Function v3.11
--   4. Deploy lib/live-site.js v5
--
-- WHY
--   AI-generated multi-page produced unreliable navigation (slug drift,
--   missing prompts per macro, modal-vs-anchor confusion). Per Vinay's
--   2026-05-22 decision, switch to one excellent single-page website
--   with full-screen modals for long lists (menu, gallery, rooms, etc).
--   Pages table infrastructure stays — may be used later for Business-tier
--   premium upsell, but is unused for now.
--
-- ROLLBACK PLAN (if v18 generates badly):
--   UPDATE ai_prompt_templates SET is_active = false WHERE name = 'website_v1' AND version = 18;
--   UPDATE ai_prompt_templates SET is_active = true  WHERE name = 'website_v1' AND version = 16;
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Deactivate the home_multipage prompt (M2 experiment) ──────────
UPDATE ai_prompt_templates
SET is_active = false
WHERE name = 'website_v1'
  AND page_slug = 'home_multipage';

-- ── 2. Deactivate per-page prompts (menu, about, gallery, contact) ──
-- These were for multi-page; not needed for single-page architecture.
-- Keep the rows (for future Business-tier multipage) but deactivate.
UPDATE ai_prompt_templates
SET is_active = false
WHERE name = 'website_v1'
  AND page_slug IN ('menu','about','gallery','contact');

-- ── 3. Deactivate ALL old home prompts (we'll activate v18 in 098) ──
UPDATE ai_prompt_templates
SET is_active = false
WHERE name = 'website_v1'
  AND (page_slug = 'home' OR page_slug IS NULL);

-- ── 4. Reset Indian Curry's quota so v18 testing isn't blocked ──────
-- Comment out before production deploy.
UPDATE sbp_shop_websites
SET ai_regenerations_used = 0
WHERE shop_id = '73aa8ede-6352-4549-8617-cccacdd5c821';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- After running this:
--   SELECT page_slug, version, is_active
--   FROM ai_prompt_templates
--   WHERE name = 'website_v1' AND is_active = true;
--   -- Expected: 0 rows (next step: run 098 to activate v18)
-- ════════════════════════════════════════════════════════════════════
