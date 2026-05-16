-- ════════════════════════════════════════════════════════════════════
-- BATCH 068 — QR Guest Orders
-- ════════════════════════════════════════════════════════════════════
-- Lets a guest scan a QR sticker on their table and place an order
-- directly from their phone (no app install, no login). Order lands
-- as a 'pending' row that the waiter accepts/rejects on the running
-- order page; on accept, it merges into the running order as the
-- next KOT round.
--
-- Architecture decisions (locked May 16 2026):
--   1. Anonymous scan — no guest login.
--   2. Name + phone OPTIONAL, captured at place time.
--   3. Staff acceptance required before KOT fires.
--   4. Guest order = separate pending row, merges on accept.
--   5. Supabase Realtime broadcasts new pending rows to staff.
--   6. Guest can browse always, but ordering gated on table being
--      'occupied' or 'reserved' (must be seated first).
--   7. Plan gate: Business tier only (incl. 60-day trial).
--
-- Tables:
--   - sbp_guest_orders                 (new — pending guest requests)
--   - shops.guest_order_counter        (new column — atomic G-XXXX numbering)
--
-- RPCs (all SECURITY DEFINER, all with explicit extensions search_path
-- because the void-item bug taught us that lesson):
--   - sbp_guest_menu_get_public(slug, table_num)        ANON  · resolve+menu+state
--   - sbp_guest_order_place(slug, table_num, items, …)  ANON  · create pending row
--   - sbp_guest_order_status(guest_order_id)            ANON  · poll status
--   - sbp_guest_order_accept(shop_id, guest_order_id)   AUTH  · merge into RO
--   - sbp_guest_order_reject(shop_id, guest_order_id, reason) AUTH · mark rejected
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────
-- 0. Atomic guest-order counter per shop
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE shops ADD COLUMN IF NOT EXISTS guest_order_counter int NOT NULL DEFAULT 0;


-- ─────────────────────────────────────────────────────────────────
-- 1. sbp_guest_orders table
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sbp_guest_orders (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id           uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  table_id          uuid REFERENCES sbp_restaurant_tables(id) ON DELETE SET NULL,
  table_number      text NOT NULL,
  running_order_id  uuid REFERENCES sbp_running_orders(id) ON DELETE SET NULL,

  -- Atomic per-shop guest order number, G-0001 format
  guest_order_no    text NOT NULL,

  -- Optional guest details
  guest_name        text,
  guest_phone       text,

  -- Same item shape as running_orders.items (name/qty/price/gst_rate/notes/service_id)
  items             jsonb NOT NULL DEFAULT '[]'::jsonb,
  notes             text,                          -- order-level note ("birthday — bring candle")

  -- Lifecycle
  status            text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','accepted','rejected','expired')),
  rejected_reason   text,
  accepted_kot_no   int,                           -- KOT number assigned on accept
  accepted_by_name  text,                          -- staff member who clicked accept

  created_at        timestamptz NOT NULL DEFAULT now(),
  accepted_at       timestamptz,
  rejected_at       timestamptz,

  -- Anti-spam: throttle to 1 pending per (shop_id, table_number) at a time.
  -- Enforced at insert via a partial unique index (only PENDING rows count).
  UNIQUE (shop_id, guest_order_no)
);

-- Only ONE pending guest order per table at a time.
-- (Tables can have many accepted/rejected ones in history; this gate is
--  status-scoped via a partial index.)
CREATE UNIQUE INDEX IF NOT EXISTS idx_go_one_pending_per_table
  ON sbp_guest_orders(shop_id, table_number)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_go_shop_status
  ON sbp_guest_orders(shop_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_go_ro
  ON sbp_guest_orders(running_order_id) WHERE running_order_id IS NOT NULL;


-- RLS — owners + staff see their shop's rows. Anon-callable RPCs use
-- SECURITY DEFINER so they bypass RLS where needed.
ALTER TABLE sbp_guest_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_go_owner ON sbp_guest_orders;
CREATE POLICY p_go_owner ON sbp_guest_orders
  FOR ALL TO authenticated
  USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
    OR
    shop_id IN (SELECT shop_id FROM shop_users WHERE user_id = auth.uid() AND is_active = true)
  )
  WITH CHECK (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
    OR
    shop_id IN (SELECT shop_id FROM shop_users WHERE user_id = auth.uid() AND is_active = true)
  );


