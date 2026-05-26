-- ════════════════════════════════════════════════════════════════════
-- 105_seo_phase1.sql
-- ════════════════════════════════════════════════════════════════════
-- WHAT
--   v8.0 — SEO Phase 1 server support:
--     1. Public sitemap RPC for crawlers to enumerate all published shops
--     2. IndexNow queue + enqueue helper
--     3. sbp_set_ai_website_published — extended to enqueue IndexNow ping
--        for both the canonical app URL and any connected custom_domain
--     4. (Optional) pg_cron 5-min flush — guarded; only enabled if
--        pg_cron + pg_net extensions are present.
--
-- WHY
--   Today there is no public way for Google/Bing/Yandex to discover all
--   shop pages. We need a sitemap. And when an owner publishes/republishes
--   their site, we want to ping IndexNow immediately so Bing/Yandex (and,
--   per November 2024 reports, Google) reindex within minutes instead
--   of waiting days for natural crawl.
--
-- DEPLOY
--   1. Run this migration in Supabase SQL Editor.
--   2. Deploy the 3 Edge Functions (shop-page, shop-sitemap, indexnow-flush).
--   3. Update vercel.json (rewrites) + robots.txt + .well-known/{key}.txt.
--   4. Optionally configure pg_cron (see section 6 below — left commented).
--
-- ROLLBACK
--   See bottom of file. Drops new tables/RPCs and restores the v7-era
--   sbp_set_ai_website_published.
-- ════════════════════════════════════════════════════════════════════

-- ── 1. Public sitemap RPC ───────────────────────────────────────────
-- Returns one row per published shop. Crawler-accessible (anon grant).

