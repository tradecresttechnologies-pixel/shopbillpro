-- ════════════════════════════════════════════════════════════════════
-- 071_guest_accept_selfcontained.sql
-- ════════════════════════════════════════════════════════════════════
-- PROBLEM
--   "Accept & Send KOT" → POST sbp_guest_order_accept returns HTTP 400
--   (not 404). 404 = function missing; 400 with a body = the function
--   RUNS but raises an exception internally. The 068 version calls
--   sbp_ro_open() and sbp_ro_add_items() (Batches 065 / 067). If either
--   nested function is absent or errors on this deployment, Postgres
--   raises (e.g. 42883 undefined_function) and PostgREST returns a raw
--   400 that bypasses the clean {ok:false} envelope — so even the
--   client patch can't show a useful reason. Accept never completes,
--   so the guest order stays 'pending' and the floor notification
--   never clears.
--
-- FIX
--   Replace sbp_guest_order_accept with a SELF-CONTAINED version:
--     • Resolves / opens the running order INLINE (no sbp_ro_open dep).
--     • Appends the KOT round INLINE, replicating Batch 067's item
--       stamping exactly (round + item_id + voided:false), updates
--       items / kots / kot_count (no sbp_ro_add_items dep).
--     • Mirrors to the KDS (sbp_restaurant_orders) best-effort, in its
--       own sub-block so a KDS hiccup can never fail the accept.
--     • Wraps the whole body in EXCEPTION WHEN OTHERS → returns a clean
--       { ok:false, error:'exception', detail:{ sqlstate, message } }.
--       No more opaque 400s — the client toast (already surfaces
--       data.error + data.detail) will show the exact Postgres error
--       if anything else ever goes wrong.
--   Removing the nested-function dependency eliminates the most likely
--   root cause outright; the exception wrapper makes any residual
--   failure self-reporting instead of fatal.
--
-- SAFETY
--   • Same signature, same return shape on success — drop-in.
--   • IST KOT timestamp via Asia/Kolkata, matching 067.
--   • Idempotent guard preserved (status<>'pending' → already_handled).
--   • KDS insert mirrors 067's exact column list/semantics.
--   • Does not touch 069/070; complements them.
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
  v_actor    text;
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
    -- KDS is a downstream convenience; the order is already on the
    -- running order. Swallow and continue.
    NULL;
  END;

  -- Who accepted?
  v_actor := COALESCE(
    (SELECT name FROM sbp_authorized_users
       WHERE shop_id = p_shop_id AND user_id = auth.uid() LIMIT 1),
    (SELECT name FROM shops WHERE id = p_shop_id LIMIT 1),
    'staff'
  );

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
  -- Any unexpected runtime error → clean, self-reporting envelope
  -- instead of an opaque HTTP 400.
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

-- PostgREST schema cache reload (permanent rule)
NOTIFY pgrst, 'reload schema';
