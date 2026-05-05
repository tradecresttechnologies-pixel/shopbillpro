-- ════════════════════════════════════════════════════════════════════
-- 008_public_shop_page.sql
-- Public Shop Page MVP — Free single-page profile at /s/[slug]
--
-- Master Plan v1.1 reference:
--   Section 3.4 Pillar 2 — Public Shop Page (viral acquisition channel)
--   Section 6.4 — URL Architecture (path-based, smart slug system)
--   Section 6.7 — Caching strategy (5-min Vercel edge TTL)
--
-- ACTUAL shops table columns used:
--   id, owner_id, name, tag (tagline), owner_name, phone, wa,
--   email, address, city, gstin, upi, shop_type, plan
--
-- IDEMPOTENT — safe to re-run.
-- Deploy after: 007_pricing_fix.sql
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Tables ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sbp_shop_websites (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         uuid NOT NULL UNIQUE REFERENCES shops(id) ON DELETE CASCADE,
  slug            text NOT NULL UNIQUE,
  content_json    jsonb NOT NULL DEFAULT '{}'::jsonb,
  design_tokens   jsonb NOT NULL DEFAULT '{}'::jsonb,
  template_id     uuid,
  custom_domain   text,
  published       boolean NOT NULL DEFAULT true,
  slug_changed_at timestamptz,
  view_count      integer NOT NULL DEFAULT 0,
  whatsapp_clicks integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sbp_slug_redirects (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  old_slug      text NOT NULL UNIQUE,
  shop_id       uuid NOT NULL REFERENCES shops(id) ON DELETE CASCADE,
  expires_at    timestamptz NOT NULL DEFAULT (now() + interval '12 months'),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sbp_reserved_slugs (
  slug text PRIMARY KEY,
  reason text DEFAULT 'system'
);

INSERT INTO sbp_reserved_slugs(slug, reason) VALUES
  ('admin','system'),('api','system'),('app','system'),('login','system'),
  ('signup','system'),('logout','system'),('register','system'),
  ('pricing','public'),('plans','public'),('blog','public'),('about','public'),
  ('contact','public'),('support','public'),('help','public'),('docs','public'),
  ('terms','public'),('privacy','public'),('refund','public'),('refunds','public'),
  ('legal','public'),('faq','public'),('press','public'),('careers','public'),
  ('jobs','public'),('investors','public'),('partners','public'),
  ('settings','system'),('dashboard','system'),('billing','system'),('bills','system'),
  ('reports','system'),('stock','system'),('inventory','system'),('customers','system'),
  ('marketing','system'),('whatsapp','system'),('cash','system'),
  ('supplier','system'),('suppliers','system'),('recurring','system'),('templates','system'),
  ('team','system'),('users','system'),('subscription','system'),('wa','system'),
  ('pos','system'),('khata','system'),('ledger','system'),('cart','system'),
  ('checkout','system'),('pay','system'),('payments','system'),('payment','system'),
  ('order','system'),('orders','system'),('invoice','system'),('invoices','system'),
  ('product','system'),('products','system'),('category','system'),('categories','system'),
  ('search','system'),('explore','system'),('discover','system'),('home','system'),
  ('index','system'),('main','system'),('default','system'),('null','system'),
  ('undefined','system'),('test','system'),('demo','system'),('sample','system'),
  ('shopbillpro','brand'),('shopbill','brand'),('tradecrest','brand'),
  ('apple','trademark'),('google','trademark'),('microsoft','trademark'),
  ('tata','trademark'),('reliance','trademark'),('amazon','trademark'),
  ('flipkart','trademark'),('paytm','trademark'),('phonepe','trademark'),
  ('razorpay','trademark'),('vyapar','trademark'),('khatabook','trademark'),
  ('mybillbook','trademark'),('zoho','trademark')
ON CONFLICT (slug) DO NOTHING;

-- ── 2. Indexes ─────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_sbp_shop_websites_slug ON sbp_shop_websites(slug);
CREATE INDEX IF NOT EXISTS idx_sbp_shop_websites_shop_id ON sbp_shop_websites(shop_id);
CREATE INDEX IF NOT EXISTS idx_sbp_shop_websites_published ON sbp_shop_websites(published) WHERE published = true;
CREATE INDEX IF NOT EXISTS idx_sbp_slug_redirects_old_slug ON sbp_slug_redirects(old_slug);

-- ── 3. Updated_at trigger ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_shop_websites_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sbp_shop_websites_updated_at ON sbp_shop_websites;
CREATE TRIGGER trg_sbp_shop_websites_updated_at
  BEFORE UPDATE ON sbp_shop_websites
  FOR EACH ROW EXECUTE FUNCTION sbp_shop_websites_set_updated_at();

-- ── 4. Slug generation function ────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_generate_slug(p_shop_name text, p_city text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_base text;
  v_slug text;
  v_suffix text;
  v_attempt int := 0;
BEGIN
  v_base := lower(trim(coalesce(p_shop_name, 'shop')));
  v_base := regexp_replace(v_base, '[^a-z0-9]+', '-', 'g');
  v_base := regexp_replace(v_base, '-+', '-', 'g');
  v_base := trim(both '-' from v_base);

  IF length(v_base) < 4 THEN
    v_base := v_base || '-shop';
  END IF;

  IF length(v_base) > 40 THEN
    v_base := substring(v_base from 1 for 40);
    v_base := trim(both '-' from v_base);
  END IF;

  v_slug := v_base;
  IF NOT EXISTS (SELECT 1 FROM sbp_shop_websites WHERE slug = v_slug)
     AND NOT EXISTS (SELECT 1 FROM sbp_reserved_slugs WHERE slug = v_slug)
     AND NOT EXISTS (SELECT 1 FROM sbp_slug_redirects WHERE old_slug = v_slug AND expires_at > now()) THEN
    RETURN v_slug;
  END IF;

  IF p_city IS NOT NULL AND length(trim(p_city)) > 0 THEN
    v_suffix := lower(regexp_replace(trim(p_city), '[^a-z0-9]+', '-', 'g'));
    v_suffix := regexp_replace(v_suffix, '-+', '-', 'g');
    v_suffix := trim(both '-' from v_suffix);
    IF length(v_suffix) > 0 THEN
      v_slug := v_base || '-' || v_suffix;
      IF length(v_slug) > 40 THEN
        v_slug := substring(v_slug from 1 for 40);
        v_slug := trim(both '-' from v_slug);
      END IF;
      IF NOT EXISTS (SELECT 1 FROM sbp_shop_websites WHERE slug = v_slug)
         AND NOT EXISTS (SELECT 1 FROM sbp_reserved_slugs WHERE slug = v_slug)
         AND NOT EXISTS (SELECT 1 FROM sbp_slug_redirects WHERE old_slug = v_slug AND expires_at > now()) THEN
        RETURN v_slug;
      END IF;
    END IF;
  END IF;

  WHILE v_attempt < 5 LOOP
    v_attempt := v_attempt + 1;
    v_suffix := substr(md5(random()::text || clock_timestamp()::text), 1, 4);
    v_slug := v_base || '-' || v_suffix;
    IF length(v_slug) > 40 THEN
      v_slug := substring(v_slug from 1 for 40);
      v_slug := trim(both '-' from v_slug);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sbp_shop_websites WHERE slug = v_slug)
       AND NOT EXISTS (SELECT 1 FROM sbp_reserved_slugs WHERE slug = v_slug)
       AND NOT EXISTS (SELECT 1 FROM sbp_slug_redirects WHERE old_slug = v_slug AND expires_at > now()) THEN
      RETURN v_slug;
    END IF;
  END LOOP;

  RETURN 'shop-' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
END;
$$;

-- ── 5. Default content builder ─────────────────────────────────────────
-- Uses ACTUAL shops columns: name, tag, address, city, phone, wa, email,
-- gstin, upi, shop_type

CREATE OR REPLACE FUNCTION sbp_default_website_content(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_shop record;
  v_content jsonb;
BEGIN
  SELECT
    s.name, s.tag, s.address, s.city, s.phone, s.wa, s.email,
    s.gstin, s.upi, s.shop_type
  INTO v_shop
  FROM shops s
  WHERE s.id = p_shop_id;

  IF NOT FOUND THEN
    RETURN '{}'::jsonb;
  END IF;

  v_content := jsonb_build_object(
    'name', coalesce(v_shop.name, 'Shop'),
    'tagline', coalesce(v_shop.tag, ''),
    'address', coalesce(v_shop.address, ''),
    'city', coalesce(v_shop.city, ''),
    'phone', coalesce(v_shop.phone, ''),
    'whatsapp', coalesce(v_shop.wa, v_shop.phone, ''),
    'email', coalesce(v_shop.email, ''),
    'gst_number', coalesce(v_shop.gstin, ''),
    'upi', coalesce(v_shop.upi, ''),
    'shop_type', coalesce(v_shop.shop_type, ''),
    'hours', '',
    'photo_url', '',
    'services', '[]'::jsonb,
    'show_powered_by', true
  );

  RETURN v_content;
END;
$$;

-- ── 6. Public-facing view ──────────────────────────────────────────────

CREATE OR REPLACE VIEW sbp_public_shop_websites AS
SELECT
  w.slug,
  w.content_json,
  w.design_tokens,
  w.published,
  w.updated_at,
  s.name AS shop_name,
  s.shop_type,
  s.plan
FROM sbp_shop_websites w
JOIN shops s ON s.id = w.shop_id
WHERE w.published = true;

GRANT SELECT ON sbp_public_shop_websites TO anon;
GRANT SELECT ON sbp_public_shop_websites TO authenticated;
GRANT SELECT ON sbp_slug_redirects TO anon;
GRANT SELECT ON sbp_slug_redirects TO authenticated;
GRANT SELECT ON sbp_reserved_slugs TO anon;
GRANT SELECT ON sbp_reserved_slugs TO authenticated;

-- ── 7. RLS on the main table ───────────────────────────────────────────

ALTER TABLE sbp_shop_websites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_websites_owner_select ON sbp_shop_websites;
CREATE POLICY p_websites_owner_select ON sbp_shop_websites
  FOR SELECT TO authenticated
  USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
  );

DROP POLICY IF EXISTS p_websites_owner_update ON sbp_shop_websites;
CREATE POLICY p_websites_owner_update ON sbp_shop_websites
  FOR UPDATE TO authenticated
  USING (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
  )
  WITH CHECK (
    shop_id IN (SELECT id FROM shops WHERE owner_id = auth.uid())
  );

-- ── 8. Slug-claim RPC ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_change_shop_slug(
  p_shop_id uuid,
  p_new_slug text,
  p_force boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_current record;
  v_clean text;
  v_caller_owner boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()
  ) INTO v_caller_owner;

  IF NOT v_caller_owner THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  v_clean := lower(trim(coalesce(p_new_slug, '')));
  v_clean := regexp_replace(v_clean, '[^a-z0-9]+', '-', 'g');
  v_clean := regexp_replace(v_clean, '-+', '-', 'g');
  v_clean := trim(both '-' from v_clean);

  IF length(v_clean) < 4 OR length(v_clean) > 40 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slug_length_invalid');
  END IF;

  IF EXISTS (SELECT 1 FROM sbp_reserved_slugs WHERE slug = v_clean) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slug_reserved');
  END IF;

  IF EXISTS (SELECT 1 FROM sbp_shop_websites WHERE slug = v_clean AND shop_id <> p_shop_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slug_taken');
  END IF;

  IF EXISTS (SELECT 1 FROM sbp_slug_redirects
             WHERE old_slug = v_clean AND shop_id <> p_shop_id AND expires_at > now()) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'slug_recently_used');
  END IF;

  SELECT * INTO v_current FROM sbp_shop_websites WHERE shop_id = p_shop_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_website_row');
  END IF;

  IF NOT p_force
     AND v_current.slug_changed_at IS NOT NULL
     AND v_current.slug_changed_at > (now() - interval '30 days') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fee_required',
                              'message', 'Slug changes after first 30 days require ₹99 fee');
  END IF;

  IF v_current.slug <> v_clean THEN
    INSERT INTO sbp_slug_redirects(old_slug, shop_id)
    VALUES (v_current.slug, p_shop_id)
    ON CONFLICT (old_slug) DO UPDATE
    SET shop_id = p_shop_id, expires_at = now() + interval '12 months';
  END IF;

  UPDATE sbp_shop_websites
  SET slug = v_clean, slug_changed_at = now()
  WHERE shop_id = p_shop_id;

  RETURN jsonb_build_object('ok', true, 'new_slug', v_clean);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_change_shop_slug(uuid, text, boolean) TO authenticated;

-- ── 9. Update content RPC ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_update_website_content(
  p_shop_id uuid,
  p_patch jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_caller_owner boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM shops WHERE id = p_shop_id AND owner_id = auth.uid()
  ) INTO v_caller_owner;

  IF NOT v_caller_owner THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'patch_must_be_object');
  END IF;

  UPDATE sbp_shop_websites
  SET content_json = content_json || p_patch
  WHERE shop_id = p_shop_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_website_row');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_update_website_content(uuid, jsonb) TO authenticated;

