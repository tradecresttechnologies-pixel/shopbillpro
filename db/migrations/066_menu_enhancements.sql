-- ════════════════════════════════════════════════════════════════════
-- 066_menu_enhancements.sql
-- Adds is_available to sbp_services so restaurants can 86 items
-- ("Sorry, butter chicken is finished today")
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE sbp_services ADD COLUMN IF NOT EXISTS is_available boolean NOT NULL DEFAULT true;

-- Activate 'menu' module for food verticals in sidebar
-- (uses sbp_services table, restaurant-specific menu.html UI)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order)
VALUES
  ('restaurant',    'menu', 'active', NULL, 15),
  ('cafe',          'menu', 'active', NULL, 15),
  ('qsr',           'menu', 'active', NULL, 15),
  ('cloud_kitchen', 'menu', 'active', NULL, 15),
  ('bar_lounge',    'menu', 'active', NULL, 15),
  ('dhaba',         'menu', 'active', NULL, 15),
  ('food_other',    'menu', 'active', NULL, 15),
  ('food',          'menu', 'active', NULL, 15)
ON CONFLICT (profile, module_code) DO UPDATE SET status='active', badge=NULL;

NOTIFY pgrst, 'reload schema';
COMMIT;
