# ShopBill Pro — v8.0 Shop Website SEO Phase 1

**Bundle:** `ShopBillPro_v8.0_seo_phase1.zip`
**Date:** 2026-05-25
**Goal:** Make every published shop website discoverable by Google,
shareable on WhatsApp/Facebook with real previews, and re-indexed
within minutes when an owner republishes.

---

## What this ships

Three Supabase Edge Functions plus one SQL migration plus updates to
`vercel.json`, `robots.txt`, and a new IndexNow key file.

| Capability | Before v8.0 | After v8.0 |
|---|---|---|
| Google sees `<title>` for a shop page | Generic "Shop · ShopBill Pro" | Real shop name |
| WhatsApp/FB share preview | Generic OG tags | Real shop name + photo + tagline |
| Schema.org structured data | None | LocalBusiness / Restaurant / BeautySalon / Hotel / etc. (32 vertical mappings) |
| Sitemap of all published shops | None | `/sitemap-shops.xml` dynamically generated, 1-hr CDN cache |
| Bing/Yandex/Google reindex on publish | Manual, days | Auto via IndexNow within minutes |
| `app.shopbillpro.in/robots.txt` | Marketing site's robots leaks here | App-specific rules |
| Logged-in pages crawled | Possibly indexed | Disallowed |

---

## DEPLOY PATHS

| Action  | Path                                                       | How                                         |
|---------|------------------------------------------------------------|---------------------------------------------|
| RUN     | `db/migrations/105_seo_phase1.sql`                         | Supabase SQL Editor                         |
| DEPLOY  | `supabase/functions/shop-page/index.ts`                    | Supabase Dashboard → Functions → Deploy     |
| DEPLOY  | `supabase/functions/shop-sitemap/index.ts`                 | Supabase Dashboard → Functions → Deploy     |
| DEPLOY  | `supabase/functions/indexnow-flush/index.ts`               | Supabase Dashboard → Functions → Deploy     |
| REPLACE | `vercel.json`                                              | GitHub Desktop → push                       |
| REPLACE | `robots.txt`                                               | GitHub Desktop → push                       |
| NEW     | `.well-known/f8488df6bad03b6684392d1eb63edd41.txt`         | GitHub Desktop → push                       |

⚠️ **The IndexNow key file MUST be deployed before submitting the first
ping**, or IndexNow returns 403 (key file unreachable).

---

## Deploy order (do these in sequence, not in parallel)

### Step 1 — Run the SQL migration

1. Open **Supabase Dashboard → SQL Editor**.
2. Paste contents of `db/migrations/105_seo_phase1.sql`.
3. Click **Run**. Expect: 5 success messages
   (`sbp_public_shop_sitemap` created, `_sbp_indexnow_queue` table created,
   `_sbp_enqueue_indexnow` created, `sbp_set_ai_website_published` replaced,
   `sbp_request_reindex` created), then `NOTIFY pgrst, 'reload schema'`.
4. Verify with:
   ```sql
   SELECT * FROM sbp_public_shop_sitemap() LIMIT 5;
   ```
   Should return rows for every published shop.

### Step 2 — Set the IndexNow secret

In **Supabase Dashboard → Edge Functions → Settings → Secrets**, add:

```
INDEXNOW_KEY = f8488df6bad03b6684392d1eb63edd41
```

(This MUST match the filename of the `.well-known` file you'll deploy
in step 4. If you change one, change the other.)

### Step 3 — Deploy the three Edge Functions

For each of `shop-page`, `shop-sitemap`, `indexnow-flush`:

1. Open **Supabase Dashboard → Edge Functions → Create a new function**.
2. Name it exactly as listed (lowercase, dashes).
3. Copy-paste the entire contents of the corresponding `index.ts` file.
4. Click **Deploy**.

Or via CLI if you prefer:
```bash
supabase functions deploy shop-page
supabase functions deploy shop-sitemap
supabase functions deploy indexnow-flush
```

After deploy, test each:

```bash
# shop-page (replace 'indian-curry' with a real published shop slug)
curl -i "https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/shop-page?slug=indian-curry"

# shop-sitemap
curl -i "https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/shop-sitemap"

# indexnow-flush (should return {"ok":true,"drained":0,"message":"queue_empty"})
curl -i -X POST "https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/indexnow-flush"
```

### Step 4 — Push static files + vercel.json

In GitHub Desktop:

1. Replace `vercel.json` (root)
2. Replace `robots.txt` (root)
3. Add new file `.well-known/f8488df6bad03b6684392d1eb63edd41.txt`
   (this is the IndexNow validation file — Bing/Yandex fetches it to
   verify ownership before accepting submissions)
