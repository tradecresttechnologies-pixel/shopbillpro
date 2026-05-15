-- ════════════════════════════════════════════════════════════════════
-- 059_custom_domain.sql
--
-- Enables custom domain support for AI-generated shop websites.
-- Shop owners on Business plan can connect their own domain
-- (e.g. glitzglamhotel.com) to their ShopBill Pro AI website.
--
-- Adds:
--   1. custom_domain columns on sbp_shop_websites
--   2. sbp_resolve_shop_by_domain(domain) — public, used by domain-router.html
--   3. sbp_connect_custom_domain(domain) — authenticated, saves + validates
--   4. sbp_check_custom_domain_status()  — authenticated, polls Vercel status
--   5. sbp_disconnect_custom_domain()    — authenticated, removes domain
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Add custom domain columns ────────────────────────────────────

ALTER TABLE sbp_shop_websites
  ADD COLUMN IF NOT EXISTS custom_domain           text,
  ADD COLUMN IF NOT EXISTS custom_domain_status    text DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS custom_domain_added_at  timestamptz,
  ADD COLUMN IF NOT EXISTS custom_domain_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS custom_domain_vercel_id text;

-- Unique constraint: each domain can only be connected to one shop
CREATE UNIQUE INDEX IF NOT EXISTS idx_sbp_shop_websites_custom_domain
  ON sbp_shop_websites (custom_domain)
  WHERE custom_domain IS NOT NULL
    AND custom_domain_status NOT IN ('none','removed');

-- ── 2. sbp_resolve_shop_by_domain ───────────────────────────────────
-- Public RPC — called from domain-router.html by anonymous visitors.
-- Looks up the shop connected to a custom domain and delegates
-- resolution to sbp_resolve_shop_slug (reuses all existing logic).

DROP FUNCTION IF EXISTS sbp_resolve_shop_by_domain(text);

CREATE OR REPLACE FUNCTION sbp_resolve_shop_by_domain(p_domain text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_slug    text;
  v_clean   text;
BEGIN
  -- Strip www. prefix and lowercase
  v_clean := lower(trim(
    regexp_replace(p_domain, '^www\.', '')
  ));

  IF v_clean = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'empty_domain');
  END IF;

  -- Find the shop connected to this domain (must be active + published)
  SELECT w.slug INTO v_slug
  FROM sbp_shop_websites w
  WHERE (w.custom_domain = v_clean OR w.custom_domain = 'www.' || v_clean)
    AND w.custom_domain_status = 'active'
    AND (
      COALESCE(w.ai_published, false) = true
      AND w.ai_generated_html IS NOT NULL
      AND length(w.ai_generated_html) > 50
    )
  LIMIT 1;

  IF v_slug IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'domain_not_found', 'domain', v_clean);
  END IF;

  -- Delegate to the slug resolver — reuses all existing logic
  RETURN sbp_resolve_shop_slug(v_slug);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_resolve_shop_by_domain(text)
  TO anon, authenticated, service_role;


-- ── 3. sbp_connect_custom_domain ────────────────────────────────────
-- Authenticated. Validates the domain, checks Business plan, saves to DB.
-- The frontend then calls the manage-domain edge function to add it to Vercel.

DROP FUNCTION IF EXISTS sbp_connect_custom_domain(text);

