-- ════════════════════════════════════════════════════════════════
-- ShopBill Pro — Migration 004: Admin SEO Manager
-- ════════════════════════════════════════════════════════════════
-- Run AFTER migration 003.
-- Idempotent — safe to re-run.
--
-- This migration creates the database backbone for the admin SEO panel.
-- All marketing-site SEO (titles, meta, OG tags, schema, blog posts) is
-- driven from these tables — no code deploys needed for content updates.
--
-- Tables:
--   sbp_seo_global   — site-wide defaults (singleton row)
--   sbp_seo_pages    — per-page SEO settings
--   sbp_blog_posts   — blog post CMS
--   sbp_seo_redirects — 301 redirect manager
-- ════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════
-- 1. sbp_seo_global — site-wide defaults
-- ══════════════════════════════════════════════════════════════
-- Singleton table (id=1) — the admin SEO Global page edits this row.

CREATE TABLE IF NOT EXISTS sbp_seo_global (
  id                  smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  site_name           text DEFAULT 'ShopBill Pro',
  site_tagline        text DEFAULT 'Run any business in India',
  default_title_template text DEFAULT '{page} | ShopBill Pro',
  default_description text DEFAULT 'Free GST billing software for Indian shops. POS + manual billing, stock, customer ledger, GSTR exports, WhatsApp bills.',
  default_og_image    text,
  default_keywords    text DEFAULT 'billing software india, GST billing, kirana billing, free billing software',
  -- Organization Schema
  org_name            text DEFAULT 'TradeCrest Technologies Pvt. Ltd.',
  org_legal_name      text DEFAULT 'TradeCrest Technologies Pvt. Ltd.',
  org_logo_url        text,
  org_url             text DEFAULT 'https://shopbillpro.in',
  org_contact_email   text,
  org_contact_phone   text,
  org_address_country text DEFAULT 'IN',
  org_address_locality text,
  org_address_region  text,
  org_address_postal  text,
  org_address_street  text,
  -- Social
  social_twitter      text,
  social_facebook     text,
  social_instagram    text,
  social_youtube      text,
  social_linkedin     text,
  -- Verifications
  google_search_console_token text,
  bing_webmaster_token text,
  google_analytics_id text,
  posthog_token       text,
  sentry_dsn          text,
  -- robots.txt
  robots_txt_content  text DEFAULT E'User-agent: *\nAllow: /\nDisallow: /admin/\nDisallow: /app/dashboard\nDisallow: /app/billing\nDisallow: /app/bills\nDisallow: /app/customers\nDisallow: /app/stock\nDisallow: /app/reports\nDisallow: /app/settings\nDisallow: /app/wa-center\nDisallow: /app/team\nDisallow: /app/marketing\nDisallow: /app/subscription\nSitemap: https://shopbillpro.in/sitemap.xml',
  updated_at          timestamptz DEFAULT now(),
  updated_by          text
);

-- Seed the singleton row
INSERT INTO sbp_seo_global (id) VALUES (1) ON CONFLICT (id) DO NOTHING;


-- ══════════════════════════════════════════════════════════════
-- 2. sbp_seo_pages — per-page SEO settings
-- ══════════════════════════════════════════════════════════════
-- One row per page on the marketing site. The admin SEO Pages screen
-- edits these. Marketing pages render from this data at build/serve time.

CREATE TABLE IF NOT EXISTS sbp_seo_pages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  path            text UNIQUE NOT NULL,                 -- '/', '/pricing', '/for/kirana', etc.
  page_type       text NOT NULL,                        -- 'home','feature','vertical','vs','pricing','legal'
  title           text NOT NULL,
  meta_description text,
  h1              text,
  og_title        text,
  og_description  text,
  og_image        text,
  schema_type     text DEFAULT 'WebPage',               -- 'SoftwareApplication','FAQPage','Article', etc.
  schema_jsonld   jsonb,                                -- full custom JSON-LD if needed
  keywords        text,
  canonical_url   text,
  -- Hindi translations (for /hi/<path>)
  title_hi        text,
  meta_description_hi text,
  h1_hi           text,
  -- Page-level controls
  noindex         boolean DEFAULT false,
  in_sitemap      boolean DEFAULT true,
  priority        numeric(2,1) DEFAULT 0.5,             -- sitemap priority 0.0-1.0
  changefreq      text DEFAULT 'weekly',                -- 'always','hourly','daily','weekly','monthly','yearly','never'
  display_order   integer DEFAULT 100,
  is_published    boolean DEFAULT true,
  -- Audit
  updated_at      timestamptz DEFAULT now(),
  updated_by      text,
  created_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_seo_pages_path ON sbp_seo_pages(path);
