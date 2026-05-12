-- ════════════════════════════════════════════════════════════════════
-- Migration 034 — Add authorized_users + audit_log modules to every
--                 profile in sbp_module_profiles
-- Batch 022D Link Wiring
--
-- Without this migration, shops whose sidebar is driven by the cloud
-- (get_shop_modules RPC) won't see the two new menu entries even
-- though the JS catalog has them — the server-side module profile
-- list filters them out.
--
-- This migration adds 'authorized_users' (order 122) and 'audit_log'
-- (order 124) to every distinct profile that already exists in
-- sbp_module_profiles. Idempotent via ON CONFLICT DO UPDATE.
--
-- Status='active' for all profiles. No plan gating (security is
-- universal). No badge (these are stable, not new/PRO/BIZ).
--
-- Note: the server-side RPCs (sbp_authorized_users_list,
-- sbp_audit_log_query) enforce owner-only access — if a non-owner
-- somehow has the sidebar entry, they'll see an "Access denied"
-- empty state when navigating, not a broken page.
-- ════════════════════════════════════════════════════════════════════

-- Add authorized_users to every existing profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order)
SELECT DISTINCT
  profile,
  'authorized_users',
  'active',
  NULL,
  122
FROM sbp_module_profiles
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Add audit_log to every existing profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order)
SELECT DISTINCT
  profile,
  'audit_log',
  'active',
  NULL,
  124
FROM sbp_module_profiles
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Done. Both modules now visible in sidebar across every business
-- type / vertical / profile. Server-side RPCs enforce owner-only.
