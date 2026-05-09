-- ════════════════════════════════════════════════════════════════════
-- 025_bills_integrity.sql
-- Batch 021.5 — Bills + customer linkage integrity (9 May 2026)
--
-- Closes 5 root causes surfaced during Glitz & Glam hotel testing:
--
--   (a) next_invoice_no RPC was failing with HTTP 400 due to PG error
--       42702 (ambiguous_column) — OUT-param names colliding with
--       shops table columns. Client silent-caught and fell back to a
--       stale localStorage counter, producing duplicate invoice numbers
--       (e.g. GG-0076 assigned to two different bills, illegal under GST).
--
--   (b) bills.customer_id was always NULL because billing.html bill
--       insert never set it. sbp_get_customer_timeline filters strictly
--       on customer_id → guest history pages always show 0 bills /
--       ₹0 spent regardless of how many bills the customer actually has.
--
--   (c) Hotel checkouts that didn't link booking → bill leave the
--       booking with bill_id = NULL, which makes salvage skip them.
--
--   (d) Existing salvage RPC requires bookings.bill_id IS NOT NULL —
--       no fuzzy fallback by name+amount+date.
--
--   (e) Customer timeline RPC fails closed (zero stats) when customer_id
--       linkage is missing, even when bills exist under the same name.
--
-- DELIVERABLES (all idempotent, safe to re-run):
--   1. Fix next_invoice_no — rename internal column refs, preserve API.
--   2. NEW sbp_backfill_bills_customer_id(shop_id) — backfills NULL
--      customer_id on existing bills via name + normalized phone.
--   3. NEW sbp_link_orphan_hotel_bills(shop_id) — fuzzy-matches checked-out
--      bookings (bill_id IS NULL) to bills by customer_name + grand_total
--      ± ₹1 + check_out_date ± 1 day, writes bill_id back to booking.
--   4. PATCH sbp_get_customer_timeline — adds name+shop fallback so
--      legacy bills with NULL customer_id still appear in stats.
--   5. PATCH sbp_salvage_orphan_hotel_bills — runs link-orphans pass
--      first, then existing salvage logic.
--   6. Auto-runs steps 2 + 3 + salvage for hospitality + commerce shops.
--
-- Prerequisites: migrations 003, 013, 015, 022, 023, 024 must have run.
-- ════════════════════════════════════════════════════════════════════


-- ──────────────────────────────────────────────────────────────────
-- 1. FIX: next_invoice_no — drop PG 42702 ambiguous_column error
-- ──────────────────────────────────────────────────────────────────
--
-- Old function declared OUT params named identically to shops table
-- columns (invoice_prefix, invoice_counter). PostgreSQL raised 42702
-- on the assignment statements because plpgsql.variable_conflict
-- defaults to 'error'. Rewrite to use only local variables internally
-- and project them via RETURN QUERY SELECT — preserves API contract.
--
-- Client at billing.html unchanged: still calls
--   _sb.rpc('next_invoice_no', { p_shop_id }) and reads
--   row.invoice_prefix + row.invoice_counter.

DROP FUNCTION IF EXISTS public.next_invoice_no(uuid);

CREATE OR REPLACE FUNCTION public.next_invoice_no(p_shop_id uuid)
RETURNS TABLE(invoice_prefix text, invoice_counter int)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_prefix  text;
  v_counter int;
  v_owner   uuid;
BEGIN
  -- Ownership check (cheap, atomic, no RLS surprises)
  SELECT s.owner_id INTO v_owner FROM public.shops s WHERE s.id = p_shop_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'shop_not_found';
  END IF;
  IF v_owner <> auth.uid() THEN
    RAISE EXCEPTION 'not_owner';
  END IF;

  -- Atomic increment + capture new value into local vars only.
  -- Fully qualifying with table alias 's' eliminates any column/var
  -- ambiguity even under stricter plpgsql.variable_conflict settings.
  UPDATE public.shops AS s
     SET invoice_counter = COALESCE(s.invoice_counter, 0) + 1
   WHERE s.id = p_shop_id
   RETURNING s.invoice_prefix, s.invoice_counter
        INTO v_prefix, v_counter;

  IF v_counter IS NULL THEN
    RAISE EXCEPTION 'shop_not_found';
  END IF;

  -- Project locals back into the TABLE return tuple. No name collision
  -- because we use RETURN QUERY SELECT (not OUT-param assignment).
  RETURN QUERY SELECT COALESCE(v_prefix, 'INV')::text, v_counter::int;