CREATE INDEX IF NOT EXISTS idx_seo_pages_published ON sbp_seo_pages(is_published) WHERE is_published = true;
CREATE INDEX IF NOT EXISTS idx_seo_pages_sitemap ON sbp_seo_pages(in_sitemap) WHERE in_sitemap = true;


-- Seed initial 14 pages from the strategy doc
INSERT INTO sbp_seo_pages (path, page_type, title, meta_description, h1, schema_type, priority, display_order) VALUES
  ('/',                'home',     'ShopBill Pro — Free GST Billing Software for Indian Shops',
                                   'Free GST billing software for kirana, restaurant, salon, pharmacy, and any Indian business. Works offline, prints WhatsApp bills, manages stock. No card needed.',
                                   'Free GST Billing Software for Every Indian Business',
                                   'SoftwareApplication', 1.0, 10),
  ('/pricing',         'pricing',  'Pricing — ShopBill Pro | Free, Pro ₹99, Business ₹499',
                                   'Simple pricing: Free with watermark · Pro ₹99/month · Business ₹499/month with website + vertical modules. No hidden fees. Cancel anytime.',
                                   'Simple, transparent pricing for every shop',
                                   'WebPage', 0.9, 20),
  ('/features/gst-billing','feature','GST Billing Software India | ShopBill Pro',
                                   'Generate GST-compliant invoices in seconds. Auto CGST/SGST/IGST split, GSTR-1 and GSTR-3B exports, B2B and B2C handling. Free for 100 bills/month.',
                                   'GST Billing Made Easy', 'WebPage', 0.8, 30),
  ('/features/pos-billing','feature','POS Software for Shop | Fast Counter Billing | ShopBill Pro',
                                   'Lightning-fast POS billing on phone, tablet or computer. Barcode scanner, quick item search, mobile-first. Perfect for kirana and retail.',
                                   'Fast POS billing for any shop', 'WebPage', 0.8, 31),
  ('/features/whatsapp-bills','feature','Send Bills on WhatsApp | UPI QR Bill Software | ShopBill Pro',
                                   'Send GST bills directly to customers on WhatsApp with UPI QR code. One-tap payment, auto-reminders. Loved by Indian shopkeepers.',
                                   'WhatsApp bills with built-in UPI', 'WebPage', 0.8, 32),
  ('/features/inventory-stock','feature','Stock Management Software | Inventory Tracking | ShopBill Pro',
                                   'Track stock levels, cost prices, and reorder alerts. Real COGS for accurate profit tracking. Works offline.',
                                   'Smart inventory and stock tracking', 'WebPage', 0.8, 33),
  ('/for/retail',      'vertical', 'Retail Billing Software | Kirana, Garments, Hardware | ShopBill Pro',
                                   'Built for Indian retail shops. GST billing, stock, customer khata, WhatsApp bills, premium shop website — all in one. Free to start.',
                                   'Retail Billing Software for Indian Shops', 'WebPage', 0.7, 40),
  ('/for/restaurants', 'vertical', 'Restaurant Billing Software India | QR Menu, Tables | ShopBill Pro',
                                   'Restaurant billing with QR menu, table management, kitchen display, online orders coming soon. GST-ready, bilingual, mobile-first.',
                                   'Restaurant Software Built for India', 'WebPage', 0.7, 41),
  ('/for/services',    'vertical', 'Service Business Software India | Plumber, Photographer, Repair | ShopBill Pro',
                                   'Service business billing with appointment booking, customer history, WhatsApp reminders. Perfect for repair, photography, home services.',
                                   'Service business made simple', 'WebPage', 0.7, 42),
  ('/for/healthcare',  'vertical', 'Clinic Billing Software India | Doctor, Dentist, Vet | ShopBill Pro',
                                   'Clinic and doctor billing with appointments, patient records, prescription tracking. GST-ready, bilingual, mobile-first.',
                                   'Clinic & healthcare practice software', 'WebPage', 0.7, 43),
  ('/for/education',   'vertical', 'Coaching Class Software | Tuition, Music, Skill | ShopBill Pro',
                                   'Coaching and tuition class management — fee tracking, batches, attendance, parent communication. Built for Indian institutes.',
                                   'Coaching class management software', 'WebPage', 0.7, 44),
  ('/vs/vyapar',       'vs',       'ShopBill Pro vs Vyapar | Compare Indian Billing Software',
                                   'Compare ShopBill Pro and Vyapar. Free tier features, GST handling, WhatsApp bills, vertical modules, public shop page. Honest comparison.',
                                   'ShopBill Pro vs Vyapar', 'WebPage', 0.6, 50),
  ('/vs/khatabook',    'vs',       'ShopBill Pro vs Khatabook | Billing + Khata Comparison',
                                   'Khatabook is great for ledger. ShopBill Pro adds full GST billing, stock, reports, vertical modules, premium website. See what fits.',
                                   'ShopBill Pro vs Khatabook', 'WebPage', 0.6, 51),
  ('/vs/mybillbook',   'vs',       'ShopBill Pro vs myBillBook | Compare Pricing & Features',
                                   'Compare ShopBill Pro and myBillBook on pricing, features, vertical modules, and shop website. Find the best billing app for your business.',
                                   'ShopBill Pro vs myBillBook', 'WebPage', 0.6, 52)
