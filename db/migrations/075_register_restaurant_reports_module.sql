-- ════════════════════════════════════════════════════════════════════
-- 075_register_restaurant_reports_module.sql
-- ════════════════════════════════════════════════════════════════════
-- WHY "deployed but not in sidebar"
--   The sidebar is data-driven: lib/sidebar-engine.js CATALOG entry +
--   a sbp_module_profiles row per profile decide visibility. 074 only
--   added data-capture columns — there was no restaurant_reports
--   module registered anywhere, so nothing could appear. This migration
--   registers it (the sidebar-engine.js CATALOG entry ships alongside).
--
-- WHAT
--   Insert restaurant_reports as an ACTIVE module for every food
--   profile + the hospitality profiles (hotels with F&B benefit too).
--   Idempotent via ON CONFLICT — safe to re-run.
--
-- TIER
--   Restaurant = Business-only (locked decision). Page itself enforces
--   the Business gate client-side; server RPC (Phase B) enforces owner
--   + the report data is Business-scoped. Module shown so Business
--   users can reach it; non-Business see the standard upgrade lock on
--   the page (same pattern as tables.html).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('restaurant',    'restaurant_reports', 'active', 'NEW', 30),
  ('cafe',          'restaurant_reports', 'active', 'NEW', 30),
  ('qsr',           'restaurant_reports', 'active', 'NEW', 30),
  ('cloud_kitchen', 'restaurant_reports', 'active', 'NEW', 30),
  ('bar_lounge',    'restaurant_reports', 'active', 'NEW', 30),
  ('dhaba',         'restaurant_reports', 'active', 'NEW', 30),
  ('food_other',    'restaurant_reports', 'active', 'NEW', 30),
  ('tiffin',        'restaurant_reports', 'active', 'NEW', 30),
  ('catering',      'restaurant_reports', 'active', 'NEW', 30),
  ('ice_cream',     'restaurant_reports', 'active', 'NEW', 30),
  ('food',          'restaurant_reports', 'active', 'NEW', 30),
  ('hotel',         'restaurant_reports', 'active', 'NEW', 80),
  ('hospitality',   'restaurant_reports', 'active', 'NEW', 80),
  ('resort',        'restaurant_reports', 'active', 'NEW', 80)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status        = EXCLUDED.status,
  badge         = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Verify:
-- SELECT profile, module_code, status, display_order
-- FROM sbp_module_profiles
-- WHERE module_code = 'restaurant_reports'
-- ORDER BY profile;
