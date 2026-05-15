-- ════════════════════════════════════════════════════════════════════
-- 061_pin_multiuser_fix.sql
--
-- PROBLEM
-- ═══════
-- Staff members created via team.html have their own Supabase auth
-- accounts (auth.uid() = staff UUID ≠ owner UUID). When they log in
-- and try to perform a PIN-gated action (void bill, delete bill,
-- reopen bill), the flow fails at the very first check:
--
--   sbp_verify_pin()
--     → sbp_check_shop_owner()
--         → shops.owner_id = auth.uid()   ← staff uid ≠ owner uid
--         → returns {ok:false, error:'not_owner'}
--     ← PIN never checked. Modal shows "Invalid PIN".
--
-- The same block exists in all 5 bill action RPCs (038/039) which
-- call _sbp_check_shop_owner() — also owner-only, also blocks staff.
--
-- ROOT CAUSE
-- ══════════
-- Both owner-check helpers check for owner ONLY. They were written
-- before team.html added real staff Supabase accounts.
--
-- FIX
-- ═══
-- Redefine both helpers to pass for EITHER:
--   a) The shop owner  (shops.owner_id = auth.uid())
--   b) An active staff member  (shop_users.user_id = auth.uid() AND is_active)
--
-- Because all downstream RPCs (sbp_verify_pin, sbp_bill_void,
-- sbp_bill_void_item, sbp_bill_delete, sbp_bill_delete_item,
-- sbp_bill_reopen) call one of these two helpers, this single
-- migration fixes ALL of them without touching any other file.
--
-- SECURITY NOTE
-- ═════════════
-- The check still requires a valid PIN (bcrypt, server-verified).
-- A staff member can only pass if:
--   1. Their auth.uid() is linked to the shop via shop_users
--   2. They know a valid PIN for that shop
-- This is equivalent security to the owner case. Brute-force is
-- mitigated by the 3-attempt lock in lib/auth-pin.js.
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. _sbp_check_shop_owner (boolean) ──────────────────────────────
-- Used by: sbp_bill_void_item, sbp_bill_delete_item, sbp_bill_delete,
--          sbp_bill_reopen (all from 038), sbp_bill_void (039)
-- Change:  now returns true for active staff members as well as owner

DROP FUNCTION IF EXISTS public._sbp_check_shop_owner(uuid);

CREATE OR REPLACE FUNCTION public._sbp_check_shop_owner(p_shop_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER                           -- needed to bypass shop_users RLS
SET search_path = public, extensions
AS $$
BEGIN
  -- Owner check (original behaviour, preserved)
  IF EXISTS (
    SELECT 1 FROM shops
     WHERE id = p_shop_id
       AND owner_id = auth.uid()
  ) THEN
    RETURN true;
  END IF;

  -- Staff check — active member of this shop via shop_users table
  -- (created by team.html → auth.signUp → shop_users INSERT)
  IF EXISTS (
    SELECT 1 FROM shop_users
     WHERE shop_id  = p_shop_id
       AND user_id  = auth.uid()
       AND is_active = true
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;

GRANT EXECUTE ON FUNCTION public._sbp_check_shop_owner(uuid)
  TO authenticated, service_role;


-- ── 2. sbp_check_shop_owner (jsonb) ─────────────────────────────────
-- Used by: sbp_verify_pin (and several other RPCs from 031)
-- Change:  same membership logic, returns friendly jsonb envelope

DROP FUNCTION IF EXISTS public.sbp_check_shop_owner(uuid);

CREATE OR REPLACE FUNCTION public.sbp_check_shop_owner(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  -- Delegate to the boolean helper (already handles owner + staff)
  IF public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', true);
  END IF;

  -- Distinguish "shop doesn't exist" from "not a member"
  IF NOT EXISTS (SELECT 1 FROM shops WHERE id = p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_check_shop_owner(uuid)
  TO authenticated, service_role;


-- ── 3. Update sbp_authorized_users RLS ──────────────────────────────
-- Current policy only allows shop owners to read/write this table.
-- Staff need READ access to their own shop's PIN records so the PIN
-- modal can show the list of authorized users (if applicable).
-- They should NOT be able to create/delete/update PIN users —
-- only the owner can manage the PIN roster.

DROP POLICY IF EXISTS p_auth_users_owner  ON public.sbp_authorized_users;
DROP POLICY IF EXISTS p_auth_users_read   ON public.sbp_authorized_users;
DROP POLICY IF EXISTS p_auth_users_write  ON public.sbp_authorized_users;

-- Read: owner + active staff
CREATE POLICY p_auth_users_read ON public.sbp_authorized_users
  FOR SELECT TO authenticated
  USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
    OR
    shop_id IN (SELECT shop_id FROM shop_users WHERE user_id = auth.uid() AND is_active = true)
  );

-- Write (INSERT/UPDATE/DELETE): owner only
CREATE POLICY p_auth_users_write ON public.sbp_authorized_users
  FOR ALL TO authenticated
  USING  (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid()));


NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- VERIFY after deploy:
--
-- 1. Check helpers exist:
--    SELECT routine_name FROM information_schema.routines
--    WHERE routine_name IN ('_sbp_check_shop_owner','sbp_check_shop_owner')
--    AND routine_schema = 'public';
--    -- Should return 2 rows
--
-- 2. Test from SQL Editor (as owner):
--    SELECT sbp_check_shop_owner('<your_shop_id>');
--    -- Should return {ok: true}
--
-- 3. Test PIN verify (as owner):
--    SELECT sbp_verify_pin('<shop_id>', '1234');
--    -- Should return {ok: true, user_name: 'owner', ...}
--
-- 4. Test from staff account:
--    (Log in as staff in app → try to void a bill → PIN modal appears
--     → enter correct PIN → should succeed instead of "Invalid PIN")
--
-- ROLLBACK if needed:
-- Run the original _sbp_check_shop_owner from migration 036 and
-- original sbp_check_shop_owner from migration 031.
-- ════════════════════════════════════════════════════════════════════
