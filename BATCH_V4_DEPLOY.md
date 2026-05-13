# Batch v4 — AI Website Prompt Mastering + Live Components

Transforms the AI Website Builder from "generates a pretty static brochure" into
"generates a properly-designed website connected to ShopBill Pro backend that
shows your real services, contact buttons, gallery, and business info."

---

## DEPLOY PATHS

```
NEW      db/migrations/048_website_prompt_v2.sql
NEW      lib/live-site.js                                    ← repo root /lib/
REPLACE  s.html                                              ← repo root
```

Edge function **does not change** — it reads the active prompt from DB on
every call, so just running migration 048 swaps the prompt for the next
generation. No `supabase functions deploy` needed.

---

## WHAT THIS BATCH CHANGES (in plain English)

### 1. Massively upgraded prompt (`website_v2`)

The new prompt teaches the AI to:
- Use a **component vocabulary** — placeholders like `<div data-sbp="services"></div>` that get hydrated with real shop data
- Follow **vertical-specific guidance** for 8 business types (salon, hotel, healthcare, restaurant, retail, education, services, online brand)
- Apply a **design system** — proper typography clamp scales, mobile-first spacing, hover states, shadow tokens
- Avoid **anti-patterns** — no Lorem Ipsum, no external images, no broken links, no `<script>` tags, no Bootstrap/Tailwind, no over-claiming
- Match the **language** of the description (Hindi → Hindi UI, Hinglish → Hinglish, English → English)

The old prompt was ~30 lines. The new one is ~180 lines of structured guidance. Output quality scales with prompt quality.

### 2. Live components runtime (`lib/live-site.js`)

A small (~14KB) self-contained runtime loaded inside the AI website iframe. It scans for `[data-sbp]` placeholders and replaces them with live data fetched from public RPCs:

| Placeholder | Renders | RPC used |
|---|---|---|
| `<div data-sbp="services"></div>` | Service cards grid with prices | `sbp_get_shop_services_public` |
| `<div data-sbp="contact"></div>` | WhatsApp / Call / Directions buttons | `sbp_resolve_shop_slug` |
| `<div data-sbp="gallery"></div>` | Image grid from content.gallery | `sbp_resolve_shop_slug` |
| `<div data-sbp="info"></div>` | Address + hours + phone card | `sbp_resolve_shop_slug` |
| `<div data-sbp="cta"></div>` | Big "Message on WhatsApp" button | `sbp_resolve_shop_slug` |

Each component:
- Inherits the AI-set `--sbp-primary` and `--sbp-accent` CSS variables for consistent theming
- Has a loading state while fetching
- Handles empty data gracefully (e.g., gallery hides if no images)
- Auto-styles itself with cards, shadows, hover effects, responsive grids
- Logs page views and WhatsApp clicks for analytics

### 3. Iframe sandbox change in `s.html`

**Before:** `sandbox="allow-same-origin allow-popups..."` (no scripts at all — AI HTML was pure static)

**After:** `sandbox="allow-scripts allow-popups allow-popups-to-escape-sandbox allow-forms"` (drops same-origin, adds scripts)

**Why this is more secure**, not less:
- Dropping `allow-same-origin` gives the iframe a **unique opaque origin**
- AI-generated JavaScript still runs (for the live-site.js runtime + any AI scripts)
- BUT it cannot read parent `localStorage`, `cookies`, or `window.parent.*`
- Supabase JS SDK works fine without same-origin — it uses fetch + public anon key
- Both runtime scripts (SDK + live-site.js) are injected by **us**, not by the AI

---

## DEPLOY ORDER

### 1. SQL migration (Supabase SQL Editor)

Run `db/migrations/048_website_prompt_v2.sql`.

Verify:
```sql
SELECT name, version, is_active, left(notes, 50) AS notes
FROM ai_prompt_templates
ORDER BY version;
-- Expected: website_v1 v1 false 'Initial...', website_v1 v2 true 'v2 — ...'
```

### 2. Push frontend files

Copy these into your repo and commit:
```
lib/live-site.js    (new)
s.html              (replace)
```
Push → Vercel auto-deploys.

### 3. Hard refresh anything cached

`Ctrl+Shift+R` on:
- `/admin-websites.html` (to verify v2 is now the active prompt)
- `/s/{your-test-slug}` (to verify live components hydrate)

---

## VERIFY

### Step A — confirm v2 prompt is active

Open `/admin-websites.html` → **Provider & Prompts** tab:
- "Active: website_v1 v2 · …" should show in the prompt-meta line
- The prompt text area should contain "LIVE COMPONENTS" and "VERTICAL-SPECIFIC GUIDANCE" headings

### Step B — generate a new website with v2 prompt

