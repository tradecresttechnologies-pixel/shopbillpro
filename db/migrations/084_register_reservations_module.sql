-- ════════════════════════════════════════════════════════════════════
-- 084_register_reservations_module.sql
-- ════════════════════════════════════════════════════════════════════
-- WHY "deployed but not in sidebar"
--   The sidebar is data-driven: lib/sidebar-engine.js CATALOG entry +
--   a sbp_module_profiles row per profile decide visibility. 083 added
--   the reservations table + RPCs, and the CATALOG entry for
--   'reservations' ships in sidebar-engine.js — but there was no
--   sbp_module_profiles row, so verticalModules never includes it and
--   nothing appears. This migration registers it.
--   (Exact same pattern as 075_register_restaurant_reports_module.sql.)
--
-- WHAT
--   Insert 'reservations' as an ACTIVE module for every food/restaurant
--   profile. Idempotent via ON CONFLICT — safe to re-run.
--
-- TIER
--   Restaurant = Business-only (locked decision, per marketing page).
--   reservations.html enforces the Business gate client-side (isBiz);
--   server RPCs in 083 enforce owner. Module is shown so Business users
--   can reach it; non-Business see the upgrade lock on the page itself
--   (same pattern as tables.html / restaurant_reports).
--
-- DEPLOY ORDER: after 083_table_reservations.sql.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('restaurant',    'reservations', 'active', 'NEW', 26),
  ('cafe',          'reservations', 'active', 'NEW', 26),
  ('qsr',           'reservations', 'active', 'NEW', 26),
  ('cloud_kitchen', 'reservations', 'active', 'NEW', 26),
  ('bar_lounge',    'reservations', 'active', 'NEW', 26),
  ('dhaba',         'reservations', 'active', 'NEW', 26),
  ('food_other',    'reservations', 'active', 'NEW', 26),
  ('tiffin',        'reservations', 'active', 'NEW', 26),
  ('catering',      'reservations', 'active', 'NEW', 26),
  ('ice_cream',     'reservations', 'active', 'NEW', 26),
  ('food',          'reservations', 'active', 'NEW', 26)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status        = EXCLUDED.status,
  badge         = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Verify:
-- SELECT profile, module_code, status, display_order
-- FROM sbp_module_profiles
-- WHERE module_code = 'reservations'
-- ORDER BY profile;
