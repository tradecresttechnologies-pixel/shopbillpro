-- ════════════════════════════════════════════════════════════════════
-- 064_activate_restaurant_modules.sql
--
-- Restaurant Phase 1-4 is complete. Update module_profiles so
-- Tables, Kitchen, QR Menu show as ACTIVE (not SOON) in the sidebar
-- for all food/restaurant shop types.
--
-- Also activates for cafe, qsr, cloud_kitchen, bar_lounge, dhaba
-- verticals which share the food macro.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── Activate Tables + Kitchen + QR Menu for all food verticals ───

-- restaurant vertical
UPDATE sbp_module_profiles
SET status = 'active', badge = NULL
WHERE shop_type IN ('restaurant','cafe','qsr','cloud_kitchen','bar_lounge',
                    'dhaba','food_other','tiffin','catering','ice_cream')
  AND module_code IN ('tables','kitchen','qr_menu');

-- food macro generic rows
UPDATE sbp_module_profiles
SET status = 'active', badge = NULL
WHERE shop_type = 'food'
  AND module_code IN ('tables','kitchen','qr_menu');

-- online_orders stays SOON (Phase 4+ aggregator integration not built)
-- If it exists and is 'soon', leave it.

-- Verify
-- SELECT shop_type, module_code, status, badge
-- FROM sbp_module_profiles
-- WHERE module_code IN ('tables','kitchen','qr_menu')
-- ORDER BY shop_type, module_code;

NOTIFY pgrst, 'reload schema';
COMMIT;