-- ─────────────────────────────────────────────────────────────────
-- 2. Realtime publication
-- ─────────────────────────────────────────────────────────────────
-- Supabase Realtime broadcasts INSERTs/UPDATEs to subscribed clients
-- via this publication. Staff's running-order.html subscribes here.
DO $$
BEGIN
  -- Add only if the publication exists and the table isn't already in it
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND tablename = 'sbp_guest_orders'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE sbp_guest_orders;
    END IF;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Realtime publication setup skipped: %', SQLERRM;
END $$;


-- ─────────────────────────────────────────────────────────────────
-- Helper: is this shop on an active Business plan (paid or in trial)?
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sbp_shop_has_qr_access(p_shop_id uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_plan        text;
  v_expires     timestamptz;
BEGIN
  SELECT plan, plan_expires_at
    INTO v_plan, v_expires
  FROM shops WHERE id = p_shop_id;

  -- enterprise = legacy alias for business
  IF v_plan IN ('business','enterprise') THEN
    -- Active if no expiry, or expiry in the future (trial still valid)
    RETURN v_expires IS NULL OR v_expires > now();
  END IF;
  RETURN false;
END;
$$;
GRANT EXECUTE ON FUNCTION public._sbp_shop_has_qr_access(uuid) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 3. sbp_guest_menu_get_public(slug, table_number)
-- ─────────────────────────────────────────────────────────────────
-- ANON-callable. Resolves shop slug → shop, loads menu, reports table
-- state. Returns enough for the QR menu page to render fully.
--
-- Response shape:
--   {
--     ok, error,
--     shop:    { id, name, address, phone, currency },
--     table:   { id, number, status, can_order },
--     menu:    [ {id, name, description, category, price, gst_rate, image_url, is_available} ],
--     qr_enabled: boolean   (Business plan check)
--   }
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_guest_menu_get_public(text, text);
CREATE OR REPLACE FUNCTION sbp_guest_menu_get_public(
  p_slug         text,
  p_table_number text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_shop_id   uuid;
  v_published boolean;
  v_shop_row  shops%ROWTYPE;
  v_table     sbp_restaurant_tables%ROWTYPE;
  v_clean     text;
  v_menu      jsonb;
  v_qr        boolean;
BEGIN
  v_clean := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean) = 0 OR length(trim(coalesce(p_table_number, ''))) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_input');
  END IF;

  -- Slug → shop_id
  SELECT shop_id, published INTO v_shop_id, v_published
  FROM sbp_shop_websites WHERE slug = v_clean;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  SELECT * INTO v_shop_row FROM shops WHERE id = v_shop_id;
  IF v_shop_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  -- Business plan / trial check. If not Business, we still return shop
  -- info but with qr_enabled=false so the page shows a polite notice.
  v_qr := public._sbp_shop_has_qr_access(v_shop_id);

  -- Table by (shop_id, table_number)
  SELECT * INTO v_table
  FROM sbp_restaurant_tables
  WHERE shop_id = v_shop_id AND table_number = trim(p_table_number) AND active = true;

  IF v_table.id IS NULL THEN
    -- Table doesn't exist — show "this table isn't set up yet" message
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'table_not_found',
      'shop', jsonb_build_object('name', v_shop_row.name),
      'qr_enabled', v_qr
    );
  END IF;

  -- Menu — only ACTIVE services for this shop. is_available is shown
  -- (so out-of-stock items can be visible-but-disabled in the UI).
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',            s.id,
      'name',          s.name,
      'description',   s.description,
      'category',      s.category,
      'price',         s.price,
      'gst_rate',      s.gst_rate,
      'hsn_sac_code',  s.hsn_sac_code,
      'image_url',     s.image_url,
      'is_available',  COALESCE(s.is_available, true),
      'display_order', s.display_order
    ) ORDER BY s.display_order, s.name
  ), '[]'::jsonb)
  INTO v_menu
  FROM sbp_services s
  WHERE s.shop_id = v_shop_id AND s.active = true;

  RETURN jsonb_build_object(
    'ok', true,
    'shop', jsonb_build_object(
      'id',       v_shop_row.id,
      'name',     v_shop_row.name,
      'address',  COALESCE(v_shop_row.address, ''),
      'phone',    COALESCE(v_shop_row.phone, ''),
      'currency', '₹'
    ),
    'table', jsonb_build_object(
      'id',         v_table.id,
      'number',     v_table.table_number,
      'status',     v_table.status,
      -- Can order only when staff has opened the table (status occupied/reserved).
      -- 'free' = guest can browse but the place button is gated.
      'can_order',  v_table.status IN ('occupied','reserved')
    ),
    'menu',       v_menu,
    'qr_enabled', v_qr
  );