ON CONFLICT (path) DO NOTHING;


-- ══════════════════════════════════════════════════════════════
-- 3. sbp_blog_posts — blog CMS
-- ══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS sbp_blog_posts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            text UNIQUE NOT NULL,                 -- 'how-to-make-gst-bill-india'
  title           text NOT NULL,
  excerpt         text,                                 -- 1-2 sentence summary
  body_md         text NOT NULL,                        -- full markdown content
  -- SEO
  meta_title      text,
  meta_description text,
  og_image        text,
  keywords        text,
  schema_type     text DEFAULT 'Article',               -- 'Article','BlogPosting','HowTo','FAQPage'
  -- Author
  author_name     text DEFAULT 'ShopBill Pro Team',
  author_bio      text,
  author_avatar   text,
  -- Categorization
  category        text DEFAULT 'general',               -- 'gst','billing','marketing','tutorial', etc.
  tags            text[],
  featured_image  text,
  featured_image_alt text,
  reading_time_min integer,
  -- Hindi
  title_hi        text,
  body_md_hi      text,
  -- Publish controls
  status          text DEFAULT 'draft' CHECK (status IN ('draft','scheduled','published','archived')),
  published_at    timestamptz,
  scheduled_for   timestamptz,
  -- Audit
  updated_at      timestamptz DEFAULT now(),
  updated_by      text,
  created_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_blog_slug ON sbp_blog_posts(slug);
CREATE INDEX IF NOT EXISTS idx_blog_status ON sbp_blog_posts(status);
CREATE INDEX IF NOT EXISTS idx_blog_published_at ON sbp_blog_posts(published_at DESC) WHERE status = 'published';
CREATE INDEX IF NOT EXISTS idx_blog_category ON sbp_blog_posts(category);


