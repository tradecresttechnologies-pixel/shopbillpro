-- ════════════════════════════════════════════════════════════════════
-- 012_module_status_updates.sql
-- Batch 012 — Bug fix sprint (6 May 2026)
--
-- Two strategic updates to sbp_module_profiles:
--
-- 1. LOYALTY STATUS FLIP: Loyalty module shipped 5 May 2026 (Batch 009).
--    The DB seed in 003_business_categories.sql still has it as 'soon'
--    for the kirana profile. Flip to 'active' with NEW badge across all
--    retail-style profiles where loyalty makes sense.
--
-- 2. WEBSITE EVERYWHERE (locked decision 3, 6 May 2026):
--    "All business will have website" — even tea stalls, pan shops,
--    minimal-profile shops. Update sbp_module_profiles to ensure
--    every profile (including 'minimal') has the website module active.
--    Strategic shift: ShopBill Pro = "every Indian shop deserves a
--    digital presence."
--
-- IDEMPOTENT — safe to re-run.
-- Prerequisites: 003_business_categories.sql must have run.
-- ════════════════════════════════════════════════════════════════════


-- ── 1. LOYALTY STATUS FLIP ──────────────────────────────────────────
-- Update existing kirana row + add loyalty to other retail-leaning profiles.

UPDATE sbp_module_profiles
SET status = 'active', badge = 'NEW'
WHERE module_code = 'loyalty';

-- Add loyalty to profiles where it's a natural fit (retail + food)
-- Insert with display_order 75 (between team@70 and supplier-dependent items)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('standard',   'loyalty', 'active', 'NEW', 75),
  ('garments',   'loyalty', 'active', 'NEW', 75),
  ('jewellery',  'loyalty', 'active', 'NEW', 75),
  ('mobile',     'loyalty', 'active', 'NEW', 75),
  ('pharmacy',   'loyalty', 'active', 'NEW', 75),
  ('food',       'loyalty', 'active', 'NEW', 75),
  ('restaurant', 'loyalty', 'active', 'NEW', 75),
  ('auto',       'loyalty', 'active', 'NEW', 75),
  ('salon',      'loyalty', 'active', 'NEW', 75),
  ('healthcare', 'loyalty', 'active', 'NEW', 75),
  ('education',  'loyalty', 'active', 'NEW', 75),
  ('services',   'loyalty', 'active', 'NEW', 75)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;


-- ── 2. WEBSITE EVERYWHERE ────────────────────────────────────────────
-- Per locked decision 3 (6 May 2026): every business gets a website.
-- This INSERTs website into 'minimal' profile (currently has none) and
-- ensures every other profile has it set to 'active' with BIZ badge.

INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  -- 'minimal' profile (tea stall, pan shop) — currently has NO website
  ('minimal', 'website', 'active', 'BIZ', 5)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Sanity-update: ensure website is 'active' (not 'soon') across every
-- profile where it appears. No-op for the 18 profiles where it's already
-- correct; cleanup for any future drift.
UPDATE sbp_module_profiles
SET status = 'active', badge = 'BIZ'
WHERE module_code = 'website';


-- ── Verification ─────────────────────────────────────────────────────
-- After running, paste these into Supabase SQL Editor to confirm:

-- Loyalty status — should show 'active' across 13 profiles, no 'soon':
--   SELECT profile, status, badge FROM sbp_module_profiles
--   WHERE module_code='loyalty' ORDER BY profile;

-- Website everywhere — should appear in EVERY profile, all 'active':
--   SELECT profile, status, badge FROM sbp_module_profiles
--   WHERE module_code='website' ORDER BY profile;
--   -- Expected: 19 rows (one per profile), all status='active', badge='BIZ'

-- Profile count:
--   SELECT count(DISTINCT profile) FROM sbp_module_profiles;
--   -- Expected: 19


-- ════════════════════════════════════════════════════════════════════
-- DONE — Migration 012 complete.
-- ════════════════════════════════════════════════════════════════════