END;
$$;

REVOKE ALL ON FUNCTION sbp_guest_menu_get_public(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_menu_get_public(text, text) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 4. sbp_guest_order_place(slug, table_num, items, notes, phone, name)
-- ─────────────────────────────────────────────────────────────────
-- ANON-callable. Validates everything server-side (don't trust the
-- anon client), inserts a pending guest order row.
--
-- Validations:
--   • Slug + table exist
--   • Shop has Business plan / trial
--   • Table is 'occupied' or 'reserved' (must be seated)
--   • Items array non-empty
--   • No existing pending guest order for this table (anti-spam)
--   • Every item.service_id (if present) belongs to this shop
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_guest_order_place(text, text, jsonb, text, text, text);
CREATE OR REPLACE FUNCTION sbp_guest_order_place(
  p_slug         text,
  p_table_number text,
  p_items        jsonb,
  p_notes        text  DEFAULT NULL,
  p_phone        text  DEFAULT NULL,
  p_name         text  DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_shop_id    uuid;
  v_table      sbp_restaurant_tables%ROWTYPE;
  v_clean      text;
  v_n          int;
  v_counter    int;
  v_order_no   text;
  v_order_id   uuid;
  v_clean_items jsonb := '[]'::jsonb;
  v_item       jsonb;
  v_service_ok boolean;
BEGIN
  v_clean := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_slug');
  END IF;

  SELECT shop_id INTO v_shop_id FROM sbp_shop_websites WHERE slug = v_clean;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  IF NOT public._sbp_shop_has_qr_access(v_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan_required');
  END IF;

  SELECT * INTO v_table FROM sbp_restaurant_tables
   WHERE shop_id = v_shop_id AND table_number = trim(p_table_number) AND active = true;
  IF v_table.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'table_not_found');
  END IF;

  IF v_table.status NOT IN ('occupied','reserved') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'table_not_open');
  END IF;

  -- Items array sanity
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_items');
  END IF;
  IF jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_items');
  END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    -- Sanity cap; honest restaurants don't have 50+ different dishes per order
    RETURN jsonb_build_object('ok', false, 'error', 'too_many_items');
  END IF;

  -- Anti-spam: only one pending order per table at a time
  IF EXISTS (
    SELECT 1 FROM sbp_guest_orders
    WHERE shop_id = v_shop_id AND table_number = v_table.table_number AND status = 'pending'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pending_exists');
  END IF;

  -- Validate + sanitise each item. Re-fetch price/gst from sbp_services
  -- so a malicious client can't underpay. Name we trust (presentation only).
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    DECLARE
      v_sid    uuid;
      v_qty    int;
      v_note   text;
      v_srv    sbp_services%ROWTYPE;
    BEGIN
      v_sid  := NULLIF(v_item->>'service_id', '')::uuid;
      v_qty  := COALESCE((v_item->>'qty')::int, 1);
      v_note := NULLIF(trim(coalesce(v_item->>'notes', '')), '');

      IF v_qty < 1 OR v_qty > 99 THEN
        RAISE EXCEPTION 'invalid_qty';
      END IF;

      IF v_sid IS NOT NULL THEN
        SELECT * INTO v_srv FROM sbp_services
         WHERE id = v_sid AND shop_id = v_shop_id AND active = true;
        IF v_srv.id IS NULL THEN RAISE EXCEPTION 'item_not_in_menu'; END IF;
        IF COALESCE(v_srv.is_available, true) = false THEN RAISE EXCEPTION 'item_unavailable'; END IF;

        v_clean_items := v_clean_items || jsonb_build_array(jsonb_build_object(
          'service_id',   v_srv.id,
          'name',         v_srv.name,
          'qty',          v_qty,
          'price',        v_srv.price,
          'gst_rate',     v_srv.gst_rate,
          'hsn_sac_code', v_srv.hsn_sac_code,
          'notes',        v_note
        ));
      ELSE
        -- No service_id — guest typed a custom item? In the QR menu UI
        -- we don't expose custom items (anti-fraud), so reject these.
        RAISE EXCEPTION 'item_not_in_menu';
      END IF;
    END;
  END LOOP;

  -- Atomic guest-order counter: G-0001, G-0002, …
  UPDATE shops
     SET guest_order_counter = COALESCE(guest_order_counter, 0) + 1
   WHERE id = v_shop_id
   RETURNING guest_order_counter INTO v_counter;
  v_order_no := 'G-' || lpad(v_counter::text, 4, '0');

  -- Insert pending row. The partial unique index on (shop_id, table_number)
  -- WHERE status='pending' is our concurrency guard if two anon clients
  -- post at the same millisecond.
  BEGIN
    INSERT INTO sbp_guest_orders(
      shop_id, table_id, table_number, guest_order_no,
      guest_name, guest_phone, items, notes, status
    ) VALUES (
      v_shop_id, v_table.id, v_table.table_number, v_order_no,
      NULLIF(trim(coalesce(p_name, '')), ''),
      NULLIF(trim(coalesce(p_phone, '')), ''),
      v_clean_items,
      NULLIF(trim(coalesce(p_notes, '')), ''),
      'pending'
    )
    RETURNING id INTO v_order_id;
  EXCEPTION WHEN unique_violation THEN
    -- Race lost: another pending order beat us. Re-read & report.
    RETURN jsonb_build_object('ok', false, 'error', 'pending_exists');
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'guest_order_id', v_order_id,
    'guest_order_no', v_order_no,
    'status', 'pending'
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Re-throw cleanly via {ok:false, error:<sqlerrm>}. Item validation
    -- exceptions bubble up here too (item_not_in_menu, invalid_qty…).
    RETURN jsonb_build_object('ok', false, 'error', COALESCE(SQLERRM, 'place_failed'));
END;
$$;

REVOKE ALL ON FUNCTION sbp_guest_order_place(text, text, jsonb, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_order_place(text, text, jsonb, text, text, text) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 5. sbp_guest_order_status(guest_order_id)
-- ─────────────────────────────────────────────────────────────────
-- ANON-callable. Used by the QR menu page to poll status if Realtime
-- isn't connected. Returns minimal fields (no PII echo).
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_guest_order_status(uuid);
CREATE OR REPLACE FUNCTION sbp_guest_order_status(p_guest_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_row sbp_guest_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM sbp_guest_orders WHERE id = p_guest_order_id;
  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'guest_order_no',  v_row.guest_order_no,
    'status',          v_row.status,
    'accepted_kot_no', v_row.accepted_kot_no,
    'rejected_reason', v_row.rejected_reason,
    'created_at',      v_row.created_at,
    'accepted_at',     v_row.accepted_at,
    'rejected_at',     v_row.rejected_at
  );
END;
$$;

REVOKE ALL ON FUNCTION sbp_guest_order_status(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_order_status(uuid) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 6. sbp_guest_order_accept(shop_id, guest_order_id)
-- ─────────────────────────────────────────────────────────────────
-- AUTH-only. Staff taps "Accept & Send to Kitchen" on the running
-- order page. We:
--   • Verify ownership/staff for this shop
--   • Resolve or lazily open the running order for this table
--   • Append items via sbp_ro_add_items (which stamps each with
--     item_id + voided_qty:0 baseline, identical to staff-typed items)
--   • Mark guest_order accepted + record KOT number
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_guest_order_accept(uuid, uuid);
CREATE OR REPLACE FUNCTION sbp_guest_order_accept(
  p_shop_id        uuid,
  p_guest_order_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_go       sbp_guest_orders%ROWTYPE;
  v_table    sbp_restaurant_tables%ROWTYPE;
  v_ro_id    uuid;
  v_ro_open  jsonb;
  v_kot_res  jsonb;
  v_kot_no   int;
  v_actor    text;
  v_items    jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_go FROM sbp_guest_orders
   WHERE id = p_guest_order_id AND shop_id = p_shop_id
   FOR UPDATE;
  IF v_go.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_go.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_handled');
  END IF;

  -- Find or open the running order for this table
  SELECT * INTO v_table FROM sbp_restaurant_tables
   WHERE shop_id = p_shop_id AND table_number = v_go.table_number AND active = true;
  IF v_table.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'table_gone');
  END IF;

  -- Use the table's open running_order (if any), else lazy-open one
  SELECT id INTO v_ro_id FROM sbp_running_orders
   WHERE shop_id = p_shop_id AND table_id = v_table.id AND status = 'open'
   ORDER BY opened_at DESC LIMIT 1;

  IF v_ro_id IS NULL THEN
    -- Lazy-open. sbp_ro_open returns {ok, order:{id,…}}
    v_ro_open := sbp_ro_open(p_shop_id, v_table.id, v_table.table_number);
    IF NOT COALESCE((v_ro_open->>'ok')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ro_open_failed', 'detail', v_ro_open);
    END IF;
    v_ro_id := (v_ro_open->'order'->>'id')::uuid;
  END IF;

  -- Append the items as a new KOT round. Items go in WITHOUT service_id
  -- nulled because sbp_ro_add_items expects the same shape we already
  -- have. Per-item notes flow through. Order-level note becomes the
  -- KOT-level p_notes argument.
  v_items := v_go.items;
  v_kot_res := sbp_ro_add_items(p_shop_id, v_ro_id, v_items, v_go.notes);
  IF NOT COALESCE((v_kot_res->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'kot_failed', 'detail', v_kot_res);
  END IF;
  v_kot_no := (v_kot_res->>'kot_number')::int;

  -- Who clicked accept? Best-effort name from sbp_authorized_users (if
  -- the auth-pin lib stamped the request) or owner display name.
  v_actor := COALESCE(
    (SELECT name FROM sbp_authorized_users
       WHERE shop_id = p_shop_id AND user_id = auth.uid() LIMIT 1),
    (SELECT name FROM shops WHERE id = p_shop_id LIMIT 1),
    'staff'
  );

  -- Mark accepted
  UPDATE sbp_guest_orders
     SET status           = 'accepted',
         accepted_at      = now(),
         accepted_kot_no  = v_kot_no,
         accepted_by_name = v_actor,
         running_order_id = v_ro_id
   WHERE id = p_guest_order_id;

  RETURN jsonb_build_object(
    'ok', true,
    'guest_order_id',  p_guest_order_id,
    'running_order_id', v_ro_id,
    'kot_number',      v_kot_no,
    'accepted_by',     v_actor
  );
END;
$$;

REVOKE ALL ON FUNCTION sbp_guest_order_accept(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_order_accept(uuid, uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 7. sbp_guest_order_reject(shop_id, guest_order_id, reason)
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_guest_order_reject(uuid, uuid, text);
CREATE OR REPLACE FUNCTION sbp_guest_order_reject(
  p_shop_id        uuid,
  p_guest_order_id uuid,
  p_reason         text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_go sbp_guest_orders%ROWTYPE;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT * INTO v_go FROM sbp_guest_orders
   WHERE id = p_guest_order_id AND shop_id = p_shop_id
   FOR UPDATE;
  IF v_go.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF v_go.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_handled');
  END IF;

  UPDATE sbp_guest_orders
     SET status          = 'rejected',
         rejected_at     = now(),
         rejected_reason = COALESCE(NULLIF(trim(p_reason), ''), 'No reason given')
   WHERE id = p_guest_order_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION sbp_guest_order_reject(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_order_reject(uuid, uuid, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 8. sbp_guest_order_pending_list(shop_id)
-- ─────────────────────────────────────────────────────────────────
-- Staff convenience: on running-order.html load, fetch all pending
-- guest orders for this shop in one call so the banner has data
-- even before any realtime event fires.
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS sbp_guest_order_pending_list(uuid);
CREATE OR REPLACE FUNCTION sbp_guest_order_pending_list(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',             g.id,
      'guest_order_no', g.guest_order_no,
      'table_number',   g.table_number,
      'guest_name',     g.guest_name,
      'guest_phone',    g.guest_phone,
      'items',          g.items,
      'notes',          g.notes,
      'created_at',     g.created_at
    ) ORDER BY g.created_at DESC
  ), '[]'::jsonb)
  INTO v_rows
  FROM sbp_guest_orders g
  WHERE g.shop_id = p_shop_id AND g.status = 'pending';

  RETURN jsonb_build_object('ok', true, 'pending', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION sbp_guest_order_pending_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sbp_guest_order_pending_list(uuid) TO authenticated;


NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify (in Supabase SQL Editor):
--
-- -- 1. Table exists
-- SELECT count(*) FROM sbp_guest_orders;        -- 0
--
-- -- 2. Counter column added
-- SELECT column_name FROM information_schema.columns
--  WHERE table_name='shops' AND column_name='guest_order_counter';
--
-- -- 3. RPCs present
-- SELECT routine_name FROM information_schema.routines
--  WHERE routine_schema='public' AND routine_name LIKE 'sbp_guest_%';
-- -- expect 6 rows
--
-- -- 4. Realtime publication includes the table
-- SELECT tablename FROM pg_publication_tables
--  WHERE pubname='supabase_realtime' AND tablename='sbp_guest_orders';
--
-- -- 5. Smoke test (replace UUIDs with your own):
-- SELECT sbp_guest_menu_get_public('your-slug', '10');
-- ════════════════════════════════════════════════════════════════════