4. Commit + push.
5. Wait ~2 min for Vercel build.

### Step 5 — Verify deploy

```bash
# Confirm robots.txt updated
curl -s https://app.shopbillpro.in/robots.txt | head -10

# Confirm key file accessible
curl -s https://app.shopbillpro.in/.well-known/f8488df6bad03b6684392d1eb63edd41.txt
# Expected: f8488df6bad03b6684392d1eb63edd41

# Confirm shop page SSR works (use a real published shop slug)
curl -s -A "Googlebot/2.1" https://app.shopbillpro.in/s/indian-curry | head -30
# Expect: real <title>, JSON-LD <script>, full body HTML — NOT the JS shell

# Confirm WhatsApp/FB preview works
curl -s -A "facebookexternalhit/1.1" https://app.shopbillpro.in/s/indian-curry | grep "og:"
# Expect: real og:title, og:description, og:image

# Confirm sitemap accessible
curl -s https://app.shopbillpro.in/sitemap-shops.xml | head -20
```

### Step 6 — (Optional) Enable pg_cron auto-flush

The IndexNow queue currently sits idle until manually flushed. To
auto-flush every 10 min:

1. In Supabase Dashboard → Database → Extensions, enable **pg_cron**
   and **pg_net**.
2. Uncomment section 6 of `105_seo_phase1.sql` (the `cron.schedule`
   block) and run that SQL alone in the editor.
3. Verify with `SELECT * FROM cron.job;`.

**Alternative if pg_net not preferred:** trigger from outside via
GitHub Actions or any cron service — POST to
`https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/indexnow-flush`
every 10 min.

### Step 7 — Submit sitemap to Google Search Console

1. Open **GSC → Sitemaps** (under Indexing).
2. Use the existing `app.shopbillpro.in` property (or add it if not present).
3. Enter sitemap URL: `https://app.shopbillpro.in/sitemap-shops.xml`
4. Click **Submit**.
5. Google will process within ~24 hours. Status should change from
   "Couldn't fetch" → "Success" with a discovered URL count.

### Step 8 — (Optional) Submit to Bing Webmaster

If you previously imported the marketing site to Bing Webmaster
via GSC, the app subdomain is a separate property. Add it manually:

1. Open Bing Webmaster Tools.
2. Add site: `https://app.shopbillpro.in/`.
3. Verify ownership (the IndexNow key file in `.well-known` already
   counts as verification proof).
4. Submit `https://app.shopbillpro.in/sitemap-shops.xml`.

IndexNow submissions will auto-feed Bing once the key + sitemap are
both in place.

---

## How the SSR works

```
                  User opens
   app.shopbillpro.in/s/indian-curry
              │
              ▼
       Vercel CDN check
          (5min TTL)
              │
   cache miss │  cache hit → serve cached HTML
              ▼
   Vercel rewrites to:
   ...supabase.co/functions/v1/shop-page?slug=indian-curry
              │
              ▼
       Edge Function:
       1. Read User-Agent
       2. Fetch sbp_resolve_shop_slug RPC
       3. Crawler UA?  ──Yes──► Render full HTML with
              │                  meta + JSON-LD + body
              │                  (return to Vercel)
              │No
              ▼
       Fetch s.html shell (cached in memory)
       Inject meta tags + JSON-LD into <head>
       Return shell with real meta
              │
              ▼
       Vercel caches response 5 min,
       serves stale up to 10 min during revalidation.
              │
              ▼
       User's browser gets shell, JS executes,
       Supabase client fetches shop data,
       client-renders interactive widgets.
       (Same UX as before v8.0.)
```

Crawlers see fully-rendered HTML on first byte. Humans see the same
interactive experience as before, but with correct meta tags so
share previews work.

---

## How IndexNow works

```
   Owner clicks "Publish" in website-builder.html
              │
              ▼
   sbp_set_ai_website_published(true) RPC
              │
              ▼
   Updates sbp_shop_websites.ai_published = true
              │
              ▼
   Calls _sbp_enqueue_indexnow() with:
     • https://app.shopbillpro.in/s/{slug}
     • https://{custom_domain}/  (if connected + active)
              │
              ▼
   Rows inserted into _sbp_indexnow_queue
              │
              ▼
       [waiting for pg_cron / manual flush]
              │
              ▼
   indexnow-flush Edge Function runs:
     1. Pull up to 100 URLs (oldest first)
     2. Group by host
     3. POST each host's URLs to api.indexnow.org/IndexNow
     4. IndexNow verifies our key at
        /.well-known/f8488df6...txt
     5. On 200/202 → delete from queue
     6. On error → increment attempts (max 5)
              │
              ▼
   Bing, Yandex, and (per Nov 2024 docs) Google
   reindex within minutes.
```