As a test shop owner, open `/website-builder.html`:
1. Click **Generate / Regenerate**
2. Wait ~20-30 sec (v2 prompt is longer → slightly longer generation time)
3. Preview should now contain `data-sbp` placeholders that hydrate into real components

### Step C — open the public page

Visit `/s/{your-slug}`:
1. AI's design loads instantly (static HTML)
2. After ~200-500ms, placeholder boxes fill in:
   - Services section shows your real services with prices
   - Contact section shows working WhatsApp/Call/Directions buttons
   - Gallery shows your uploaded images (or hides if none)
   - Info card shows address/hours/phone with clickable links
3. Open DevTools → Console: should see no errors, only `[live-site]` debug logs

### Step D — security check

In DevTools → Application → Storage:
- Inside the iframe context, `localStorage` should be **empty** (sandboxed origin)
- Parent's `localStorage` should be untouched

---

## ROLLBACK

If the v2 prompt produces worse results than v1:
```sql
UPDATE ai_prompt_templates SET is_active = (version = 1) WHERE name='website_v1';
```
This reactivates v1 instantly — next generation uses old prompt. No code changes needed.

If `live-site.js` breaks something on public pages:
1. Revert `s.html` to the v2 version (with `allow-same-origin` sandbox)
2. AI sites will render statically again — placeholders will show as empty divs but page won't crash
3. Existing non-AI shop pages are unaffected (the AI fork is only triggered when `ai_mode=true`)

---

## KNOWN LIMITATIONS & FUTURE WORK

### Phase 5a v2 (this batch) intentionally leaves out:

- **Full appointment booking widget** — the existing 5-step booking UI in `s.html` is rich; porting it as a `data-sbp="book"` component will be Batch v4.1. For now, businesses that need bookings should use the legacy non-AI shop page.
- **Product catalog grid** — `data-sbp="products"` for retail/restaurant menus. Adds in v4.2.
- **Room types component** — `data-sbp="rooms"` for hospitality. Adds in v4.2.
- **Multi-page sites** — currently AI generates single-page. Multi-page (`/services`, `/about`) is a bigger architectural shift.
- **Inline edit of generated content** — admin can replace via re-generation, but can't tweak individual sections inline yet.

### Things to monitor after deploy:

1. **Generation cost** — v2 prompt is longer, expect ~300 more input tokens per generation. At Claude Sonnet 4 pricing ($3/M input) that's an extra ~$0.001 per generation. Negligible.
2. **Generation time** — slightly longer (~25-35 sec vs 15-25 sec) due to longer prompt + larger output. Acceptable.
3. **Failure rate** — AI might occasionally generate placeholders it invents (e.g. `data-sbp="testimonials"` which doesn't exist). live-site.js logs a warning and leaves them empty — safe to ignore. If a specific phantom placeholder keeps appearing, we can add it as a real component.
4. **AI dropping data-sbp placeholders entirely** — some generations may produce 100% static HTML with no placeholders. If this happens >20% of the time, the prompt needs an even stronger emphasis on using them. Check the admin **Generations** tab for samples.

---

## ARCHITECTURE SUMMARY (for future-you reference)

```
┌────────────────────────────────────────────────────────────────┐
│ /s/{slug}  (s.html, ai_mode=true)                              │
│ ┌────────────────────────────────────────────────────────────┐ │
│ │ <iframe sandbox="allow-scripts ...">                       │ │
│ │ ┌────────────────────────────────────────────────────────┐ │ │
│ │ │ srcdoc = ai_html + runtime block                       │ │ │
│ │ │ ─────────────────────────────────────────────────────  │ │ │
│ │ │ <html>                                                 │ │ │
│ │ │   AI-generated HTML with <div data-sbp="..."></div>    │ │ │
│ │ │   placeholders                                          │ │ │
│ │ │ </body>                                                 │ │ │
│ │ │ ★ window.__SBP_{SLUG,URL,KEY} injected here            │ │ │
│ │ │ ★ supabase-js SDK loaded from CDN                       │ │ │
│ │ │ ★ /lib/live-site.js loaded → hydrates placeholders     │ │ │
│ │ │ </html>                                                 │ │ │
│ │ └────────────────────────────────────────────────────────┘ │ │
│ └────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
                          │  RPC calls (fetch + anon key)
                          ▼
┌────────────────────────────────────────────────────────────────┐
│ Supabase (public RPCs, GRANTed to anon)                         │
│ • sbp_resolve_shop_slug(slug)        → shop info + content     │
│ • sbp_get_shop_services_public(slug) → services list           │
│ • sbp_log_shop_page_view(slug)       → analytics               │
│ • sbp_log_whatsapp_click(slug)       → analytics               │
└────────────────────────────────────────────────────────────────┘
```

Reply once tested. Next priority remains **Razorpay** (which will also benefit from the Vault migration pattern we built in v3.3).
