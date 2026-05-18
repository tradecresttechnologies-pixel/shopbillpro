-- ════════════════════════════════════════════════════════════════════
-- 072_guest_accept_actor_fix.sql
-- ════════════════════════════════════════════════════════════════════
-- ROOT CAUSE (finally captured from the live app console):
--   sbp_guest_order_accept threw  {"sqlstate":"42703",
--   "message":"column \"name\" does not exist"}.  071's exception
--   wrapper turned that into {ok:false,error:'exception'} → accept
--   failed every time. NOT auth, NOT nested RPCs — a single bad column
--   reference in the cosmetic "who accepted this" lookup:
--
--     v_actor := COALESCE(
--       (SELECT name FROM sbp_authorized_users
--          WHERE shop_id = p_shop_id AND user_id = auth.uid() ...),
--       (SELECT name FROM shops WHERE id = p_shop_id ...),
--       'staff');
--
--   Verified against the schema:
--     • sbp_authorized_users  → column is  user_name  (NOT name);
--       it has  created_by  (NOT user_id).
--     • shops  → predates migrations; no  name  column. Every WORKING
--       rpc only ever touches shops via owner_id, never SELECT name.
--   So two of the three COALESCE branches reference columns that do
--   not exist → 42703 at first row fetch → whole accept aborts.
--
-- FIX
--   Recreate sbp_guest_order_accept identical to 071 EXCEPT the actor
--   block, which is now:
--     • a self-contained sub-block with its own EXCEPTION handler, so
--       a label lookup can never again abort the accept;
--     • uses the correct column  user_name  and the correct key
--       created_by = auth.uid()  on sbp_authorized_users;
--     • drops the invalid  SELECT name FROM shops  branch entirely;
--     • defaults to 'staff' on any miss/error.
--   accepted_by_name is a display label only — correctness of the KOT
--   and the running order does not depend on it, so degrading it
--   gracefully is correct.
--
-- Everything else in 071 (inline RO open, inline KOT append, KDS
-- mirror, outer exception envelope) is preserved byte-for-byte.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_guest_order_accept(uuid, uuid);

CREATE OR REPLACE FUNCTION sbp_guest_order_accept(
  p_shop_id        uuid,
  p_guest_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_go       sbp_guest_orders%ROWTYPE;
  v_table    sbp_restaurant_tables%ROWTYPE;
  v_ro       sbp_running_orders%ROWTYPE;
  v_ro_id    uuid;
  v_kot_n    int;
  v_stamped  jsonb;
  v_new_kot  jsonb;
  v_actor    text := 'staff';
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

  SELECT * INTO v_table
  FROM sbp_restaurant_tables
  WHERE shop_id = p_shop_id
    AND table_number = v_go.table_number
    AND active = true;

  IF v_table.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'table_gone');
  END IF;

  -- ── Inline running-order resolve / open (no sbp_ro_open dep) ──────
  SELECT * INTO v_ro
  FROM sbp_running_orders
  WHERE shop_id = p_shop_id AND table_id = v_table.id AND status = 'open'
  ORDER BY opened_at DESC
  LIMIT 1;

  IF v_ro.id IS NULL THEN
    INSERT INTO sbp_running_orders (shop_id, table_id, table_number)
    VALUES (p_shop_id, v_table.id, v_table.table_number)
    RETURNING * INTO v_ro;

    UPDATE sbp_restaurant_tables
       SET status = 'occupied', updated_at = now()
     WHERE id = v_table.id AND shop_id = p_shop_id;
  END IF;
  v_ro_id := v_ro.id;

  -- ── Inline KOT round append (replicates 067 sbp_ro_add_items) ─────
  v_kot_n := COALESCE(v_ro.kot_count, 0) + 1;

  SELECT jsonb_agg(
           item
           || jsonb_build_object('round',   v_kot_n)
           || jsonb_build_object('item_id', gen_random_uuid())
           || jsonb_build_object('voided',  false)
         )
  INTO v_stamped
  FROM jsonb_array_elements(COALESCE(v_go.items, '[]'::jsonb)) AS item;

  IF v_stamped IS NULL OR jsonb_array_length(v_stamped) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_items');
  END IF;

  v_new_kot := jsonb_build_object(
    'round',      v_kot_n,
    'items',      v_stamped,
    'notes',      v_go.notes,
    'sent_at',    to_char(now() AT TIME ZONE 'Asia/Kolkata', 'HH24:MI'),
    'kot_number', v_kot_n
  );

  UPDATE sbp_running_orders
     SET items      = COALESCE(items, '[]'::jsonb) || v_stamped,
         kots       = COALESCE(kots,  '[]'::jsonb) || jsonb_build_array(v_new_kot),
         kot_count  = v_kot_n,
         notes      = COALESCE(v_go.notes, notes),
         updated_at = now()
   WHERE id = v_ro_id AND shop_id = p_shop_id;

  -- ── KDS mirror (best-effort; never fail the accept over this) ─────
  BEGIN
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_name = 'sbp_restaurant_orders'
    ) THEN
      INSERT INTO sbp_restaurant_orders (
        shop_id, table_number, table_id, items,
        status, source, notes, kot_number
      ) VALUES (
        p_shop_id, v_table.table_number, v_table.id, v_stamped,
        'pending', 'qr', v_go.notes, v_kot_n
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- ── Who accepted? (DISPLAY LABEL ONLY) ───────────────────────────
  -- Self-contained + exception-safe: a label lookup must never abort
  -- the accept. Correct column is sbp_authorized_users.user_name,
  -- correct key is created_by = auth.uid(). The old shops.name branch
  -- was invalid (no such column) and is removed.
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

  UPDATE sbp_guest_orders
     SET status           = 'accepted',
         accepted_at      = now(),
         accepted_kot_no  = v_kot_n,
         accepted_by_name = v_actor,
         running_order_id = v_ro_id
   WHERE id = p_guest_order_id;

  RETURN jsonb_build_object(
    'ok',               true,
    'guest_order_id',   p_guest_order_id,
    'running_order_id', v_ro_id,
    'kot_number',       v_kot_n,
    'accepted_by',      v_actor
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

REVOKE ALL ON FUNCTION sbp_guest_order_accept(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_order_accept(uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