---

## Test plan

### Test 1 — Crawler sees real meta
```bash
curl -s -A "Googlebot/2.1" https://app.shopbillpro.in/s/<published-slug> > /tmp/seo-test.html
grep -E "<title>|og:title|og:description|application/ld\+json" /tmp/seo-test.html
```
Expect: real shop name in `<title>`, JSON-LD script tag present, OG tags
filled with shop content.

### Test 2 — WhatsApp/FB preview
1. Share a published shop URL in WhatsApp to yourself.
2. Wait 3-5 seconds for preview card.
3. Expect: shop name, tagline, photo. Not the generic "Shop · ShopBill Pro".

If preview is wrong, paste URL into **Facebook Sharing Debugger**
(developers.facebook.com/tools/debug) and click "Scrape Again".

### Test 3 — Schema.org validation
1. Open Google Rich Results Test: search.google.com/test/rich-results
2. Enter a published shop URL.
3. Expect: "Page is eligible for rich results" with at least
   `LocalBusiness` or its subclass detected.

### Test 4 — Sitemap freshness
```bash
curl -s https://app.shopbillpro.in/sitemap-shops.xml | grep -c "<url>"
```
Expect: one `<url>` per published shop.

### Test 5 — IndexNow flow
1. In website-builder, click Publish on a test shop.
2. Inspect queue:
   ```sql
   SELECT * FROM _sbp_indexnow_queue ORDER BY enqueued_at DESC LIMIT 5;
   ```
   Expect: 1-2 fresh rows (app URL + custom domain if connected).
3. Manually trigger flush:
   ```bash
   curl -X POST https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/indexnow-flush
   ```
   Expect: `{"ok":true,"drained":N,"hosts":1,"results":[{"host":"app.shopbillpro.in","status":200,"count":N}]}`
4. Re-inspect queue — rows should be gone.

### Test 6 — Human flow still works
1. Open a published shop URL in a normal browser.
2. Expect: same interactive UX as before (services pickable,
   gallery scrolls, etc.) — JS is still in control of the body.
3. View page source — expect to see real meta tags in `<head>`
   (not the placeholders). This is what's new.

---

## Caveats + known limitations

- **Edge Function cold starts** add ~150-300ms latency on the first
  request to a particular shop after a quiet period. Vercel CDN caches
  the response for 5 min so this only happens occasionally. If this
  becomes a problem in production we can extend `s-maxage` to 1 hour.

- **AI-mode shops embed `ai_html` directly for crawlers**, bypassing
  the live-site.js wrapper. The placeholders that live-site.js fills in
  (services list, gallery, etc.) will appear as literal `<div data-sbp="services">…</div>` placeholders in the SSR'd HTML. This is fine for SEO
  (text content is still there), but if you want services to render
  in crawler HTML, that's a v8.1 enhancement (fetch services in the
  Edge Function and inject them into the placeholder tags before
  returning).

- **Custom domain SSR uses domain-router.html flow, not this Edge
  Function.** Custom-domain shops will still need the same SEO
  treatment in domain-router — that's planned for v8.1.

- **Sitemap excludes `/s/{slug}` for shops with active custom domain**
  (to avoid duplicate-content signal). The custom-domain URL is the
  canonical and is what appears in the sitemap.

- **`pg_cron` auto-flush is OFF by default.** Until you enable it, the
  queue will grow with each publish but nothing pings IndexNow. Trigger
  manually for now via curl, or enable pg_cron in step 6.

---

## Rollback

If anything breaks:

1. **Revert vercel.json** to the previous version — `/s/:slug` will
   route back to `s.html` (legacy client-side rendering). Loses SSR
   but everything else still works.
2. **Re-run mig 044's** `sbp_set_ai_website_published` definition to
   restore pre-v8.0 publish behavior (no IndexNow enqueue).
3. **Drop the queue table** via the rollback section at the bottom of
   `105_seo_phase1.sql`.
4. Edge Functions can be left deployed — they're idle if vercel.json
   doesn't route to them.

---

## v8.1 follow-ups

- Custom-domain SSR (extend domain-router to call shop-page Edge Function)
- Services / gallery / reservation hours injected into crawler HTML
- Per-shop SEO settings in website-builder (custom title, description, keywords)
- Submit shop sitemap to IndexNow as a sitemap-URL (not just individual URLs)
- Add `<meta name="robots" content="noindex">` to `qr-menu.html` (the
  per-table QR menu page that shouldn't compete with the shop page in SERPs)
- Google Indexing API integration (for shops with structured-data eligible
  pages — JobPosting/Event style)
- GSC URL Inspection API integration to monitor which shop URLs got indexed