-- Seed the 5 launch blog post drafts (empty body — to be written before launch)
INSERT INTO sbp_blog_posts (slug, title, excerpt, body_md, meta_title, meta_description, category, status) VALUES
  ('how-to-make-gst-bill-india-2026',
   'How to Make a GST Bill in India — Complete Guide 2026',
   'Step-by-step guide to creating GST-compliant invoices for any Indian business. Includes B2B, B2C, HSN codes, and CGST/SGST/IGST rules.',
   E'# How to Make a GST Bill in India — Complete Guide 2026\n\n*[Draft — to be completed pre-launch]*',
   'How to Make a GST Bill in India — Complete Guide 2026 | ShopBill Pro',
   'Learn how to create GST-compliant invoices in India. B2B vs B2C, HSN codes, CGST/SGST/IGST rules, place of supply — explained simply.',
   'gst', 'draft'),
  ('gst-rates-kirana-shop-hsn-list',
   'GST Rates for Kirana Shop Items — Full HSN List',
   'Complete HSN code reference and GST rate guide for kirana shop items: rice, dal, oil, sugar, spices, dairy, packaged food.',
   E'# GST Rates for Kirana Shop Items — Full HSN List\n\n*[Draft — to be completed pre-launch]*',
   'GST Rates for Kirana Shop Items — Full HSN List | ShopBill Pro',
   'Find GST rates and HSN codes for all kirana shop items. Rice, dal, oil, sugar, packaged foods, dairy, and more — Indian GST reference.',
   'gst', 'draft'),
  ('how-to-send-bill-on-whatsapp',
   'How to Send Bills on WhatsApp — Step-by-Step',
   'Send GST bills, payment links, and reminders to customers via WhatsApp. Includes UPI QR setup and templates.',
   E'# How to Send Bills on WhatsApp — Step-by-Step\n\n*[Draft — to be completed pre-launch]*',
   'How to Send Bills on WhatsApp — Step-by-Step Guide | ShopBill Pro',
   'Send GST bills to customers via WhatsApp in 3 taps. UPI QR codes, payment reminders, message templates — all explained.',
   'tutorial', 'draft'),
  ('best-free-billing-software-india-2026',
   'Best Free Billing Software for Small Business in India 2026',
   'Compare the top free billing apps for Indian shops: features, pricing, GST support, regional language, and offline mode.',
   E'# Best Free Billing Software for Small Business in India 2026\n\n*[Draft — to be completed pre-launch]*',
   'Best Free Billing Software for Small Business in India 2026 | ShopBill Pro',
   'Compare the top free GST billing apps for Indian businesses. Features, pricing, language support, offline use — find the right fit.',
   'comparison', 'draft'),
  ('hindi-bill-kaise-banaye-software-guide',
   'Hindi Me Bill Kaise Banaye — Software Guide',
   'हिंदी में बिल कैसे बनाएं — किराना दुकान, रेस्तरां, सैलून के लिए सरल गाइड।',
   E'# Hindi Me Bill Kaise Banaye — Software Guide\n\n*[Draft — to be completed pre-launch]*',
   'Hindi Me Bill Kaise Banaye — पूरा गाइड | ShopBill Pro',
   'हिंदी में GST बिल बनाने का आसान तरीका। किराना, रेस्तरां, सैलून सहित किसी भी छोटी दुकान के लिए।',
   'tutorial', 'draft')
ON CONFLICT (slug) DO NOTHING;


-- ══════════════════════════════════════════════════════════════
-- 4. sbp_seo_redirects — 301 redirect manager
-- ══════════════════════════════════════════════════════════════
-- Used to preserve SEO when paths change (e.g. slug change, page rename).

CREATE TABLE IF NOT EXISTS sbp_seo_redirects (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_path       text UNIQUE NOT NULL,
  to_path         text NOT NULL,
  status_code     integer DEFAULT 301 CHECK (status_code IN (301, 302, 307, 308)),
  is_active       boolean DEFAULT true,
  hits            bigint DEFAULT 0,                      -- counter, incremented by middleware
  notes           text,
  created_at      timestamptz DEFAULT now(),
  expires_at      timestamptz                            -- nullable; for slug-change auto-expiry
);

CREATE INDEX IF NOT EXISTS idx_redirects_from ON sbp_seo_redirects(from_path) WHERE is_active = true;


-- ══════════════════════════════════════════════════════════════
-- 5. RPCs for admin SEO panel + sitemap generator
-- ══════════════════════════════════════════════════════════════

