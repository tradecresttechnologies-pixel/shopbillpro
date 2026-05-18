-- ════════════════════════════════════════════════════════════════════
-- 073_guest_order_mark_modified.sql
-- ════════════════════════════════════════════════════════════════════
-- PROBLEM
--   The "Modify" button (running-order.html → modifyGuestOrder) loads
--   the guest's items into the staff round for editing, then calls
--   sbp_guest_order_reject() purely to remove the order from the
--   pending queue. Side effect: the guest order is permanently marked
--   status='rejected' even though it was NOT refused — staff accepted
--   it and is editing it. This corrupted every report (all test orders
--   showed 'rejected') and is the documented-but-never-finished
--   "future: dedicated modified status" hack.
--
-- DESIGN DECISION
--   The status CHECK is ('pending','accepted','rejected','expired') —
--   adding a 5th value means a constraint migration plus handling it
--   in every consumer. Not worth it. Semantically, a modified order
--   WAS accepted (staff took it, just edited it before sending KOT).
--   So Modify should mark it 'accepted' — same as Accept — but WITHOUT
--   firing a KOT (staff sends the KOT manually after editing the
--   round). accepted_kot_no stays NULL to signal "accepted via modify,
--   KOT sent manually". rejected_* stays clean.
--
-- FIX
--   New RPC sbp_guest_order_mark_modified(shop_id, guest_order_id):
--     • same auth gate + pending guard as accept/reject
--     • status → 'accepted', accepted_at = now(),
--       accepted_kot_no = NULL, accepted_by_name = staff label,
--       running_order_id left NULL (items live in the staff round,
--       not yet committed to a running order — they will be on Send KOT)
--     • self-contained, exception-safe envelope (same pattern as 072)
--   running-order.html is repointed from sbp_guest_order_reject →
--   sbp_guest_order_mark_modified for the Modify action only. Reject
--   (Send Waiter) is unchanged and still legitimately rejects.
--
-- REPORTING IMPACT
--   After this, guest-order reports can correctly distinguish:
--     accepted + accepted_kot_no NOT NULL  → accepted directly
--     accepted + accepted_kot_no IS NULL   → accepted via Modify
--     rejected                             → genuinely refused
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_guest_order_mark_modified(uuid, uuid);

CREATE OR REPLACE FUNCTION sbp_guest_order_mark_modified(
  p_shop_id        uuid,
  p_guest_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_go    sbp_guest_orders%ROWTYPE;
  v_actor text := 'staff';
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_go
  FROM sbp_guest_orders
  WHERE id = p_guest_order_id AND shop_id = p_shop_id
  FOR UPDATE;

  IF v_go.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_go.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_handled');
  END IF;

  -- Staff display label (same correct lookup as 072; exception-safe)
  BEGIN
    SELECT user_name INTO v_actor
    FROM sbp_authorized_users
    WHERE shop_id = p_shop_id
      AND created_by = auth.uid()
      AND active = true
    LIMIT 1;
    IF v_actor IS NULL OR length(trim(v_actor)) = 0 THEN
      v_actor := 'staff';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_actor := 'staff';
  END;

  -- Accepted (staff took it & is editing) — NO KOT fired here.
  -- accepted_kot_no NULL = "accepted via Modify, KOT sent manually".
  UPDATE sbp_guest_orders
     SET status           = 'accepted',
         accepted_at      = now(),
         accepted_kot_no  = NULL,
         accepted_by_name = v_actor
   WHERE id = p_guest_order_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'guest_order_id', p_guest_order_id,
    'mode',           'modified',
    'accepted_by',    v_actor
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'ok',     false,
    'error',  'exception',
    'detail', jsonb_build_object(
                'sqlstate', SQLSTATE,
                'message',  SQLERRM
              )
  );
END;
$$;

REVOKE ALL ON FUNCTION sbp_guest_order_mark_modified(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_order_mark_modified(uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
