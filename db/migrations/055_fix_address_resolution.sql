-- ════════════════════════════════════════════════════════════════════
-- 055_fix_address_resolution.sql
--
-- THE BUG:
--   The website builder's "Save All" writes the shop address to the
--   `shops` table (shops.address). But sbp_resolve_shop_slug — and the
--   content_json blob it returns — was reading address from
--   content_json.address, which the builder never populated.
--
--   Result: the public site's info card showed content_json.city
--   ("Gorakhp", stale truncated data) instead of the real address.
--
-- THIS FIX:
--   1. Rewrites sbp_resolve_shop_slug so the merged content object
--      prefers a NON-EMPTY value in this priority order:
--        address  → shops.address, then content_json.address
--        city     → shops.city,    then content_json.city
--        phone    → shops.phone,   then content_json.phone
--        whatsapp → shops.wa,      then content_json.whatsapp
--        email    → shops.email,   then content_json.email
--      Empty strings are treated as "missing" so they never override
--      a real value.
--
--   2. One-time data backfill: copies shops.address/city into
--      content_json for shops that have a real address but empty
--      content_json.address. Keeps the two stores in sync going forward
--      (the builder fix in website-builder.html also writes both).
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Rewrite sbp_resolve_shop_slug with proper address merge ──────

DROP FUNCTION IF EXISTS sbp_resolve_shop_slug(text);

CREATE OR REPLACE FUNCTION sbp_resolve_shop_slug(p_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_row record;
  v_merged jsonb;
BEGIN
  SELECT
    w.id                 AS website_id,
    w.shop_id,
    w.slug,
    w.published          AS legacy_published,
    w.ai_published,
    w.ai_generated_html,
    w.content_json,
    w.updated_at,
    s.name               AS shop_name,
    s.shop_type,
    s.phone              AS shop_phone,
    s.wa                 AS shop_wa,
    s.email              AS shop_email,
    s.city               AS shop_city,
    s.address            AS shop_address,
    s.plan               AS shop_plan
  INTO v_row
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = p_slug
    AND (
      COALESCE(w.published, false) = true
      OR (COALESCE(w.ai_published, false) = true AND w.ai_generated_html IS NOT NULL)
    )
  LIMIT 1;

  IF v_row.website_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found', 'slug', p_slug);
  END IF;

  -- Build merged content. Strategy:
  --   start with content_json (legacy fields the builder DOES write:
  --   about, tagline, hours, gallery, upi, etc.)
  --   then OVERRIDE the contact fields with shops.* values when those
  --   are non-empty. nullif(x,'') turns empty strings into NULL so
  --   jsonb_strip_nulls drops them and they don't clobber good data.
  v_merged := COALESCE(v_row.content_json, '{}'::jsonb)
    || jsonb_strip_nulls(jsonb_build_object(
         'name',     v_row.shop_name,
         'address',  NULLIF(trim(COALESCE(v_row.shop_address, '')), ''),
         'city',     NULLIF(trim(COALESCE(v_row.shop_city, '')), ''),
         'phone',    NULLIF(trim(COALESCE(v_row.shop_phone, '')), ''),
         'whatsapp', NULLIF(trim(COALESCE(v_row.shop_wa, '')), ''),
         'email',    NULLIF(trim(COALESCE(v_row.shop_email, '')), '')
       ));

  -- If after the merge address is still missing/empty, make sure we do
  -- NOT leave a bare city sitting in the 'address' slot. The info-card
  -- renderer should show whatever 'address' holds; an empty string is
  -- fine (component will skip the row) — a wrong value is not.
  IF NULLIF(trim(COALESCE(v_merged->>'address','')), '') IS NULL THEN
    v_merged := v_merged || jsonb_build_object('address', '');
  END IF;

  RETURN jsonb_build_object(
    'ok',        true,
    'shop_name', v_row.shop_name,
    'slug',      v_row.slug,
    'shop_id',   v_row.shop_id,
    'shop_type', v_row.shop_type,
    'plan',      v_row.shop_plan,
    'ai_mode',   (COALESCE(v_row.ai_published, false) = true
                  AND v_row.ai_generated_html IS NOT NULL),
    'ai_html',   v_row.ai_generated_html,
    'content',   v_merged,
    'updated_at', v_row.updated_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_resolve_shop_slug(text)
  TO anon, authenticated, service_role;


-- ── 2. One-time backfill: sync shops.address → content_json ─────────
-- For any shop website whose content_json.address is empty/missing but
-- the shops table has a real address, copy it across. This keeps both
-- stores consistent (the website-builder.html fix writes both going
-- forward; this catches shops saved before that fix).

UPDATE sbp_shop_websites w
SET content_json = COALESCE(w.content_json, '{}'::jsonb)
  || jsonb_build_object(
       'address', COALESCE(s.address, ''),
       'city',    COALESCE(s.city, '')
     )
FROM shops s
WHERE s.id = w.shop_id
  AND COALESCE(trim(s.address), '') <> ''
  AND COALESCE(trim(w.content_json->>'address'), '') = '';


NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--
--   -- Should now return address from shops.address, not stale city
--   SELECT sbp_resolve_shop_slug('glitz-glam') -> 'content' ->> 'address';
--
--   -- Full content object
--   SELECT jsonb_pretty(sbp_resolve_shop_slug('glitz-glam') -> 'content');
--
-- If Glitz & Glam still shows empty address, run the manual patch:
--   UPDATE shops SET address='Cinema Road, Near Golghar', city='Gorakhpur'
--   WHERE id='73aa8ede-6352-4549-8617-cccacdd5c821';
--   -- then re-run this migration's backfill (section 2) or just re-run
--   -- the whole file (it's idempotent).
-- ════════════════════════════════════════════════════════════════════
