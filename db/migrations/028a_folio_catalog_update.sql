-- ════════════════════════════════════════════════════════════════════
-- 028a_folio_catalog_update.sql
-- Batch 022A v2 follow-up — adds catalog update RPC (9 May 2026)
--
-- The original 028 migration shipped _list / _add / _remove for the
-- extras catalog but missed the _update RPC. Without it, fixing a
-- catalog item's price required removing + re-adding (which loses the
-- display_order). This RPC closes the gap so the folio.html edit
-- button can persist catalog changes properly.
--
-- Idempotent. Safe to re-run.
-- Prerequisites: 028_folio_management.sql must have run.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.sbp_folio_extras_catalog_update(
  p_shop_id uuid,
  p_id      uuid,
  p_data    jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_check jsonb;
  v_count int;
  v_cat   text;
BEGIN
  v_check := sbp_check_hospitality_owner(p_shop_id);
  IF NOT (v_check->>'ok')::boolean THEN RETURN v_check; END IF;

  -- Validate category if provided
  IF p_data ? 'category' THEN
    v_cat := p_data->>'category';
    IF v_cat NOT IN ('food','laundry','minibar','service','telephone','transport','spa','other') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_category');
    END IF;
  END IF;

  -- Validate description if provided
  IF p_data ? 'description' AND length(trim(COALESCE(p_data->>'description',''))) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'description_required');
  END IF;

  -- Update only the fields supplied; leave others untouched. COALESCE
  -- lets us partial-update without nuking unspecified columns.
  UPDATE public.sbp_folio_extras_catalog
     SET category           = COALESCE(p_data->>'category', category),
         description        = COALESCE(NULLIF(trim(p_data->>'description'),''), description),
         default_qty        = COALESCE((p_data->>'default_qty')::int, default_qty),
         default_unit_price = COALESCE((p_data->>'default_unit_price')::numeric, default_unit_price),
         display_order      = COALESCE((p_data->>'display_order')::int, display_order)
   WHERE id      = p_id
     AND shop_id = p_shop_id
     AND active  = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'item_not_found_or_inactive');
  END IF;

  RETURN jsonb_build_object('ok', true, 'updated', v_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sbp_folio_extras_catalog_update(uuid, uuid, jsonb) TO authenticated;

-- Verification:
--   SELECT public.sbp_folio_extras_catalog_update(
--     (SELECT id FROM public.shops WHERE shop_type='day_room' LIMIT 1),
--     (SELECT id FROM public.sbp_folio_extras_catalog LIMIT 1),
--     '{"default_unit_price": 200}'::jsonb
--   );