CREATE OR REPLACE FUNCTION sbp_connect_custom_domain(p_domain text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id  uuid;
  v_plan     text;
  v_clean    text;
  v_taken_by uuid;
BEGIN
  -- Get caller's shop
  SELECT s.id, COALESCE(s.plan, 'free') INTO v_shop_id, v_plan
  FROM shops s WHERE s.owner_id = auth.uid() LIMIT 1;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop');
  END IF;

  -- Business plan required
  IF v_plan NOT IN ('business', 'enterprise') THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'business_plan_required',
      'message', 'Custom domains require the Business plan (₹499/mo).'
    );
  END IF;

  -- Must have an AI-published website first
  IF NOT EXISTS (
    SELECT 1 FROM sbp_shop_websites
    WHERE shop_id = v_shop_id
      AND COALESCE(ai_published, false) = true
      AND ai_generated_html IS NOT NULL
  ) THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'no_website',
      'message', 'Generate and publish your AI website first before connecting a domain.'
    );
  END IF;

  -- Clean + validate domain format
  v_clean := lower(trim(p_domain));
  v_clean := regexp_replace(v_clean, '^https?://', '');
  v_clean := regexp_replace(v_clean, '/.*$', '');
  v_clean := regexp_replace(v_clean, '^www\.', '');

  IF v_clean = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'empty_domain');
  END IF;

  -- Basic format: letters, digits, hyphens, dots. At least one dot.
  IF v_clean !~ '^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$' THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'invalid_domain',
      'message', 'Enter a valid domain like "mybusiness.com" (without http or www).'
    );
  END IF;

  -- Reject shopbillpro.in domains
  IF v_clean LIKE '%shopbillpro.in' OR v_clean LIKE '%shopbillpro.com' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'reserved_domain');
  END IF;

  -- Check not taken by another shop
  SELECT w.shop_id INTO v_taken_by
  FROM sbp_shop_websites w
  WHERE (w.custom_domain = v_clean OR w.custom_domain = 'www.' || v_clean)
    AND w.shop_id != v_shop_id
    AND w.custom_domain_status NOT IN ('none', 'removed')
  LIMIT 1;

  IF v_taken_by IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'error', 'domain_already_in_use',
      'message', 'This domain is already connected to another shop.'
    );
  END IF;

  -- Save with pending status
  UPDATE sbp_shop_websites
  SET custom_domain           = v_clean,
      custom_domain_status    = 'pending_vercel',
      custom_domain_added_at  = now(),
      custom_domain_verified_at = NULL,
      custom_domain_vercel_id   = NULL
  WHERE shop_id = v_shop_id;

  RETURN jsonb_build_object(
    'ok',     true,
    'domain', v_clean,
    'status', 'pending_vercel'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_connect_custom_domain(text)
  TO authenticated, service_role;


-- ── 4. sbp_update_custom_domain_status ──────────────────────────────
-- Called by the manage-domain edge function after Vercel API responds.
-- Updates status + vercel_id in DB.

DROP FUNCTION IF EXISTS sbp_update_custom_domain_status(uuid, text, text, text);

CREATE OR REPLACE FUNCTION sbp_update_custom_domain_status(
  p_shop_id   uuid,
  p_domain    text,
  p_status    text,   -- 'pending_dns' | 'active' | 'failed' | 'removed'
  p_vercel_id text    DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  UPDATE sbp_shop_websites
  SET custom_domain_status     = p_status,
      custom_domain_vercel_id  = COALESCE(p_vercel_id, custom_domain_vercel_id),
      custom_domain_verified_at = CASE WHEN p_status = 'active' THEN now() ELSE custom_domain_verified_at END
  WHERE shop_id = p_shop_id
    AND custom_domain = p_domain;

  RETURN jsonb_build_object('ok', true, 'status', p_status);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_update_custom_domain_status(uuid, text, text, text)
  TO service_role;


-- ── 5. sbp_get_custom_domain_info ───────────────────────────────────
-- Returns current domain status for the builder UI.

DROP FUNCTION IF EXISTS sbp_get_custom_domain_info();

CREATE OR REPLACE FUNCTION sbp_get_custom_domain_info()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
  v_row record;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop');
  END IF;

  SELECT custom_domain, custom_domain_status, custom_domain_added_at,
         custom_domain_verified_at
    INTO v_row
  FROM sbp_shop_websites WHERE shop_id = v_shop_id LIMIT 1;

  RETURN jsonb_build_object(
    'ok',           true,
    'shop_id',      v_shop_id,
    'domain',       v_row.custom_domain,
    'status',       COALESCE(v_row.custom_domain_status, 'none'),
    'added_at',     v_row.custom_domain_added_at,
    'verified_at',  v_row.custom_domain_verified_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_custom_domain_info()
  TO authenticated, service_role;


-- ── 6. sbp_disconnect_custom_domain ─────────────────────────────────
-- Owner removes their custom domain. Marks as removed in DB.
-- Frontend calls manage-domain edge function to remove from Vercel.

DROP FUNCTION IF EXISTS sbp_disconnect_custom_domain();

CREATE OR REPLACE FUNCTION sbp_disconnect_custom_domain()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_shop_id uuid;
  v_domain  text;
BEGIN
  SELECT s.id INTO v_shop_id
  FROM shops s WHERE s.owner_id = auth.uid() LIMIT 1;

  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_shop');
  END IF;

  SELECT custom_domain INTO v_domain
  FROM sbp_shop_websites WHERE shop_id = v_shop_id LIMIT 1;

  IF v_domain IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_domain_connected');
  END IF;

  UPDATE sbp_shop_websites
  SET custom_domain_status = 'removed',
      custom_domain_verified_at = NULL
  WHERE shop_id = v_shop_id;

  RETURN jsonb_build_object('ok', true, 'domain', v_domain);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_disconnect_custom_domain()
  TO authenticated, service_role;


NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--
--   SELECT column_name, data_type
--   FROM information_schema.columns
--   WHERE table_name = 'sbp_shop_websites'
--     AND column_name LIKE 'custom_domain%'
--   ORDER BY column_name;
--   -- Should show 5 custom_domain* columns
--
--   SELECT sbp_resolve_shop_by_domain('glitzglamhotel.com');
--   -- Returns {ok:false, error:'domain_not_found'} (no domain connected yet)
--
--   SELECT sbp_get_custom_domain_info();
--   -- Returns current domain info for your test shop
-- ════════════════════════════════════════════════════════════════════
