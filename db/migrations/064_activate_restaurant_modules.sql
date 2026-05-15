-- 064_activate_restaurant_modules.sql (fixed — column is 'profile' not 'shop_type')
BEGIN;

UPDATE sbp_module_profiles
SET status = 'active', badge = NULL
WHERE profile IN ('restaurant','cafe','qsr','cloud_kitchen','bar_lounge',
                  'dhaba','food_other','tiffin','catering','ice_cream','food')
  AND module_code IN ('tables','kitchen','qr_menu');

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Verify:
-- SELECT profile, module_code, status, badge
-- FROM sbp_module_profiles
-- WHERE module_code IN ('tables','kitchen','qr_menu')
-- ORDER BY profile, module_code;
