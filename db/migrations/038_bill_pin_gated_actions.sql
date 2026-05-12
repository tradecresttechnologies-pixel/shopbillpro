-- ════════════════════════════════════════════════════════════════════
-- Migration 038 — Server-side PIN-gated bill actions (Batch 022D-D)
--
-- Closes the security hole in bills.html where 5 high-risk actions were
-- gated by a client-side PIN check (localStorage plaintext comparison).
-- Anyone with browser dev tools could bypass it. This migration moves
-- the gate to the server: each action verifies the PIN via the existing
-- sbp_verify_pin RPC and logs to audit_log via sbp_audit_log_write.
--
-- 5 RPCs introduced:
--   1. sbp_bill_void_item    — void a single line item (soft delete)
--   2. sbp_bill_delete_item  — permanently delete a line item
--   3. sbp_bill_delete       — permanently delete an entire bill
--   4. sbp_bill_reopen       — reopen a closed bill for editing
--   5. sbp_bill_edit_start   — verify PIN + log "edit started"
--                              (actual edit happens via billing.html save)
--
-- 1 internal helper:
--   _sbp_bill_recompute_totals(p_bill_id) — recompute subtotal/gst/total
--   from non-voided bill_items, update bills row, sync bills.items jsonb
--
-- All RPCs:
--   • Owner check via _sbp_check_shop_owner (from migration 036)
--   • PIN re-verify via existing sbp_verify_pin
--   • Audit log via existing sbp_audit_log_write
--   • {ok, error?, ...} jsonb envelope
--   • Row locks where appropriate
-- ════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════
-- Helper: recompute bill totals from non-voided bill_items
-- Also syncs bills.items jsonb so legacy `select('*')` callers see
-- the updated state.
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public._sbp_bill_recompute_totals(p_bill_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_subtotal    numeric := 0;
  v_gst         numeric := 0;
  v_discount    numeric := 0;
  v_paid        numeric := 0;
  v_grand       numeric := 0;
  v_balance     numeric := 0;
  v_status      text;
  v_items_jsonb jsonb;
BEGIN
  -- Subtotal + GST from non-voided items
  SELECT
    COALESCE(SUM(COALESCE(qty,0) * COALESCE(rate,0)), 0),
    COALESCE(SUM(COALESCE(qty,0) * COALESCE(rate,0) * COALESCE(gst_rate,0) / 100), 0)
  INTO v_subtotal, v_gst
  FROM bill_items
  WHERE bill_id = p_bill_id
    AND COALESCE(voided, false) = false;

  -- Bill-level discount + paid + current status
  SELECT
    COALESCE(discount, 0),
    COALESCE(paid_amount, 0),
    status
  INTO v_discount, v_paid, v_status
  FROM bills WHERE id = p_bill_id;

  v_grand   := GREATEST(0, v_subtotal + v_gst - v_discount);
  v_balance := GREATEST(0, v_grand - v_paid);

  -- Status: only auto-recompute if not voided/cancelled
  IF COALESCE(v_status, '') NOT IN ('voided', 'Cancelled', 'cancelled') THEN
    IF v_balance <= 0 AND v_paid > 0 THEN
      v_status := 'Paid';
    ELSIF v_paid > 0 THEN
      v_status := 'Partial';
    -- else: leave status as-is (e.g. 'Pending', 'Credit')
    END IF;
  END IF;

  -- Sync bills.items jsonb from bill_items (so `select('*')` callers see truth)
  SELECT COALESCE(jsonb_agg(to_jsonb(bi) ORDER BY bi.created_at, bi.id), '[]'::jsonb)
  INTO v_items_jsonb
  FROM bill_items bi
  WHERE bi.bill_id = p_bill_id;

  UPDATE bills SET
    subtotal    = v_subtotal,
    gst_amount  = v_gst,
    grand_total = v_grand,
    balance_due = v_balance,
    status      = v_status,
    items       = v_items_jsonb
  WHERE id = p_bill_id;

  RETURN jsonb_build_object(
    'subtotal',    v_subtotal,
    'gst_amount',  v_gst,
    'grand_total', v_grand,
    'balance_due', v_balance,
    'status',      v_status
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public._sbp_bill_recompute_totals(uuid) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- Helper: defensive stock restore — adds qty back to products.stock_qty
-- for each non-voided product item in the bill. Wraps in exception
-- handler so a stock error doesn't fail the parent operation.
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public._sbp_bill_restore_stock(p_bill_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_item record;
BEGIN
  FOR v_item IN
    SELECT product_id, COALESCE(qty, 0) AS qty
    FROM bill_items
    WHERE bill_id = p_bill_id
      AND product_id IS NOT NULL
      AND COALESCE(voided, false) = false
  LOOP
    BEGIN
      UPDATE products
         SET stock_qty = COALESCE(stock_qty, 0) + v_item.qty
       WHERE id = v_item.product_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Stock restore skipped for product %: %', v_item.product_id, SQLERRM;
    END;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public._sbp_bill_restore_stock(uuid) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 1. sbp_bill_void_item — soft-void a single line item
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_bill_void_item(
  p_shop_id   uuid,
  p_bill_id   uuid,
  p_item_id   uuid,
  p_auth_pin  text,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_pin       jsonb;
  v_user_id   uuid;
  v_user_name text;
  v_user_role text;
  v_item      bill_items%ROWTYPE;
  v_before    jsonb;
  v_after     jsonb;
  v_totals    jsonb;
BEGIN
  -- Ownership
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  -- Server-side PIN verify
  v_pin := public.sbp_verify_pin(p_shop_id, p_auth_pin);
  IF NOT COALESCE((v_pin->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_invalid');
  END IF;
  v_user_id   := NULLIF(v_pin->>'user_id', '')::uuid;
  v_user_name := v_pin->>'user_name';
  v_user_role := v_pin->>'auth_role';

  -- Lock + load item (verifies it belongs to this bill + shop)
  SELECT bi.* INTO v_item
  FROM bill_items bi
  JOIN bills b ON b.id = bi.bill_id
  WHERE bi.id = p_item_id
    AND bi.bill_id = p_bill_id
    AND b.shop_id = p_shop_id
  FOR UPDATE OF bi;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'item_not_found');
  END IF;

  IF COALESCE(v_item.voided, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_voided');
  END IF;

  -- Refuse if this would void the last active item (use delete-bill instead)
  IF (SELECT COUNT(*) FROM bill_items
       WHERE bill_id = p_bill_id AND COALESCE(voided, false) = false) <= 1 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'last_active_item');
  END IF;

  v_before := to_jsonb(v_item);

  -- Void the item
  UPDATE bill_items SET voided = true WHERE id = p_item_id;

  -- Restock if a product item (single-item restore — small inline loop)
  IF v_item.product_id IS NOT NULL THEN
    BEGIN
      UPDATE products SET stock_qty = COALESCE(stock_qty, 0) + COALESCE(v_item.qty, 0)
       WHERE id = v_item.product_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Stock restore skipped: %', SQLERRM;
    END;
  END IF;

  -- Recompute bill totals
  v_totals := public._sbp_bill_recompute_totals(p_bill_id);

  v_after := to_jsonb(v_item);
  v_after := jsonb_set(v_after, '{voided}', 'true'::jsonb);

  -- Audit log
  PERFORM public.sbp_audit_log_write(
    p_shop_id              => p_shop_id,
    p_action_code          => 'bill.void_item',
    p_target_table         => 'bill_items',
    p_target_id            => p_item_id,
    p_before_json          => v_before,
    p_after_json           => v_after,
    p_reason               => p_reason,
    p_authorized_by_user_id=> v_user_id,
    p_authorized_by_name   => v_user_name,
    p_auth_method          => 'pin',
    p_actor_name           => v_user_name
  );

  RETURN jsonb_build_object(
    'ok',          true,
    'bill_id',     p_bill_id,
    'item_id',     p_item_id,
    'totals',      v_totals,
    'verified_by', v_user_name
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_bill_void_item(uuid, uuid, uuid, text, text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 2. sbp_bill_delete_item — permanently remove a line item
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_bill_delete_item(
  p_shop_id   uuid,
  p_bill_id   uuid,
  p_item_id   uuid,
  p_auth_pin  text,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_pin       jsonb;
  v_user_id   uuid;
  v_user_name text;
  v_item      bill_items%ROWTYPE;
  v_before    jsonb;
  v_totals    jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  v_pin := public.sbp_verify_pin(p_shop_id, p_auth_pin);
  IF NOT COALESCE((v_pin->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_invalid');
  END IF;
  v_user_id   := NULLIF(v_pin->>'user_id', '')::uuid;
  v_user_name := v_pin->>'user_name';

  SELECT bi.* INTO v_item
  FROM bill_items bi
  JOIN bills b ON b.id = bi.bill_id
  WHERE bi.id = p_item_id
    AND bi.bill_id = p_bill_id
    AND b.shop_id = p_shop_id
  FOR UPDATE OF bi;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'item_not_found');
  END IF;

  -- Block deletion of the last active item (use bill delete or void instead)
  IF (SELECT COUNT(*) FROM bill_items
       WHERE bill_id = p_bill_id AND COALESCE(voided, false) = false) <= 1
     AND NOT COALESCE(v_item.voided, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'last_active_item');
  END IF;

  v_before := to_jsonb(v_item);

  -- Restock if a non-voided product item
  IF v_item.product_id IS NOT NULL AND NOT COALESCE(v_item.voided, false) THEN
    BEGIN
      UPDATE products SET stock_qty = COALESCE(stock_qty, 0) + COALESCE(v_item.qty, 0)
       WHERE id = v_item.product_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Stock restore skipped: %', SQLERRM;
    END;
  END IF;

  DELETE FROM bill_items WHERE id = p_item_id;

  v_totals := public._sbp_bill_recompute_totals(p_bill_id);

  PERFORM public.sbp_audit_log_write(
    p_shop_id              => p_shop_id,
    p_action_code          => 'bill.delete_item',
    p_target_table         => 'bill_items',
    p_target_id            => p_item_id,
    p_before_json          => v_before,
    p_after_json           => NULL,
    p_reason               => p_reason,
    p_authorized_by_user_id=> v_user_id,
    p_authorized_by_name   => v_user_name,
    p_auth_method          => 'pin',
    p_actor_name           => v_user_name
  );

  RETURN jsonb_build_object(
    'ok',          true,
    'bill_id',     p_bill_id,
    'item_id',     p_item_id,
    'totals',      v_totals,
    'verified_by', v_user_name
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_bill_delete_item(uuid, uuid, uuid, text, text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 3. sbp_bill_delete — permanently delete entire bill (cascades to items)
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_bill_delete(
  p_shop_id   uuid,
  p_bill_id   uuid,
  p_auth_pin  text,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_pin       jsonb;
  v_user_id   uuid;
  v_user_name text;
  v_bill      bills%ROWTYPE;
  v_before    jsonb;
  v_items     jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  v_pin := public.sbp_verify_pin(p_shop_id, p_auth_pin);
  IF NOT COALESCE((v_pin->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_invalid');
  END IF;
  v_user_id   := NULLIF(v_pin->>'user_id', '')::uuid;
  v_user_name := v_pin->>'user_name';

  SELECT * INTO v_bill FROM bills
   WHERE id = p_bill_id AND shop_id = p_shop_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  -- Snapshot bill + its items into the audit before deleting
  SELECT COALESCE(jsonb_agg(to_jsonb(bi) ORDER BY bi.created_at, bi.id), '[]'::jsonb)
  INTO v_items FROM bill_items bi WHERE bi.bill_id = p_bill_id;

  v_before := to_jsonb(v_bill) || jsonb_build_object('bill_items', v_items);

  -- Restore stock for non-voided product items before deletion
  PERFORM public._sbp_bill_restore_stock(p_bill_id);

  -- Reverse customer ledger if credit was outstanding
  IF COALESCE(v_bill.customer_id::text, '') <> '' AND COALESCE(v_bill.balance_due, 0) > 0 THEN
    BEGIN
      UPDATE customers
         SET balance = GREATEST(0, COALESCE(balance, 0) - COALESCE(v_bill.balance_due, 0))
       WHERE id = v_bill.customer_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Ledger reversal skipped: %', SQLERRM;
    END;
  END IF;

  -- Delete bill_items first (defensive — FK should cascade but be explicit)
  DELETE FROM bill_items WHERE bill_id = p_bill_id;
  DELETE FROM bills WHERE id = p_bill_id;

  PERFORM public.sbp_audit_log_write(
    p_shop_id              => p_shop_id,
    p_action_code          => 'bill.delete',
    p_target_table         => 'bills',
    p_target_id            => p_bill_id,
    p_before_json          => v_before,
    p_after_json           => NULL,
    p_reason               => p_reason,
    p_authorized_by_user_id=> v_user_id,
    p_authorized_by_name   => v_user_name,
    p_auth_method          => 'pin',
    p_actor_name           => v_user_name
  );

  RETURN jsonb_build_object(
    'ok',          true,
    'bill_id',     p_bill_id,
    'invoice_no',  v_bill.invoice_no,
    'verified_by', v_user_name
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_bill_delete(uuid, uuid, text, text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 4. sbp_bill_reopen — reopen a closed bill for editing
-- Restores stock + reverses customer ledger (if credit was outstanding)
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_bill_reopen(
  p_shop_id   uuid,
  p_bill_id   uuid,
  p_auth_pin  text,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_pin           jsonb;
  v_user_id       uuid;
  v_user_name     text;
  v_bill          bills%ROWTYPE;
  v_old_status    text;
  v_old_balance   numeric;
  v_was_credit    boolean;
  v_before        jsonb;
  v_after         jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  v_pin := public.sbp_verify_pin(p_shop_id, p_auth_pin);
  IF NOT COALESCE((v_pin->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_invalid');
  END IF;
  v_user_id   := NULLIF(v_pin->>'user_id', '')::uuid;
  v_user_name := v_pin->>'user_name';

  SELECT * INTO v_bill FROM bills
   WHERE id = p_bill_id AND shop_id = p_shop_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  v_old_status  := v_bill.status;
  v_old_balance := COALESCE(v_bill.balance_due, 0);
  v_was_credit  := v_old_status IN ('Credit', 'Partial', 'Pending') AND v_old_balance > 0;

  v_before := to_jsonb(v_bill);

  -- Restore stock (for non-voided product items)
  PERFORM public._sbp_bill_restore_stock(p_bill_id);

  -- Reverse customer ledger if credit was open
  IF v_was_credit AND COALESCE(v_bill.customer_id::text, '') <> '' THEN
    BEGIN
      UPDATE customers
         SET balance = GREATEST(0, COALESCE(balance, 0) - v_old_balance)
       WHERE id = v_bill.customer_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Ledger reversal skipped: %', SQLERRM;
    END;
  END IF;

  -- Reopen: reset status, clear payment, set balance to grand_total
  UPDATE bills SET
    status        = 'Pending',
    paid_amount   = 0,
    balance_due   = COALESCE(grand_total, 0),
    reopened_at   = now()
  WHERE id = p_bill_id;

  SELECT * INTO v_bill FROM bills WHERE id = p_bill_id;
  v_after := to_jsonb(v_bill);

  PERFORM public.sbp_audit_log_write(
    p_shop_id              => p_shop_id,
    p_action_code          => 'bill.reopen',
    p_target_table         => 'bills',
    p_target_id            => p_bill_id,
    p_before_json          => v_before,
    p_after_json           => v_after,
    p_reason               => p_reason,
    p_authorized_by_user_id=> v_user_id,
    p_authorized_by_name   => v_user_name,
    p_auth_method          => 'pin',
    p_actor_name           => v_user_name
  );

  RETURN jsonb_build_object(
    'ok',             true,
    'bill_id',        p_bill_id,
    'invoice_no',     v_bill.invoice_no,
    'old_status',     v_old_status,
    'new_status',     v_bill.status,
    'credit_reversed', v_was_credit,
    'verified_by',    v_user_name
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_bill_reopen(uuid, uuid, text, text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════
-- 5. sbp_bill_edit_start — verify PIN + log edit-started entry
-- The actual edit happens in billing.html; this RPC just makes the
-- PIN check server-side and records who opened the bill for editing.
-- Returns the bill payload for billing.html to load.
-- ══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.sbp_bill_edit_start(
  p_shop_id   uuid,
  p_bill_id   uuid,
  p_auth_pin  text
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_pin       jsonb;
  v_user_id   uuid;
  v_user_name text;
  v_bill      bills%ROWTYPE;
  v_items     jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;
  v_pin := public.sbp_verify_pin(p_shop_id, p_auth_pin);
  IF NOT COALESCE((v_pin->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_invalid');
  END IF;
  v_user_id   := NULLIF(v_pin->>'user_id', '')::uuid;
  v_user_name := v_pin->>'user_name';

  SELECT * INTO v_bill FROM bills
   WHERE id = p_bill_id AND shop_id = p_shop_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bill_not_found');
  END IF;

  -- Pull current bill_items snapshot (for billing.html to use)
  SELECT COALESCE(jsonb_agg(to_jsonb(bi) ORDER BY bi.created_at, bi.id), '[]'::jsonb)
  INTO v_items FROM bill_items bi WHERE bi.bill_id = p_bill_id;

  PERFORM public.sbp_audit_log_write(
    p_shop_id              => p_shop_id,
    p_action_code          => 'bill.edit_start',
    p_target_table         => 'bills',
    p_target_id            => p_bill_id,
    p_before_json          => NULL,
    p_after_json           => NULL,
    p_reason               => NULL,
    p_authorized_by_user_id=> v_user_id,
    p_authorized_by_name   => v_user_name,
    p_auth_method          => 'pin',
    p_actor_name           => v_user_name
  );

  RETURN jsonb_build_object(
    'ok',          true,
    'bill_id',     p_bill_id,
    'invoice_no',  v_bill.invoice_no,
    'verified_by', v_user_name,
    'bill',        to_jsonb(v_bill),
    'bill_items',  v_items
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.sbp_bill_edit_start(uuid, uuid, text) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- End of migration 038
-- ════════════════════════════════════════════════════════════════════
