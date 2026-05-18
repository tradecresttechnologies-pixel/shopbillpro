-- ════════════════════════════════════════════════════════════════════
-- 078_fix_restaurant_reports_registration.sql
-- ════════════════════════════════════════════════════════════════════
-- DIAGNOSIS (proven from live DB, not assumed)
--   get_shop_modules resolves: shops.shop_type → sbp_business_categories
--   .module_profile → profile, then returns sbp_module_profiles rows
--   for that profile.
--   Live query result for this shop:
--     shop_type             = 'restaurant'
--     resolved_profile      = 'restaurant'
--     tables  registered for= 'food, restaurant'   (← why Tables shows)
--     rr      registered for=  NULL                 (← why RR is hidden)
--   => restaurant_reports has NO sbp_module_profiles row for ANY
--      profile. Migration 075 was not applied. This migration makes
--      the registration self-correcting and idempotent so it cannot
--      be missed again.
--
-- FIX
--   Register restaurant_reports for the SAME profile the working
--   restaurant modules ('tables','kitchen','qr_menu') already use —
--   derived dynamically from the data, so it is correct regardless of
--   which profile name this install uses (here: 'restaurant' AND
--   'food', both present for tables). Plus the explicit known set as a
--   safety net. Idempotent via ON CONFLICT.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- 1. Mirror restaurant_reports onto every profile that already has the
--    'tables' module (i.e. wherever the restaurant vertical is live).
--    This is data-derived → always matches this install's real profile.
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order)
SELECT DISTINCT mp.profile, 'restaurant_reports', 'active', 'NEW', 30
FROM sbp_module_profiles mp
WHERE mp.module_code = 'tables'
ON CONFLICT (profile, module_code) DO UPDATE SET
  status        = 'active',
  badge         = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- 2. Explicit safety net for the full known food + hotel profile set
--    (covers installs where 'tables' might be registered differently).
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
  status        = 'active',
  badge         = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- VERIFY (must return at least the 'restaurant' row as active):
-- SELECT profile, module_code, status, display_order
-- FROM sbp_module_profiles
-- WHERE module_code = 'restaurant_reports'
-- ORDER BY profile;
