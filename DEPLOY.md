# Batch v4.8a — Hero Photo Background + Prompt v3

**Delivered:** May 14, 2026

## What this batch does

Two big upgrades to AI-generated websites:

1. **Hero photo background.** The first photo from your gallery becomes the hero section's background image, with a dark gradient overlay so the headline and CTA stay readable. Result: your hotel hero now looks like Airbnb instead of a generic gradient.

2. **Prompt v3 fixes 3 known issues** from earlier generations:
   - `data-sbp="info"` is now **mandatory** (was being skipped → no address card visible)
   - Nav links only point to sections that actually exist (no more "Could not load shop" on dead links)
   - Every section gets a proper `id` attribute that nav links can target

## DEPLOY PATHS

```
NEW      db/migrations/054_website_prompt_v3.sql
REPLACE  Edge Function: generate-ai-website  (v3.2 source)
```

**2 files.** SQL migration first, then redeploy edge function via Supabase Dashboard.

---

## Deploy in 3 steps (~5 min)

### Step 1 — Run SQL migration

1. Supabase Dashboard → SQL Editor
2. Paste contents of `054_website_prompt_v3.sql`
3. Run

**Verify:**
```sql
-- Should show v3 active, v1+v2 inactive
SELECT name, version, is_active, left(notes, 60) AS notes
FROM ai_prompt_templates WHERE name='website_v1'
ORDER BY version;

-- Should show: true (prompt contains hero placeholder)
SELECT prompt_text LIKE '%{HERO_IMAGE_URL}%' AS has_hero_placeholder
FROM ai_prompt_templates WHERE name='website_v1' AND is_active=true;

-- Should return hero_image_url + has_gallery for Glitz & Glam
SELECT sbp_get_website_generation_context('73aa8ede-6352-4549-8617-cccacdd5c821');
```

### Step 2 — Redeploy edge function

1. Supabase Dashboard → Edge Functions → `generate-ai-website` → Code tab
2. Replace the entire content with `edge_function_generate-ai-website_v3_2.ts`
3. Click Deploy
4. Wait for "Deployed" confirmation

The function still serves the same URL: `https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/generate-ai-website`. JWT verification stays ON.

### Step 3 — Regenerate Glitz & Glam to see the upgrade

1. Login as Glitz & Glam owner → `/website-builder.html`
2. Make sure section 4 (Gallery) has at least 1 photo (it already does — 6 Unsplash hotel photos from last session)
3. Click **🚀 Generate Website with AI**
4. Wait 15-30 sec
5. Open `/s/glitz-glam` in incognito

**Expected visual changes:**
- Hero now has a real hotel photo as background (first gallery photo)
- Dark gradient overlay on the photo so "A Place Where You Feel Like Home" stays readable
- White text with subtle drop shadow for contrast
- Below the hero: contact section now has a proper info card (address, hours, phone, email) on the left and WhatsApp/Call/Directions buttons on the right
- Nav links (Services, Gallery, Contact) all scroll to real sections — no errors

---

## What changed in prompt v3 vs v2

### New section added to the prompt
- **HERO BACKGROUND IMAGE** — explicit instructions for the AI to use the photo URL with dark overlay, or fall back to gradient if URL is empty/literal

### Strengthened rules
- **Rule 11:** "Nav links are only for existing ids. Never link to a section you haven't rendered."
- **Rule 12:** "All 5 data-sbp placeholders must appear exactly once each."
- **info component:** Now marked `⚠️ MANDATORY — DO NOT SKIP` with reason ("customers can't see address without it")
- **Section ids:** Each required section now has an explicit `id` attribute the nav can target

### Vertical guidance refinements
- Hospitality + elegant style → serif typography hint (Georgia / Times New Roman)
- Healthcare → "NEVER over-promise medical outcomes" emphasized
- Food → "gallery prominent" for food photo emphasis
- Each vertical's section structure clarified

---

## How the hero photo flow works

```
1. Owner uploads photos in /website-builder.html → stored in content_json.gallery
2. Owner clicks Generate
3. Edge function v3.2 fetches the first gallery photo URL via
   sbp_get_website_generation_context(shop_id) → { hero_image_url: "https://..." }
4. Hero URL injected into prompt at {HERO_IMAGE_URL}
5. Claude generates HTML with the URL baked into the hero <section> style
6. HTML stored in sbp_shop_websites.ai_generated_html
7. Customer visits /s/glitz-glam → iframe renders the AI HTML
8. Hero photo loads in customer's browser directly from the gallery URL
```

**Important:** The hero photo is **baked into the HTML at generation time**. If the owner changes the first gallery photo later, they need to regenerate to get a new hero. (We can build "auto-rebake hero on gallery change" in a future batch.)

---

## Fallback behavior

If a shop has zero gallery photos OR the helper RPC fails:

- `sbp_get_website_generation_context` returns `hero_image_url: ""`
- Edge function passes empty string to fillTemplate
- The `{HERO_IMAGE_URL}` placeholder in the prompt becomes `""`
- Prompt has explicit fallback instruction: when URL is empty, use primary→accent gradient instead

So Glitz & Glam will get a real photo hero, but a new shop with no photos uploaded will still get a clean gradient hero. No errors, no broken images.

---

## What stays the same (no behavior change)

- Existing AI-generated websites for any shop continue to work — no regression
- `live-site.js` v4.7 (booking modal from previous batch) unchanged
- `s.html` unchanged
- `website-builder.html` unchanged
- All public RPCs unchanged
- Edge function URL + JWT requirements unchanged

Only newly generated websites (after this batch deploys) get the upgrades.

---

## Known limitations of v4.8a

| Item | Status | Path to fix |
|---|---|---|
| Color picker bug (Orange label → Cyan generation) | Still present | Investigate `website-builder.html` color mapping in v4.8b |
| Vertical-specific design templates (serif fonts for hotels everywhere, menu-card layout for restaurants) | Partial — hinted in prompt | More detailed per-vertical CSS in v4.8b |
| Can't pick *which* gallery photo is the hero | Defaults to first | "⭐ Set as Hero" star button in v4.8b |
| AI sometimes generates "Rooms" nav link with no rooms section | Should be fixed by Rule 11 in prompt v3 — needs verification | Test after deploy |
| Hero photo doesn't update if gallery changes | Requires regeneration | "Auto-rebake hero" cron in v4.9 |

---

## Rollback plan

If something goes wrong:

1. Rollback prompt to v2: `UPDATE ai_prompt_templates SET is_active = (version = 2) WHERE name='website_v1';`
2. Edge function: redeploy `edge_function_generate-ai-website_v3_1.ts` (from previous batch) via Dashboard
3. Existing AI-generated HTML in DB is unchanged — no customer-facing breakage

No data is at risk. The helper RPC `sbp_get_website_generation_context` can be left in place (it's harmless if unused).

---

## Files in this batch

```
Batch_Website_Polish_v4_8a/
├── DEPLOY.md
├── db/
│   └── migrations/
│       └── 054_website_prompt_v3.sql           (12 KB)
└── edge_function_generate-ai-website_v3_2.ts    (12 KB, 337 lines)
```

Total: 2 substantive files. Run SQL → redeploy edge function → regenerate one shop to verify.