END;
$$;

REVOKE ALL ON FUNCTION public.next_invoice_no(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_invoice_no(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 2. NEW: sbp_backfill_bills_customer_id(shop_id)
-- ──────────────────────────────────────────────────────────────────
--
-- Walks bills.customer_id IS NULL, resolves via name + normalized phone
-- using existing sbp_resolve_customer_for_booking helper, writes
-- customer_id back. Returns count.
--
-- Idempotent — second run finds zero NULL rows.

CREATE OR REPLACE FUNCTION public.sbp_backfill_bills_customer_id(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  r_bill         record;
  v_owner        uuid;
  v_customer_id  uuid;
  v_resolved     int := 0;
  v_skipped      int := 0;
  v_total_null   int := 0;
BEGIN
  -- Ownership check
  SELECT s.owner_id INTO v_owner FROM public.shops s WHERE s.id = p_shop_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  SELECT COUNT(*) INTO v_total_null
    FROM public.bills
   WHERE shop_id = p_shop_id AND customer_id IS NULL;

  FOR r_bill IN
    SELECT id, customer_name, customer_wa, customer_gstin
      FROM public.bills
     WHERE shop_id     = p_shop_id
       AND customer_id IS NULL
       AND customer_name IS NOT NULL
       AND length(trim(customer_name)) > 0
  LOOP
    BEGIN
      v_customer_id := public.sbp_resolve_customer_for_booking(
        p_shop_id,
        r_bill.customer_name,
        r_bill.customer_wa,           -- bills uses customer_wa as the phone-ish field
        r_bill.customer_wa,
        NULL                           -- no email on legacy bills
      );

      IF v_customer_id IS NOT NULL THEN
        UPDATE public.bills
           SET customer_id = v_customer_id
         WHERE id = r_bill.id;
        v_resolved := v_resolved + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      RAISE NOTICE 'Backfill skipped bill %: %', r_bill.id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',           true,
    'total_null',   v_total_null,
    'resolved',     v_resolved,
    'skipped',      v_skipped
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_backfill_bills_customer_id(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 3. NEW: sbp_link_orphan_hotel_bills(shop_id)
-- ──────────────────────────────────────────────────────────────────
--
-- For hotel/hospitality shops only. Walks checked-out bookings whose
-- bill_id is NULL, fuzzy-matches against bills by:
--   - same shop
--   - lower(trim(customer_name)) match
--   - grand_total within ±₹1
--   - bill.invoice_date within ±1 day of booking.check_out_date
--
-- If exactly ONE bill matches → links booking → bill (writes
-- sbp_bookings.bill_id). If zero or multiple matches → skips, logs.
-- Idempotent. Safe to re-run.

CREATE OR REPLACE FUNCTION public.sbp_link_orphan_hotel_bills(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check        jsonb;
  r_booking      record;
  v_match_id     uuid;
  v_match_count  int;
  v_total_orphan int := 0;
  v_linked       int := 0;
  v_ambiguous    int := 0;
  v_no_match     int := 0;
BEGIN
  -- Use the hospitality owner check (covers plan check too)
  v_check := public.sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  SELECT COUNT(*) INTO v_total_orphan
    FROM public.sbp_bookings
   WHERE shop_id = p_shop_id
     AND status  = 'checked_out'
     AND bill_id IS NULL;

  FOR r_booking IN
    SELECT id, customer_name, grand_total, check_out_date
      FROM public.sbp_bookings
     WHERE shop_id = p_shop_id
       AND status  = 'checked_out'
       AND bill_id IS NULL
  LOOP
    v_match_id := NULL;

    -- Count fuzzy-matching bills
    SELECT COUNT(*) INTO v_match_count
      FROM public.bills b
     WHERE b.shop_id = p_shop_id
       AND lower(trim(b.customer_name)) = lower(trim(r_booking.customer_name))
       AND ABS(COALESCE(b.grand_total, 0) - COALESCE(r_booking.grand_total, 0)) <= 1
       AND b.invoice_date BETWEEN r_booking.check_out_date - INTERVAL '1 day'
                              AND r_booking.check_out_date + INTERVAL '1 day';

    IF v_match_count = 1 THEN
      SELECT b.id INTO v_match_id
        FROM public.bills b
       WHERE b.shop_id = p_shop_id
         AND lower(trim(b.customer_name)) = lower(trim(r_booking.customer_name))
         AND ABS(COALESCE(b.grand_total, 0) - COALESCE(r_booking.grand_total, 0)) <= 1
         AND b.invoice_date BETWEEN r_booking.check_out_date - INTERVAL '1 day'
                                AND r_booking.check_out_date + INTERVAL '1 day'
       LIMIT 1;

      UPDATE public.sbp_bookings
         SET bill_id = v_match_id, updated_at = now()
       WHERE id = r_booking.id;

      v_linked := v_linked + 1;
      RAISE NOTICE 'Linked booking % → bill %', r_booking.id, v_match_id;

    ELSIF v_match_count > 1 THEN
      v_ambiguous := v_ambiguous + 1;
      RAISE NOTICE 'Ambiguous booking % — % candidate bills', r_booking.id, v_match_count;
    ELSE
      v_no_match := v_no_match + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                 true,
    'total_orphan',       v_total_orphan,
    'linked',             v_linked,
    'ambiguous',          v_ambiguous,
    'no_match',           v_no_match
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_link_orphan_hotel_bills(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 4. PATCH: sbp_get_customer_timeline — name fallback safety net
-- ──────────────────────────────────────────────────────────────────
--
-- Legacy bills (and any future regression that fails to set
-- bills.customer_id) would otherwise vanish from the customer's
-- timeline page. This patch adds a fallback: if zero rows match by
-- customer_id, ALSO match by lower(trim(customer_name)) within the
-- same shop. The OR clause handles BOTH at once so post-backfill
-- bills + still-orphan bills both render.
--
-- Returns the same JSONB envelope as before — no client change needed.

CREATE OR REPLACE FUNCTION public.sbp_get_customer_timeline(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_user_id    uuid;
  v_customer   record;
  v_shop_id    uuid;
  v_norm_name  text;
  v_norm_phone text;
  v_norm_wa    text;
  v_stats      jsonb;
  v_timeline   jsonb;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unauthorized');
  END IF;

  IF p_customer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_id_required');
  END IF;

  SELECT c.*
    INTO v_customer
    FROM public.customers c
    JOIN public.shops s ON s.id = c.shop_id
   WHERE c.id = p_customer_id
     AND s.owner_id = v_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'customer_not_found_or_unauthorized');
  END IF;

  v_shop_id    := v_customer.shop_id;
  v_norm_name  := NULLIF(lower(trim(COALESCE(v_customer.name, ''))), '');
  v_norm_phone := public.sbp_normalize_phone(v_customer.phone);
  v_norm_wa    := public.sbp_normalize_phone(v_customer.whatsapp);

  -- Stats aggregation — match by customer_id OR by name OR by normalized
  -- phone/wa within the same shop. The OR clauses capture both legacy
  -- bills (NULL customer_id) and any future bills that fail to set the link.
  WITH bill_stats AS (
    SELECT
      COUNT(*) FILTER (WHERE COALESCE(b.voided_at, NULL) IS NULL AND COALESCE(b.status,'') <> 'voided')::int AS total_bills,
      COUNT(*) FILTER (WHERE b.voided_at IS NOT NULL OR b.status = 'voided')::int AS voided_bills,
      COALESCE(SUM(b.grand_total) FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_spent,
      COALESCE(SUM(b.paid_amount)  FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS total_paid,
      COALESCE(SUM(b.balance_due)  FILTER (WHERE b.voided_at IS NULL AND COALESCE(b.status,'') <> 'voided'), 0)::numeric AS balance_due,
      MIN(b.created_at) AS first_bill_at,
      MAX(b.created_at) AS last_bill_at
    FROM public.bills b
    WHERE b.shop_id = v_shop_id
      AND (
            b.customer_id = p_customer_id
         OR (b.customer_id IS NULL AND v_norm_name  IS NOT NULL AND lower(trim(COALESCE(b.customer_name,''))) = v_norm_name)
         OR (b.customer_id IS NULL AND v_norm_phone IS NOT NULL AND public.sbp_normalize_phone(b.customer_wa) = v_norm_phone)
         OR (b.customer_id IS NULL AND v_norm_wa    IS NOT NULL AND public.sbp_normalize_phone(b.customer_wa) = v_norm_wa)
          )
  ),
  appt_stats AS (
    SELECT
      COUNT(*)::int                                                  AS appointments_total,
      COUNT(*) FILTER (WHERE status = 'completed')::int              AS appointments_completed,
      COUNT(*) FILTER (WHERE status IN ('cancelled','no_show'))::int AS appointments_cancelled
    FROM public.sbp_appointments
    WHERE customer_id = p_customer_id
      AND shop_id     = v_shop_id
  ),
  loyalty_balance_calc AS (
    SELECT (points_earned - points_redeemed - points_expired)::int AS loyalty_balance
    FROM public.sbp_customer_loyalty
    WHERE shop_id = v_shop_id AND customer_id = p_customer_id
  )
  SELECT jsonb_build_object(
    'total_bills',            COALESCE(bs.total_bills, 0),
    'voided_bills',           COALESCE(bs.voided_bills, 0),
    'total_spent',            COALESCE(bs.total_spent, 0),
    'total_paid',             COALESCE(bs.total_paid, 0),
    'balance_due',            COALESCE(bs.balance_due, 0),
    'first_bill_at',          bs.first_bill_at,
    'last_bill_at',           bs.last_bill_at,
    'avg_ticket',             CASE WHEN COALESCE(bs.total_bills,0) > 0
                                   THEN ROUND(bs.total_spent / bs.total_bills, 2)
                                   ELSE 0 END,
    'appointments_total',     COALESCE(a.appointments_total, 0),
    'appointments_completed', COALESCE(a.appointments_completed, 0),
    'appointments_cancelled', COALESCE(a.appointments_cancelled, 0),
    'loyalty_balance',        COALESCE(lb.loyalty_balance, 0)
  )
  INTO v_stats
  FROM bill_stats bs
  LEFT JOIN appt_stats a   ON true
  LEFT JOIN loyalty_balance_calc lb ON true;

  -- Timeline events — same OR fallback for bills
  WITH events AS (
    SELECT 'bill'::text                AS type,
           b.created_at                AS event_at,
           jsonb_build_object(
             'id',           b.id,
             'invoice_no',   b.invoice_no,
             'invoice_date', b.invoice_date,
             'grand_total',  b.grand_total,
             'paid_amount',  b.paid_amount,
             'balance_due',  b.balance_due,
             'status',       b.status,
             'voided',       (b.voided_at IS NOT NULL OR b.status = 'voided')
           ) AS payload
      FROM public.bills b
     WHERE b.shop_id = v_shop_id
       AND (
             b.customer_id = p_customer_id
          OR (b.customer_id IS NULL AND v_norm_name  IS NOT NULL AND lower(trim(COALESCE(b.customer_name,''))) = v_norm_name)
          OR (b.customer_id IS NULL AND v_norm_phone IS NOT NULL AND public.sbp_normalize_phone(b.customer_wa) = v_norm_phone)
          OR (b.customer_id IS NULL AND v_norm_wa    IS NOT NULL AND public.sbp_normalize_phone(b.customer_wa) = v_norm_wa)
           )

    UNION ALL

    SELECT 'appointment'::text          AS type,
           a.created_at                AS event_at,
           jsonb_build_object(
             'id',         a.id,
             'service',    a.service_name,
             'scheduled',  a.scheduled_at,
             'status',     a.status
           ) AS payload
      FROM public.sbp_appointments a
     WHERE a.customer_id = p_customer_id
       AND a.shop_id     = v_shop_id

    UNION ALL

    SELECT 'registered'::text           AS type,
           v_customer.joined_at        AS event_at,
           jsonb_build_object(
             'name',        v_customer.name,
             'phone',       v_customer.phone,
             'customer_type', v_customer.customer_type
           ) AS payload
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('type', type, 'at', event_at, 'payload', payload)
                            ORDER BY event_at DESC), '[]'::jsonb)
  INTO v_timeline
  FROM events
  LIMIT 500;

  RETURN jsonb_build_object(
    'ok',       true,
    'customer', to_jsonb(v_customer),
    'stats',    v_stats,
    'timeline', v_timeline
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_get_customer_timeline(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 5. PATCH: sbp_salvage_orphan_hotel_bills — link-orphans first
-- ──────────────────────────────────────────────────────────────────
--
-- Wrap the existing salvage logic with a leading link-orphans pass so
-- bookings missing bill_id get reconnected before the salvage walks.
-- The salvage body itself is unchanged from migration 023; we just
-- add a PERFORM at the top to fuzzy-link first.

CREATE OR REPLACE FUNCTION public.sbp_salvage_orphan_hotel_bills(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check        jsonb;
  v_link_result  jsonb;
  v_total_bills  int := 0;
  v_fixed_bills  int := 0;
  v_total_items  int := 0;
  r_booking      record;
  r_extra        record;
  v_existing_cnt int;
  v_extras_cnt   int;
  v_room_gst     numeric;
  v_room_cgst    numeric;
  v_room_sgst    numeric;
  v_room_taxable numeric;
  v_room_total_w numeric;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- ── Pass 0: fuzzy-link orphan bookings → bills (Batch 021.5) ──
  v_link_result := public.sbp_link_orphan_hotel_bills(p_shop_id);

  -- ── Pass 1: salvage bookings that now have bill_id ──
  FOR r_booking IN
    SELECT b.*
      FROM public.sbp_bookings b
     WHERE b.shop_id = p_shop_id
       AND b.status  = 'checked_out'
       AND b.bill_id IS NOT NULL
  LOOP
    v_total_bills := v_total_bills + 1;

    SELECT COUNT(*) INTO v_extras_cnt FROM public.sbp_booking_extras WHERE booking_id = r_booking.id;
    SELECT COUNT(*) INTO v_existing_cnt FROM public.bill_items WHERE bill_id = r_booking.bill_id;
    IF v_existing_cnt = (1 + v_extras_cnt) THEN CONTINUE; END IF;

    IF v_existing_cnt > 0 THEN
      DELETE FROM public.bill_items WHERE bill_id = r_booking.bill_id;
      RAISE NOTICE 'Wiped % stale items from bill % to rebuild', v_existing_cnt, r_booking.bill_id;
    END IF;

    v_room_gst := public.sbp_hotel_room_gst_for_rate(r_booking.rate_per_night);
    v_room_taxable := r_booking.room_total;
    IF v_room_gst > 0 THEN
      v_room_cgst := ROUND((v_room_taxable * v_room_gst / 200.0)::numeric, 2);
      v_room_sgst := ROUND((v_room_taxable * v_room_gst / 100.0 - v_room_cgst)::numeric, 2);
    ELSE
      v_room_cgst := 0;
      v_room_sgst := 0;
    END IF;
    v_room_total_w := v_room_taxable + v_room_cgst + v_room_sgst;

    INSERT INTO public.bill_items (
      bill_id, item_name, qty, rate, gst_rate,
      discount, line_total, gst_amount,
      kind, room_type_id, booking_id, unit, qty_unit_label
    ) VALUES (
      r_booking.bill_id,
      'Room ' || COALESCE(r_booking.room_number_snapshot, '') ||
        CASE WHEN r_booking.room_type_snapshot IS NOT NULL
             THEN ' · ' || r_booking.room_type_snapshot ELSE '' END ||
        ' (' || r_booking.check_in_date || ' → ' || r_booking.check_out_date || ')',
      r_booking.num_nights,
      r_booking.rate_per_night,
      v_room_gst,
      0,
      v_room_total_w,
      v_room_cgst + v_room_sgst,
      'room',
      r_booking.room_type_id,
      r_booking.id,
      'night',
      r_booking.num_nights || ' night' || CASE WHEN r_booking.num_nights > 1 THEN 's' ELSE '' END
    );
    v_total_items := v_total_items + 1;

    FOR r_extra IN
      SELECT * FROM public.sbp_booking_extras WHERE booking_id = r_booking.id ORDER BY added_at ASC
    LOOP
      INSERT INTO public.bill_items (
        bill_id, item_name, qty, rate, gst_rate,
        discount, line_total, gst_amount,
        kind, booking_id
      ) VALUES (
        r_booking.bill_id,
        COALESCE(r_extra.description, 'Extra') ||
          CASE WHEN r_extra.category IS NOT NULL
               THEN ' (' || r_extra.category || ')' ELSE '' END,
        r_extra.qty,
        CASE WHEN r_extra.qty > 0 AND r_extra.taxable_amount IS NOT NULL
             THEN ROUND((r_extra.taxable_amount / r_extra.qty)::numeric, 2)
             ELSE r_extra.unit_price END,
        COALESCE(r_extra.gst_rate, 0),
        0,
        COALESCE(r_extra.total_with_gst, r_extra.amount),
        COALESCE(r_extra.cgst_amount, 0) + COALESCE(r_extra.sgst_amount, 0),
        CASE WHEN lower(COALESCE(r_extra.category, '')) IN ('service','spa','laundry','salon','massage','transport','tour')
             THEN 'service' ELSE 'product' END,
        r_booking.id
      );
      v_total_items := v_total_items + 1;
    END LOOP;

    v_fixed_bills := v_fixed_bills + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',                         true,
    'link_pass',                  v_link_result,
    'total_checked_out_bookings', v_total_bills,
    'bills_salvaged',             v_fixed_bills,
    'items_inserted',             v_total_items
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_salvage_orphan_hotel_bills(uuid) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- 6. Auto-run for all shops (idempotent)
-- ──────────────────────────────────────────────────────────────────
--
-- Backfill customer_id for ALL shops (not just hospitality — every
-- vertical benefits). Then run hotel-specific link + salvage for
-- hospitality shops only.

DO $$
DECLARE
  r record;
  v_bf jsonb;
  v_lk jsonb;
  v_sv jsonb;
BEGIN
  -- Backfill customer_id across all shops
  FOR r IN SELECT id, shop_type FROM public.shops LOOP
    BEGIN
      v_bf := public.sbp_backfill_bills_customer_id(r.id);
      IF (v_bf->>'resolved')::int > 0 THEN
        RAISE NOTICE '[backfill] shop % (type=%) — resolved % of % NULL bills',
          r.id, r.shop_type, (v_bf->>'resolved')::int, (v_bf->>'total_null')::int;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '[backfill] shop % skipped: %', r.id, SQLERRM;
    END;
  END LOOP;

  -- Hotel link + salvage for hospitality shops only
  FOR r IN
    SELECT id, shop_type FROM public.shops
     WHERE shop_type IN ('hotel','resort','guesthouse','service_apartment',
                         'boutique_hotel','hostel','day_room')
  LOOP
    BEGIN
      v_lk := public.sbp_link_orphan_hotel_bills(r.id);
      IF (v_lk->>'linked')::int > 0 THEN
        RAISE NOTICE '[link-orphan] shop % — linked % of % orphan bookings',
          r.id, (v_lk->>'linked')::int, (v_lk->>'total_orphan')::int;
      END IF;

      v_sv := public.sbp_salvage_orphan_hotel_bills(r.id);
      IF (v_sv->>'bills_salvaged')::int > 0 THEN
        RAISE NOTICE '[salvage] shop % — salvaged % bills, % items inserted',
          r.id, (v_sv->>'bills_salvaged')::int, (v_sv->>'items_inserted')::int;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '[hotel-pass] shop % skipped: %', r.id, SQLERRM;
    END;
  END LOOP;
END $$;


-- ──────────────────────────────────────────────────────────────────
-- 7. Verification queries (run manually after migration)
-- ──────────────────────────────────────────────────────────────────

-- (1) Confirm next_invoice_no no longer errors:
--   SELECT * FROM public.next_invoice_no(
--     (SELECT id FROM public.shops WHERE shop_type = 'day_room' LIMIT 1)
--   );
--   Expected: one row, e.g. (invoice_prefix='GG', invoice_counter=77)

-- (2) Confirm backfill resolved Glitz & Glam bills:
--   SELECT COUNT(*) AS still_null FROM public.bills
--    WHERE shop_id = (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
--      AND customer_id IS NULL;
--   Expected: 0 (or near-0; unresolvable bills with empty customer_name will remain)

-- (3) Confirm Jyoti's timeline now shows bills (assuming Jyoti exists):
--   SELECT public.sbp_get_customer_timeline(
--     (SELECT id FROM public.customers WHERE lower(trim(name))='jyoti' LIMIT 1)
--   );
--   Expected: stats.total_bills > 0, stats.total_spent > 0

-- (4) Confirm orphan bookings linked:
--   SELECT public.sbp_link_orphan_hotel_bills(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1)
--   );
--   Expected (second run): { ok: true, total_orphan: 0, linked: 0, ... }

-- ──────────────── End of 025_bills_integrity.sql ────────────────
