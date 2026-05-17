-- ════════════════════════════════════════════════════════════════════
-- 069_table_occupancy_sync.sql
-- ════════════════════════════════════════════════════════════════════
-- PROBLEM
--   sbp_tables_list returned the raw sbp_restaurant_tables.status flag
--   with zero awareness of running orders. A table could carry an OPEN
--   running order (items punched, ₹ on the table) while the status flag
--   said 'free' — e.g. after a manual Mark-Free / Reserve / Cleaning tap,
--   which by design does NOT void the running order. Result: occupied
--   tables showed as Free on the floor screen. (Observed: T10, ₹2,362,
--   8 items, KOT 1, open 33h — displayed "Free · Tap to seat guests".)
--
-- HOW REAL POS WORKS (Petpooja / Posist / Toast / Square)
--   Occupancy is DERIVED from the open check, never a free-floating flag.
--   Punch first item → table is occupied. Settle/void the bill → free.
--   The floor tile shows running total + time-on-table + guest, live.
--
-- FIX (read-time derivation — non-destructive, backward compatible)
--   sbp_tables_list now LEFT JOIN LATERAL the latest OPEN running order
--   per table and returns:
--     • status          → 'occupied' whenever an open RO exists,
--                          otherwise the stored manual flag (reserved/
--                          cleaning/free). An open check ALWAYS wins.
--     • stored_status   → the raw flag, kept for reference/debugging.
--     • order           → { order_id, items_count, kot_count, total,
--                            opened_at, guest_name } or null.
--   The stored status column is never written here, so nothing is
--   wiped and every existing flow keeps working. Drift heals itself
--   on the next list call.
--
-- TOTAL MATH
--   Mirrors the running-order tile: per active line,
--     price × (qty − voided_qty) × (1 + gst_rate/100)
--   This is an at-a-glance figure; the authoritative bill is still
--   computed at billing time.
-- ════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS sbp_tables_list(uuid);

CREATE OR REPLACE FUNCTION sbp_tables_list(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
BEGIN
  IF NOT public._sbp_check_shop_owner(p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authorized');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'tables', COALESCE((
      SELECT jsonb_agg(row_json ORDER BY ord_disp ASC, ord_num ASC)
      FROM (
        SELECT
          t.display_order AS ord_disp,
          t.table_number  AS ord_num,
          (
            -- base table row
            to_jsonb(t)
            -- keep the raw flag visible
            || jsonb_build_object('stored_status', t.status)
            -- effective status: an open running order forces 'occupied'
            || jsonb_build_object(
                 'status',
                 CASE WHEN ro.id IS NOT NULL THEN 'occupied' ELSE t.status END
               )
            -- order summary (null when no open running order)
            || jsonb_build_object(
                 'order',
                 CASE WHEN ro.id IS NULL THEN NULL ELSE jsonb_build_object(
                   'order_id',     ro.id,
                   'opened_at',    ro.opened_at,
                   'kot_count',    ro.kot_count,
                   'items_count',  ro.items_count,
                   'total',        ro.total,
                   'guest_name',   ro.guest_name
                 ) END
               )
          ) AS row_json
        FROM sbp_restaurant_tables t
        LEFT JOIN LATERAL (
          SELECT
            r.id,
            r.opened_at,
            r.kot_count,
            COALESCE(r.notes, '')                              AS notes_raw,
            -- net unit count across all rounds (qty − voided_qty)
            COALESCE((
              SELECT SUM(GREATEST(
                COALESCE((e->>'qty')::numeric, 0)
                - COALESCE((e->>'voided_qty')::numeric, 0), 0))
              FROM jsonb_array_elements(r.items) e
            ), 0)::int                                         AS items_count,
            -- ₹ total incl. per-line GST (matches the RO panel)
            COALESCE((
              SELECT SUM(
                COALESCE((e->>'price')::numeric, 0)
                * GREATEST(
                    COALESCE((e->>'qty')::numeric, 0)
                    - COALESCE((e->>'voided_qty')::numeric, 0), 0)
                * (1 + COALESCE((e->>'gst_rate')::numeric, 0) / 100.0)
              )
              FROM jsonb_array_elements(r.items) e
            ), 0)::numeric(12,2)                               AS total,
            -- best-effort guest label: explicit guest_name key on the
            -- order row's first item, else null (column may not exist
            -- on legacy rows — extracted defensively via to_jsonb).
            NULLIF(trim(
              COALESCE(
                (to_jsonb(r) ->> 'guest_name'),
                ''
              )
            ), '')                                             AS guest_name
          FROM sbp_running_orders r
          WHERE r.shop_id  = p_shop_id
            AND r.table_id = t.id
            AND r.status   = 'open'
          ORDER BY r.opened_at DESC
          LIMIT 1
        ) ro ON true
        WHERE t.shop_id = p_shop_id
          AND t.active  = true
      ) q
    ), '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_tables_list(uuid) TO authenticated;

-- PostgREST schema cache reload (permanent rule)
NOTIFY pgrst, 'reload schema';
