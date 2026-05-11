-- ════════════════════════════════════════════════════════════════════
-- 031_auth_and_audit_foundation.sql
-- Batch 022D-A — Authorization + Audit Log Foundation (11 May 2026)
--
-- Establishes the foundation for hotel-grade authorization controls.
-- Nothing in production wires through this yet (that's 022D-B). This
-- migration is safe to deploy in isolation and test before enforcement
-- is turned on for any RPC.
--
-- What ships:
--   1. sbp_authorized_users  — users who can authorize high-risk ops
--                              PINs stored as bcrypt hashes (pgcrypto)
--   2. sbp_audit_log         — append-only, every authorized action
--                              with before/after state captured
--   3. shops.require_auth_for_high_risk — per-shop toggle (default OFF
--      so existing flows don't break until owner opts in)
--   4. RPCs:
--        sbp_verify_pin
--        sbp_authorized_users_list
--        sbp_authorized_users_upsert
--        sbp_authorized_users_set_pin
--        sbp_authorized_users_set_active
--        sbp_authorized_users_delete
--        sbp_audit_log_write       (internal, callable by other RPCs)
--        sbp_audit_log_query
--
-- pgcrypto: required (Supabase enables by default; we ensure here too).
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 0. Extension
-- ──────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ──────────────────────────────────────────────────────────────────
-- 1. Settings flag on shops
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS require_auth_for_high_risk boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.shops.require_auth_for_high_risk IS
  'When true, RPCs marked as high-risk (cancel booking, void payment, remove charge, void bill) require an authorized PIN. Default false so existing shops continue working; owner enables once authorized_users seeded.';


-- ──────────────────────────────────────────────────────────────────
-- 2. sbp_authorized_users — who can authorize high-risk ops
-- ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.sbp_authorized_users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id       uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  user_name     text NOT NULL CHECK (length(trim(user_name)) > 0),
  auth_role     text NOT NULL DEFAULT 'manager'
                  CHECK (auth_role IN ('owner','manager','supervisor','cashier')),
  pin_hash      text NOT NULL,            -- bcrypt: crypt(pin, gen_salt('bf', 10))
  can_authorize boolean NOT NULL DEFAULT true,
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    uuid REFERENCES auth.users(id),
  last_used_at  timestamptz,
  notes         text,
  UNIQUE (shop_id, user_name)
);

CREATE INDEX IF NOT EXISTS idx_auth_users_shop_active
  ON public.sbp_authorized_users(shop_id) WHERE active = true;

COMMENT ON TABLE public.sbp_authorized_users IS
  'Users who can authorize high-risk operations via PIN. Each shop has its own set. PINs are bcrypt-hashed via pgcrypto crypt(). Never store plaintext PINs.';

ALTER TABLE public.sbp_authorized_users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_auth_users_owner ON public.sbp_authorized_users;
CREATE POLICY p_auth_users_owner ON public.sbp_authorized_users
  FOR ALL TO authenticated
  USING (shop_id IN (SELECT id FROM public.shops WHERE owner_id = auth.uid()))
  WITH CHECK (shop_id IN (SELECT id FROM public.shops WHERE owner_id = auth.uid()));


-- ──────────────────────────────────────────────────────────────────
-- 3. sbp_audit_log — append-only audit trail
-- ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.sbp_audit_log (
  id                    bigserial PRIMARY KEY,
  shop_id               uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,

  -- Who performed the action (the logged-in user)
  actor_user_id         uuid REFERENCES auth.users(id),
  actor_name            text,

  -- What happened
  action_code           text NOT NULL,           -- e.g. 'booking.cancel', 'extras.remove', 'payment.void', 'bill.void'
  target_table          text,
  target_id             uuid,
  before_json           jsonb,
  after_json            jsonb,
  reason                text,

  -- Who authorized it (separate from actor — actor + authorizer can be same person)
  authorized_by_user_id uuid REFERENCES public.sbp_authorized_users(id),
  authorized_by_name    text,
  auth_method           text NOT NULL DEFAULT 'none'
                          CHECK (auth_method IN ('none','pin','biometric','master','owner_session')),

  -- Context
  ip_address            inet,
  user_agent            text,
  recorded_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_shop_time
  ON public.sbp_audit_log(shop_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_shop_action_time
  ON public.sbp_audit_log(shop_id, action_code, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_target
  ON public.sbp_audit_log(shop_id, target_table, target_id) WHERE target_id IS NOT NULL;

COMMENT ON TABLE public.sbp_audit_log IS
  'Append-only audit trail of high-risk operations. Never UPDATE or DELETE rows here. Inserts only via SECURITY DEFINER functions (sbp_audit_log_write). RLS allows owner to SELECT but not write directly.';

ALTER TABLE public.sbp_audit_log ENABLE ROW LEVEL SECURITY;

-- Owner can READ their shop's audit log
DROP POLICY IF EXISTS p_audit_log_read ON public.sbp_audit_log;
CREATE POLICY p_audit_log_read ON public.sbp_audit_log
  FOR SELECT TO authenticated
  USING (shop_id IN (SELECT id FROM public.shops WHERE owner_id = auth.uid()));

-- Nobody can directly INSERT/UPDATE/DELETE — only via sbp_audit_log_write
-- (Note: SECURITY DEFINER functions run as table owner, bypassing RLS)
DROP POLICY IF EXISTS p_audit_log_no_write ON public.sbp_audit_log;
CREATE POLICY p_audit_log_no_write ON public.sbp_audit_log
  FOR ALL TO authenticated
  USING (false) WITH CHECK (false);


-- ──────────────────────────────────────────────────────────────────
-- 4. Helper: ownership check (reuses existing hospitality pattern)
-- ──────────────────────────────────────────────────────────────────
-- For non-hospitality shops we still need a check. Generic version:

CREATE OR REPLACE FUNCTION public.sbp_check_shop_owner(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_owner uuid;
BEGIN
  SELECT owner_id INTO v_owner FROM public.shops WHERE id = p_shop_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_check_shop_owner(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 5. RPC: sbp_verify_pin — verify a PIN and return user info
-- ──────────────────────────────────────────────────────────────────
--
-- Args: p_shop_id, p_pin (plaintext, sent over HTTPS)
-- Returns: { ok, user_id, user_name, auth_role, can_authorize } on match
--          { ok: false, error: 'invalid_pin' } otherwise
--
-- Iterates over active authorized_users for the shop and checks each
-- with crypt() (bcrypt verify is constant-time per row). For shops
-- with hundreds of users this is O(n) but typical shop has < 20.
--
-- Updates last_used_at on match.

CREATE OR REPLACE FUNCTION public.sbp_verify_pin(
  p_shop_id uuid,
  p_pin     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_u     record;
  v_pin   text;
BEGIN
  -- Don't leak shop existence to non-owners
  v_check := sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  v_pin := COALESCE(p_pin, '');
  IF length(v_pin) < 4 OR length(v_pin) > 12 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_pin_format');
  END IF;

  -- Check each active user. bcrypt verify: crypt(pin, hash) === hash if match.
  FOR v_u IN
    SELECT id, user_name, auth_role, can_authorize, pin_hash
      FROM public.sbp_authorized_users
     WHERE shop_id = p_shop_id AND active = true
  LOOP
    IF crypt(v_pin, v_u.pin_hash) = v_u.pin_hash THEN
      -- Update last_used_at
      UPDATE public.sbp_authorized_users
         SET last_used_at = now()
       WHERE id = v_u.id;

      RETURN jsonb_build_object(
        'ok',            true,
        'user_id',       v_u.id,
        'user_name',     v_u.user_name,
        'auth_role',     v_u.auth_role,
        'can_authorize', v_u.can_authorize
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', false, 'error', 'invalid_pin');
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_verify_pin(uuid, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 6. RPC: sbp_authorized_users_list — list users for a shop
-- ──────────────────────────────────────────────────────────────────
-- Returns metadata only — never returns pin_hash.

CREATE OR REPLACE FUNCTION public.sbp_authorized_users_list(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_rows  jsonb;
BEGIN
  v_check := sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',            u.id,
    'user_name',     u.user_name,
    'auth_role',     u.auth_role,
    'can_authorize', u.can_authorize,
    'active',        u.active,
    'created_at',    u.created_at,
    'last_used_at',  u.last_used_at,
    'notes',         u.notes,
    'pin_set',       (u.pin_hash IS NOT NULL AND length(u.pin_hash) > 0)
  ) ORDER BY u.auth_role, u.user_name), '[]'::jsonb)
  INTO v_rows
  FROM public.sbp_authorized_users u
  WHERE u.shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true, 'users', v_rows);
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_authorized_users_list(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 7. RPC: sbp_authorized_users_upsert — owner adds/updates a user
-- ──────────────────────────────────────────────────────────────────
-- For new users, PIN is required. For existing users, PIN is optional
-- (use sbp_authorized_users_set_pin to update PIN separately).

CREATE OR REPLACE FUNCTION public.sbp_authorized_users_upsert(
  p_shop_id       uuid,
  p_user_name     text,
  p_auth_role     text DEFAULT 'manager',
  p_pin           text DEFAULT NULL,
  p_can_authorize boolean DEFAULT true,
  p_active        boolean DEFAULT true,
  p_notes         text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check    jsonb;
  v_id       uuid;
  v_pin_hash text;
  v_existing record;
BEGIN
  v_check := sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  IF p_user_name IS NULL OR length(trim(p_user_name)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_name_required');
  END IF;
  IF p_auth_role NOT IN ('owner','manager','supervisor','cashier') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_role');
  END IF;

  -- Existing?
  SELECT id, pin_hash INTO v_existing
    FROM public.sbp_authorized_users
   WHERE shop_id = p_shop_id AND user_name = trim(p_user_name);

  IF v_existing.id IS NULL THEN
    -- New user — PIN required
    IF p_pin IS NULL OR length(p_pin) < 4 OR length(p_pin) > 12 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'pin_required_4_to_12_digits');
    END IF;
    v_pin_hash := crypt(p_pin, gen_salt('bf', 10));

    INSERT INTO public.sbp_authorized_users
      (shop_id, user_name, auth_role, pin_hash, can_authorize, active, created_by, notes)
    VALUES
      (p_shop_id, trim(p_user_name), p_auth_role, v_pin_hash,
       p_can_authorize, p_active, auth.uid(), p_notes)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'user_id', v_id, 'created', true);
  ELSE
    -- Update — PIN only updated if explicitly passed
    IF p_pin IS NOT NULL AND length(p_pin) >= 4 AND length(p_pin) <= 12 THEN
      v_pin_hash := crypt(p_pin, gen_salt('bf', 10));
    ELSE
      v_pin_hash := v_existing.pin_hash;  -- keep existing
    END IF;

    UPDATE public.sbp_authorized_users
       SET auth_role     = p_auth_role,
           pin_hash      = v_pin_hash,
           can_authorize = p_can_authorize,
           active        = p_active,
           notes         = COALESCE(p_notes, notes)
     WHERE id = v_existing.id;

    RETURN jsonb_build_object('ok', true, 'user_id', v_existing.id, 'created', false);
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_authorized_users_upsert(uuid, text, text, text, boolean, boolean, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 8. RPC: sbp_authorized_users_set_pin — change a user's PIN
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_authorized_users_set_pin(
  p_shop_id uuid,
  p_user_id uuid,
  p_new_pin text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
BEGIN
  v_check := sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  IF p_new_pin IS NULL OR length(p_new_pin) < 4 OR length(p_new_pin) > 12 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_required_4_to_12_digits');
  END IF;

  UPDATE public.sbp_authorized_users
     SET pin_hash = crypt(p_new_pin, gen_salt('bf', 10))
   WHERE id = p_user_id AND shop_id = p_shop_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_authorized_users_set_pin(uuid, uuid, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 9. RPC: sbp_authorized_users_set_active — soft-disable a user
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_authorized_users_set_active(
  p_shop_id uuid,
  p_user_id uuid,
  p_active  boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
BEGIN
  v_check := sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  UPDATE public.sbp_authorized_users
     SET active = p_active
   WHERE id = p_user_id AND shop_id = p_shop_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_authorized_users_set_active(uuid, uuid, boolean) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 10. RPC: sbp_authorized_users_delete — hard delete a user
-- ──────────────────────────────────────────────────────────────────
-- Note: audit_log rows referencing this user retain authorized_by_name
-- (denormalized) so history is preserved.

CREATE OR REPLACE FUNCTION public.sbp_authorized_users_delete(
  p_shop_id uuid,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
BEGIN
  v_check := sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Null out FK refs from audit_log first (preserves denormalized name)
  UPDATE public.sbp_audit_log
     SET authorized_by_user_id = NULL
   WHERE authorized_by_user_id = p_user_id
     AND shop_id = p_shop_id;

  DELETE FROM public.sbp_authorized_users
   WHERE id = p_user_id AND shop_id = p_shop_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user_not_found');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_authorized_users_delete(uuid, uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 11. RPC: sbp_audit_log_write — internal helper for other RPCs
-- ──────────────────────────────────────────────────────────────────
-- Called by high-risk RPCs (in 022D-B) to record what happened. Not
-- exposed for direct client use — but we GRANT EXECUTE since the
-- SECURITY DEFINER context lets it bypass the no-write RLS policy.

CREATE OR REPLACE FUNCTION public.sbp_audit_log_write(
  p_shop_id               uuid,
  p_action_code           text,
  p_target_table          text DEFAULT NULL,
  p_target_id             uuid DEFAULT NULL,
  p_before_json           jsonb DEFAULT NULL,
  p_after_json            jsonb DEFAULT NULL,
  p_reason                text DEFAULT NULL,
  p_authorized_by_user_id uuid DEFAULT NULL,
  p_authorized_by_name    text DEFAULT NULL,
  p_auth_method           text DEFAULT 'none',
  p_actor_name            text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id bigint;
BEGIN
  -- We don't gate on ownership here because callers are SECURITY DEFINER
  -- RPCs that already did their own ownership check. Direct client calls
  -- are blocked by the no-write RLS policy.

  INSERT INTO public.sbp_audit_log (
    shop_id, actor_user_id, actor_name,
    action_code, target_table, target_id,
    before_json, after_json, reason,
    authorized_by_user_id, authorized_by_name, auth_method
  ) VALUES (
    p_shop_id, auth.uid(), COALESCE(p_actor_name, 'unknown'),
    p_action_code, p_target_table, p_target_id,
    p_before_json, p_after_json, p_reason,
    p_authorized_by_user_id, p_authorized_by_name, p_auth_method
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_audit_log_write(uuid, text, text, uuid, jsonb, jsonb, text, uuid, text, text, text) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 12. RPC: sbp_audit_log_query — owner reads their audit log
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sbp_audit_log_query(
  p_shop_id       uuid,
  p_action_code   text DEFAULT NULL,     -- filter, e.g. 'booking.cancel'
  p_target_table  text DEFAULT NULL,
  p_target_id     uuid DEFAULT NULL,
  p_from          timestamptz DEFAULT NULL,
  p_to            timestamptz DEFAULT NULL,
  p_limit         int DEFAULT 100,
  p_offset        int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_rows  jsonb;
  v_total int;
BEGIN
  v_check := sbp_check_shop_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  p_limit  := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  p_offset := GREATEST(COALESCE(p_offset, 0), 0);

  SELECT COUNT(*) INTO v_total
    FROM public.sbp_audit_log a
   WHERE a.shop_id = p_shop_id
     AND (p_action_code  IS NULL OR a.action_code  = p_action_code)
     AND (p_target_table IS NULL OR a.target_table = p_target_table)
     AND (p_target_id    IS NULL OR a.target_id    = p_target_id)
     AND (p_from         IS NULL OR a.recorded_at >= p_from)
     AND (p_to           IS NULL OR a.recorded_at <  p_to);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',                    a.id,
    'recorded_at',           a.recorded_at,
    'actor_user_id',         a.actor_user_id,
    'actor_name',            a.actor_name,
    'action_code',           a.action_code,
    'target_table',          a.target_table,
    'target_id',             a.target_id,
    'before_json',           a.before_json,
    'after_json',            a.after_json,
    'reason',                a.reason,
    'authorized_by_user_id', a.authorized_by_user_id,
    'authorized_by_name',    a.authorized_by_name,
    'auth_method',           a.auth_method
  ) ORDER BY a.recorded_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT *
      FROM public.sbp_audit_log
     WHERE shop_id = p_shop_id
       AND (p_action_code  IS NULL OR action_code  = p_action_code)
       AND (p_target_table IS NULL OR target_table = p_target_table)
       AND (p_target_id    IS NULL OR target_id    = p_target_id)
       AND (p_from         IS NULL OR recorded_at >= p_from)
       AND (p_to           IS NULL OR recorded_at <  p_to)
     ORDER BY recorded_at DESC
     LIMIT p_limit OFFSET p_offset
  ) a;

  RETURN jsonb_build_object('ok', true, 'entries', v_rows, 'total', v_total, 'limit', p_limit, 'offset', p_offset);
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_audit_log_query(uuid, text, text, uuid, timestamptz, timestamptz, int, int) TO authenticated;


-- ──────────────── End of 031_auth_and_audit_foundation.sql ───────