-- Admin: read full SEO global (auth'd via admin token in client)
CREATE OR REPLACE FUNCTION public.admin_get_seo_global(p_token text)
RETURNS sbp_seo_global
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row sbp_seo_global;
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  SELECT * INTO v_row FROM sbp_seo_global WHERE id = 1;
  RETURN v_row;
END $$;

-- Admin: update SEO global (one or more fields via JSONB patch)
CREATE OR REPLACE FUNCTION public.admin_update_seo_global(p_token text, p_patch jsonb)
RETURNS sbp_seo_global
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row sbp_seo_global;
  v_key text;
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- Update only the fields present in p_patch
  UPDATE sbp_seo_global SET
    site_name           = COALESCE(p_patch->>'site_name',           site_name),
    site_tagline        = COALESCE(p_patch->>'site_tagline',        site_tagline),
    default_title_template = COALESCE(p_patch->>'default_title_template', default_title_template),
    default_description = COALESCE(p_patch->>'default_description', default_description),
    default_og_image    = COALESCE(p_patch->>'default_og_image',    default_og_image),
    default_keywords    = COALESCE(p_patch->>'default_keywords',    default_keywords),
    org_name            = COALESCE(p_patch->>'org_name',            org_name),
    org_legal_name      = COALESCE(p_patch->>'org_legal_name',      org_legal_name),
    org_logo_url        = COALESCE(p_patch->>'org_logo_url',        org_logo_url),
    org_url             = COALESCE(p_patch->>'org_url',             org_url),
    org_contact_email   = COALESCE(p_patch->>'org_contact_email',   org_contact_email),
    org_contact_phone   = COALESCE(p_patch->>'org_contact_phone',   org_contact_phone),
    org_address_country = COALESCE(p_patch->>'org_address_country', org_address_country),
    org_address_locality = COALESCE(p_patch->>'org_address_locality', org_address_locality),
    org_address_region  = COALESCE(p_patch->>'org_address_region',  org_address_region),
    org_address_postal  = COALESCE(p_patch->>'org_address_postal',  org_address_postal),
    org_address_street  = COALESCE(p_patch->>'org_address_street',  org_address_street),
    social_twitter      = COALESCE(p_patch->>'social_twitter',      social_twitter),
    social_facebook     = COALESCE(p_patch->>'social_facebook',     social_facebook),
    social_instagram    = COALESCE(p_patch->>'social_instagram',    social_instagram),
    social_youtube      = COALESCE(p_patch->>'social_youtube',      social_youtube),
    social_linkedin     = COALESCE(p_patch->>'social_linkedin',     social_linkedin),
    google_search_console_token = COALESCE(p_patch->>'google_search_console_token', google_search_console_token),
    bing_webmaster_token = COALESCE(p_patch->>'bing_webmaster_token', bing_webmaster_token),
    google_analytics_id = COALESCE(p_patch->>'google_analytics_id', google_analytics_id),
    posthog_token       = COALESCE(p_patch->>'posthog_token',       posthog_token),
    sentry_dsn          = COALESCE(p_patch->>'sentry_dsn',          sentry_dsn),
    robots_txt_content  = COALESCE(p_patch->>'robots_txt_content',  robots_txt_content),
    updated_at          = now(),
    updated_by          = COALESCE(p_patch->>'updated_by', 'admin')
  WHERE id = 1
  RETURNING * INTO v_row;

  RETURN v_row;
END $$;

-- Admin: list all SEO pages
CREATE OR REPLACE FUNCTION public.admin_list_seo_pages(p_token text)
RETURNS SETOF sbp_seo_pages
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  RETURN QUERY SELECT * FROM sbp_seo_pages ORDER BY display_order, path;
END $$;

-- Admin: upsert SEO page (insert if path new, otherwise update)
CREATE OR REPLACE FUNCTION public.admin_upsert_seo_page(p_token text, p_data jsonb)
RETURNS sbp_seo_pages
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row sbp_seo_pages;
  v_path text;
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  v_path := p_data->>'path';
  IF v_path IS NULL OR v_path = '' THEN
    RAISE EXCEPTION 'path is required';
  END IF;

  INSERT INTO sbp_seo_pages (
    path, page_type, title, meta_description, h1, og_title, og_description,
    og_image, schema_type, schema_jsonld, keywords, canonical_url,
    title_hi, meta_description_hi, h1_hi,
    noindex, in_sitemap, priority, changefreq,
    display_order, is_published, updated_by
  )
  VALUES (
    v_path,
    COALESCE(p_data->>'page_type', 'WebPage'),
    p_data->>'title',
    p_data->>'meta_description',
    p_data->>'h1',
    p_data->>'og_title',
    p_data->>'og_description',
    p_data->>'og_image',
    COALESCE(p_data->>'schema_type', 'WebPage'),
    CASE WHEN p_data ? 'schema_jsonld' THEN p_data->'schema_jsonld' ELSE NULL END,
    p_data->>'keywords',
    p_data->>'canonical_url',
    p_data->>'title_hi',
    p_data->>'meta_description_hi',
    p_data->>'h1_hi',
    COALESCE((p_data->>'noindex')::boolean, false),
    COALESCE((p_data->>'in_sitemap')::boolean, true),
    COALESCE((p_data->>'priority')::numeric, 0.5),
    COALESCE(p_data->>'changefreq', 'weekly'),
    COALESCE((p_data->>'display_order')::int, 100),
    COALESCE((p_data->>'is_published')::boolean, true),
    COALESCE(p_data->>'updated_by', 'admin')
  )
  ON CONFLICT (path) DO UPDATE SET
    page_type = EXCLUDED.page_type,
    title = EXCLUDED.title,
    meta_description = EXCLUDED.meta_description,
    h1 = EXCLUDED.h1,
    og_title = EXCLUDED.og_title,
    og_description = EXCLUDED.og_description,
    og_image = EXCLUDED.og_image,
    schema_type = EXCLUDED.schema_type,
    schema_jsonld = EXCLUDED.schema_jsonld,
    keywords = EXCLUDED.keywords,
    canonical_url = EXCLUDED.canonical_url,
    title_hi = EXCLUDED.title_hi,
    meta_description_hi = EXCLUDED.meta_description_hi,
    h1_hi = EXCLUDED.h1_hi,
    noindex = EXCLUDED.noindex,
    in_sitemap = EXCLUDED.in_sitemap,
    priority = EXCLUDED.priority,
    changefreq = EXCLUDED.changefreq,
    display_order = EXCLUDED.display_order,
    is_published = EXCLUDED.is_published,
    updated_at = now(),
    updated_by = EXCLUDED.updated_by
  RETURNING * INTO v_row;

  RETURN v_row;
END $$;

-- Admin: delete SEO page
CREATE OR REPLACE FUNCTION public.admin_delete_seo_page(p_token text, p_path text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  DELETE FROM sbp_seo_pages WHERE path = p_path;
  RETURN FOUND;
END $$;

-- Admin: list blog posts
CREATE OR REPLACE FUNCTION public.admin_list_blog_posts(p_token text, p_status text DEFAULT NULL)
RETURNS SETOF sbp_blog_posts
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  IF p_status IS NULL THEN
    RETURN QUERY SELECT * FROM sbp_blog_posts ORDER BY COALESCE(published_at, created_at) DESC;
  ELSE
    RETURN QUERY SELECT * FROM sbp_blog_posts WHERE status = p_status ORDER BY COALESCE(published_at, created_at) DESC;
  END IF;
END $$;

-- Admin: upsert blog post
CREATE OR REPLACE FUNCTION public.admin_upsert_blog_post(p_token text, p_data jsonb)
RETURNS sbp_blog_posts
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row sbp_blog_posts;
  v_slug text;
  v_status text;
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  v_slug := p_data->>'slug';
  v_status := COALESCE(p_data->>'status', 'draft');
  IF v_slug IS NULL OR v_slug = '' THEN
    RAISE EXCEPTION 'slug is required';
  END IF;

  INSERT INTO sbp_blog_posts (
    slug, title, excerpt, body_md,
    meta_title, meta_description, og_image, keywords, schema_type,
    author_name, author_bio, author_avatar,
    category, tags, featured_image, featured_image_alt, reading_time_min,
    title_hi, body_md_hi,
    status, published_at, scheduled_for, updated_by
  )
  VALUES (
    v_slug,
    p_data->>'title',
    p_data->>'excerpt',
    COALESCE(p_data->>'body_md', ''),
    p_data->>'meta_title',
    p_data->>'meta_description',
    p_data->>'og_image',
    p_data->>'keywords',
    COALESCE(p_data->>'schema_type', 'Article'),
    COALESCE(p_data->>'author_name', 'ShopBill Pro Team'),
    p_data->>'author_bio',
    p_data->>'author_avatar',
    COALESCE(p_data->>'category', 'general'),
    CASE WHEN p_data ? 'tags' THEN ARRAY(SELECT jsonb_array_elements_text(p_data->'tags')) ELSE NULL END,
    p_data->>'featured_image',
    p_data->>'featured_image_alt',
    NULLIF(p_data->>'reading_time_min', '')::int,
    p_data->>'title_hi',
    p_data->>'body_md_hi',
    v_status,
    CASE WHEN v_status = 'published' THEN COALESCE((p_data->>'published_at')::timestamptz, now())
         ELSE (p_data->>'published_at')::timestamptz
    END,
    (p_data->>'scheduled_for')::timestamptz,
    COALESCE(p_data->>'updated_by', 'admin')
  )
  ON CONFLICT (slug) DO UPDATE SET
    title = EXCLUDED.title,
    excerpt = EXCLUDED.excerpt,
    body_md = EXCLUDED.body_md,
    meta_title = EXCLUDED.meta_title,
    meta_description = EXCLUDED.meta_description,
    og_image = EXCLUDED.og_image,
    keywords = EXCLUDED.keywords,
    schema_type = EXCLUDED.schema_type,
    author_name = EXCLUDED.author_name,
    author_bio = EXCLUDED.author_bio,
    author_avatar = EXCLUDED.author_avatar,
    category = EXCLUDED.category,
    tags = EXCLUDED.tags,
    featured_image = EXCLUDED.featured_image,
    featured_image_alt = EXCLUDED.featured_image_alt,
    reading_time_min = EXCLUDED.reading_time_min,
    title_hi = EXCLUDED.title_hi,
    body_md_hi = EXCLUDED.body_md_hi,
    status = EXCLUDED.status,
    published_at = CASE
      WHEN EXCLUDED.status = 'published' AND sbp_blog_posts.published_at IS NULL THEN now()
      ELSE EXCLUDED.published_at
    END,
    scheduled_for = EXCLUDED.scheduled_for,
    updated_at = now(),
    updated_by = EXCLUDED.updated_by
  RETURNING * INTO v_row;

  RETURN v_row;
END $$;

-- Admin: delete blog post
CREATE OR REPLACE FUNCTION public.admin_delete_blog_post(p_token text, p_slug text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  DELETE FROM sbp_blog_posts WHERE slug = p_slug;
  RETURN FOUND;
END $$;

-- Admin: list redirects
CREATE OR REPLACE FUNCTION public.admin_list_redirects(p_token text)
RETURNS SETOF sbp_seo_redirects
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  RETURN QUERY SELECT * FROM sbp_seo_redirects ORDER BY created_at DESC;
END $$;

-- Admin: upsert redirect
CREATE OR REPLACE FUNCTION public.admin_upsert_redirect(p_token text, p_data jsonb)
RETURNS sbp_seo_redirects
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row sbp_seo_redirects;
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  INSERT INTO sbp_seo_redirects (
    from_path, to_path, status_code, is_active, notes, expires_at
  )
  VALUES (
    p_data->>'from_path',
    p_data->>'to_path',
    COALESCE((p_data->>'status_code')::int, 301),
    COALESCE((p_data->>'is_active')::boolean, true),
    p_data->>'notes',
    (p_data->>'expires_at')::timestamptz
  )
  ON CONFLICT (from_path) DO UPDATE SET
    to_path = EXCLUDED.to_path,
    status_code = EXCLUDED.status_code,
    is_active = EXCLUDED.is_active,
    notes = EXCLUDED.notes,
    expires_at = EXCLUDED.expires_at
  RETURNING * INTO v_row;

  RETURN v_row;
END $$;

-- Admin: delete redirect
CREATE OR REPLACE FUNCTION public.admin_delete_redirect(p_token text, p_from_path text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT admin_verify_token(p_token) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  DELETE FROM sbp_seo_redirects WHERE from_path = p_from_path;
  RETURN FOUND;
END $$;


-- ══════════════════════════════════════════════════════════════
-- 6. Public RPCs — used by marketing site to render SEO content
-- ══════════════════════════════════════════════════════════════

-- Get SEO config for a page (no auth required — public read)
CREATE OR REPLACE FUNCTION public.get_page_seo(p_path text)
RETURNS TABLE (
  title text, meta_description text, h1 text,
  og_title text, og_description text, og_image text,
  schema_type text, schema_jsonld jsonb, keywords text, canonical_url text,
  title_hi text, meta_description_hi text, h1_hi text,
  noindex boolean
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT title, meta_description, h1,
         og_title, og_description, og_image,
         schema_type, schema_jsonld, keywords, canonical_url,
         title_hi, meta_description_hi, h1_hi, noindex
  FROM sbp_seo_pages
  WHERE path = p_path AND is_published = true
  LIMIT 1;
$$;

-- Get all pages for sitemap.xml generation
CREATE OR REPLACE FUNCTION public.get_sitemap_pages()
RETURNS TABLE (path text, priority numeric, changefreq text, updated_at timestamptz)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT path, priority, changefreq, updated_at
  FROM sbp_seo_pages
  WHERE is_published = true AND in_sitemap = true AND noindex = false
  UNION ALL
  SELECT '/blog/' || slug, 0.6, 'weekly', updated_at
  FROM sbp_blog_posts
  WHERE status = 'published'
  ORDER BY priority DESC, path;
$$;

-- Get a published blog post by slug (public)
CREATE OR REPLACE FUNCTION public.get_blog_post(p_slug text)
RETURNS sbp_blog_posts
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_row sbp_blog_posts;
BEGIN
  SELECT * INTO v_row FROM sbp_blog_posts
  WHERE slug = p_slug AND status = 'published';
  RETURN v_row;
END $$;

-- List recent published blog posts (public)
CREATE OR REPLACE FUNCTION public.list_blog_posts(p_limit int DEFAULT 20, p_category text DEFAULT NULL)
RETURNS TABLE (
  slug text, title text, excerpt text, category text,
  featured_image text, published_at timestamptz, reading_time_min integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT slug, title, excerpt, category, featured_image, published_at, reading_time_min
  FROM sbp_blog_posts
  WHERE status = 'published'
    AND (p_category IS NULL OR category = p_category)
  ORDER BY published_at DESC
  LIMIT GREATEST(LEAST(p_limit, 100), 1);
$$;

-- Find a redirect for a given path
CREATE OR REPLACE FUNCTION public.lookup_redirect(p_path text)
RETURNS TABLE (to_path text, status_code integer)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT to_path, status_code
  FROM sbp_seo_redirects
  WHERE from_path = p_path
    AND is_active = true
    AND (expires_at IS NULL OR expires_at > now())
  LIMIT 1;
$$;

-- Read SEO global as a public-facing org info (NO secret tokens — only public fields)
CREATE OR REPLACE FUNCTION public.get_seo_global_public()
RETURNS TABLE (
  site_name text, site_tagline text, default_og_image text,
  org_name text, org_legal_name text, org_logo_url text, org_url text,
  social_twitter text, social_facebook text, social_instagram text,
  social_youtube text, social_linkedin text,
  google_search_console_token text,
  bing_webmaster_token text,
  google_analytics_id text,
  posthog_token text,
  sentry_dsn text
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT site_name, site_tagline, default_og_image,
         org_name, org_legal_name, org_logo_url, org_url,
         social_twitter, social_facebook, social_instagram,
         social_youtube, social_linkedin,
         google_search_console_token,
         bing_webmaster_token,
         google_analytics_id,
         posthog_token,
         sentry_dsn
  FROM sbp_seo_global WHERE id = 1 LIMIT 1;
$$;

-- Read just robots.txt content
CREATE OR REPLACE FUNCTION public.get_robots_txt()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT robots_txt_content FROM sbp_seo_global WHERE id = 1;
$$;


GRANT EXECUTE ON FUNCTION public.get_page_seo(text)            TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_sitemap_pages()           TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_blog_post(text)           TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.list_blog_posts(int, text)    TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.lookup_redirect(text)         TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_seo_global_public()       TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_robots_txt()              TO authenticated, anon;


-- ══════════════════════════════════════════════════════════════
-- DONE — Migration 004 complete.
-- ══════════════════════════════════════════════════════════════
-- Verify with:
--   SELECT count(*) FROM sbp_seo_pages;     -- expect 14 seeded pages
--   SELECT count(*) FROM sbp_blog_posts;    -- expect 5 draft posts
--   SELECT * FROM get_seo_global_public();
--   SELECT * FROM get_page_seo('/');
--   SELECT * FROM get_sitemap_pages();
-- ══════════════════════════════════════════════════════════════