-- ── 10. Auto-create website row trigger on new shops ───────────────────

CREATE OR REPLACE FUNCTION sbp_auto_create_website_row()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_slug text;
BEGIN
  v_slug := sbp_generate_slug(NEW.name, NEW.city);

  INSERT INTO sbp_shop_websites(shop_id, slug, content_json)
  VALUES (NEW.id, v_slug, sbp_default_website_content(NEW.id))
  ON CONFLICT (shop_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shops_auto_website ON shops;
CREATE TRIGGER trg_shops_auto_website
  AFTER INSERT ON shops
  FOR EACH ROW EXECUTE FUNCTION sbp_auto_create_website_row();

-- ── 11. Backfill existing shops ────────────────────────────────────────

DO $$
DECLARE
  r record;
  v_slug text;
BEGIN
  FOR r IN
    SELECT s.id, s.name, s.city
    FROM shops s
    LEFT JOIN sbp_shop_websites w ON w.shop_id = s.id
    WHERE w.id IS NULL
  LOOP
    v_slug := sbp_generate_slug(r.name, r.city);

    INSERT INTO sbp_shop_websites(shop_id, slug, content_json)
    VALUES (r.id, v_slug, sbp_default_website_content(r.id))
    ON CONFLICT (shop_id) DO NOTHING;
  END LOOP;
END $$;

-- ── 12. Hit counter RPCs ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION sbp_log_shop_page_view(p_slug text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE sbp_shop_websites
  SET view_count = view_count + 1
  WHERE slug = p_slug AND published = true;
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_log_shop_page_view(text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION sbp_log_whatsapp_click(p_slug text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE sbp_shop_websites
  SET whatsapp_clicks = whatsapp_clicks + 1
  WHERE slug = p_slug AND published = true;
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_log_whatsapp_click(text) TO anon, authenticated;

-- ── 13. Resolve slug RPC for /s/[slug] page render ─────────────────────

CREATE OR REPLACE FUNCTION sbp_resolve_shop_slug(p_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_redirect record;
  v_website record;
  v_clean text;
BEGIN
  v_clean := lower(trim(coalesce(p_slug, '')));
  IF length(v_clean) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_slug');
  END IF;

  SELECT r.* INTO v_redirect
  FROM sbp_slug_redirects r
  WHERE r.old_slug = v_clean AND r.expires_at > now();

  IF FOUND THEN
    SELECT w.slug INTO v_clean
    FROM sbp_shop_websites w
    WHERE w.shop_id = v_redirect.shop_id;
    RETURN jsonb_build_object('ok', true, 'redirect', true, 'new_slug', v_clean);
  END IF;

  SELECT
    w.slug, w.content_json, w.design_tokens, w.updated_at,
    s.name AS shop_name, s.shop_type, s.plan
  INTO v_website
  FROM sbp_shop_websites w
  JOIN shops s ON s.id = w.shop_id
  WHERE w.slug = v_clean AND w.published = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'slug', v_website.slug,
    'content', v_website.content_json,
    'design', v_website.design_tokens,
    'shop_name', v_website.shop_name,
    'shop_type', v_website.shop_type,
    'plan', v_website.plan,
    'updated_at', v_website.updated_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_resolve_shop_slug(text) TO anon, authenticated;

-- ════════════════════════════════════════════════════════════════════
-- Verification queries (run manually after deploy):
--   SELECT count(*) FROM sbp_shop_websites;
--   SELECT slug, content_json->>'name' FROM sbp_shop_websites LIMIT 5;
--   SELECT * FROM sbp_resolve_shop_slug('your-test-slug');
-- ════════════════════════════════════════════════════════════════════