DROP FUNCTION IF EXISTS sbp_public_shop_sitemap();
CREATE OR REPLACE FUNCTION sbp_public_shop_sitemap()
RETURNS TABLE (
  slug           text,
  custom_domain  text,
  updated_at     timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    w.slug,
    CASE WHEN w.custom_domain_status = 'active'
         THEN w.custom_domain ELSE NULL END AS custom_domain,
    GREATEST(
      COALESCE(w.updated_at,            'epoch'::timestamptz),
      COALESCE(w.ai_last_generated_at,  'epoch'::timestamptz)
    ) AS updated_at
  FROM sbp_shop_websites w
  WHERE w.published    = true
    AND w.slug         IS NOT NULL
    AND length(w.slug) > 0
  ORDER BY updated_at DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION sbp_public_shop_sitemap() TO anon, authenticated;


-- ── 2. IndexNow queue ───────────────────────────────────────────────
-- URLs to push to api.indexnow.org. Drained by indexnow-flush Edge Fn.

CREATE TABLE IF NOT EXISTS _sbp_indexnow_queue (
  url           text PRIMARY KEY,
  enqueued_at   timestamptz NOT NULL DEFAULT now(),
  attempts      int         NOT NULL DEFAULT 0,
  last_attempt  timestamptz,
  last_error    text
);

-- No RLS: this is an internal queue, accessed only by the
-- indexnow-flush Edge Function (service role) and the
-- _sbp_enqueue_indexnow helper (SECURITY DEFINER, called only from
-- other SECURITY DEFINER RPCs).
ALTER TABLE _sbp_indexnow_queue DISABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS _sbp_indexnow_queue_enqueued_idx
  ON _sbp_indexnow_queue (enqueued_at);

COMMENT ON TABLE _sbp_indexnow_queue IS
  'IndexNow URLs awaiting submission. Drained by indexnow-flush Edge Function.';


-- ── 3. Enqueue helper ───────────────────────────────────────────────
-- Idempotent on URL (PK upsert). Resets attempts on re-enqueue.

DROP FUNCTION IF EXISTS _sbp_enqueue_indexnow(text);
CREATE OR REPLACE FUNCTION _sbp_enqueue_indexnow(p_url text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_url IS NULL OR length(trim(p_url)) = 0 THEN RETURN; END IF;
  INSERT INTO _sbp_indexnow_queue (url, enqueued_at, attempts, last_error)
  VALUES (trim(p_url), now(), 0, NULL)
  ON CONFLICT (url) DO UPDATE
  SET enqueued_at = EXCLUDED.enqueued_at,
      attempts    = 0,
      last_error  = NULL;
END;
$$;

-- Helper is internal — no anon grant.


-- ── 4. Replace sbp_set_ai_website_published to enqueue ──────────────
-- Same behaviour as before, plus IndexNow enqueue on publish=true.

DROP FUNCTION IF EXISTS sbp_set_ai_website_published(boolean);
CREATE OR REPLACE FUNCTION sbp_set_ai_website_published(p_published boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shop_id        uuid;
  v_slug           text;
  v_custom_domain  text;
  v_custom_active  boolean;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  UPDATE sbp_shop_websites
  SET ai_published = p_published,
      updated_at   = now()
  WHERE shop_id = v_shop_id
  RETURNING slug,
            custom_domain,
            (custom_domain_status = 'active')
    INTO v_slug, v_custom_domain, v_custom_active;

  IF v_slug IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_website');
  END IF;

  -- Enqueue on PUBLISH (not unpublish). Unpublish doesn't need IndexNow
  -- (Google will drop the page on next crawl when it 404s / 410s).
  IF p_published = true THEN
    PERFORM _sbp_enqueue_indexnow(
      'https://app.shopbillpro.in/s/' || v_slug
    );
    IF v_custom_active AND v_custom_domain IS NOT NULL THEN
      PERFORM _sbp_enqueue_indexnow(
        'https://' || v_custom_domain || '/'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'published', p_published);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_set_ai_website_published(boolean) TO authenticated;


-- ── 5. Manual flush trigger (for testing / manual reindex) ──────────
-- Owners can call this to re-enqueue their own site without re-publishing.

DROP FUNCTION IF EXISTS sbp_request_reindex();
CREATE OR REPLACE FUNCTION sbp_request_reindex()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shop_id        uuid;
  v_slug           text;
  v_custom_domain  text;
  v_custom_active  boolean;
  v_published      boolean;
BEGIN
  SELECT id INTO v_shop_id FROM shops WHERE owner_id = auth.uid() LIMIT 1;
  IF v_shop_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;

  SELECT w.slug, w.custom_domain,
         (w.custom_domain_status = 'active'),
         COALESCE(w.ai_published, false)
    INTO v_slug, v_custom_domain, v_custom_active, v_published
  FROM sbp_shop_websites w
  WHERE w.shop_id = v_shop_id;

  IF v_slug IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_website');
  END IF;
  IF NOT v_published THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_published',
      'message', 'Publish your site first');
  END IF;

  PERFORM _sbp_enqueue_indexnow('https://app.shopbillpro.in/s/' || v_slug);
  IF v_custom_active AND v_custom_domain IS NOT NULL THEN
    PERFORM _sbp_enqueue_indexnow('https://' || v_custom_domain || '/');
  END IF;

  RETURN jsonb_build_object('ok', true, 'slug', v_slug);
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_request_reindex() TO authenticated;


-- ── 6. Optional pg_cron flush ───────────────────────────────────────
-- COMMENTED OUT BY DEFAULT — uncomment after deploying indexnow-flush
-- Edge Function and confirming pg_cron + pg_net extensions are enabled
-- on the Supabase project.
--
-- The flush function is a thin POST to the Edge Function which then
-- batches into api.indexnow.org. Runs every 10 min.
--
-- DEPLOY STEPS:
--   1. In Supabase dashboard: Database → Extensions → enable pg_cron, pg_net
--   2. Uncomment the SELECT below, run it.
--   3. Set the supabase_anon_key in vault or substitute inline.
--
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
--      AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
--     PERFORM cron.schedule(
--       'indexnow_flush_10min',
--       '*/10 * * * *',
--       $cron$
--         SELECT net.http_post(
--           url     := 'https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/indexnow-flush',
--           headers := jsonb_build_object('Content-Type', 'application/json')
--         );
--       $cron$
--     );
--   END IF;
-- END $$;


NOTIFY pgrst, 'reload schema';

-- ════════════════════════════════════════════════════════════════════
-- ROLLBACK (run manually if needed):
--   DROP FUNCTION IF EXISTS sbp_public_shop_sitemap();
--   DROP FUNCTION IF EXISTS sbp_request_reindex();
--   DROP FUNCTION IF EXISTS _sbp_enqueue_indexnow(text);
--   DROP TABLE   IF EXISTS _sbp_indexnow_queue;
--   -- Then re-run mig 044's sbp_set_ai_website_published definition to
--   -- restore pre-v8.0 behaviour. (The v7.x version did not enqueue.)
-- ════════════════════════════════════════════════════════════════════
