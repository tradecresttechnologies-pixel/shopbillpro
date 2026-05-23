# ShopBill Pro v5 — Single-page polished website

## What this bundle ships

Rolls back the M2 multi-page experiment cleanly and ships a polished single-page architecture with:

- **One excellent single page** per shop (no multi-page navigation complexity)
- **Full-screen modals** for long lists: full menu, all photos, all rooms, all amenities, all stylists, all doctors
- **Heavy motion** with progressive enhancement: parallax, scroll-triggered animations, number counters, smooth scrolling
- **Device-aware**: capable devices get full motion; cheap phones get a clean experience without lag
- **Per-vertical creative freedom**: AI invents vertical-appropriate sections within guardrails
- **All bookings integrate with admin panel**: table reservations, hotel bookings, appointments flow into existing admin RPCs

## DEPLOY ORDER (run exactly in this sequence)

```
1. RUN SQL          097_rollback_to_singlepage.sql
2. RUN SQL          098_website_prompt_v18.sql
3. REPLACE FILE     lib/live-site.js → use lib_live-site-v5.js content
4. REPLACE FILE     s.html
5. REPLACE FILE     website-builder.html
6. DEPLOY EDGE FN   generate-ai-website-v3.11.ts (replaces v3.10)
7. PUSH             GitHub Desktop → Vercel auto-deploys
```

**No new tables. No new RPCs. No admin panel changes.** All changes are additive (live-site.js v5, prompt v18) or reversive (s.html, website-builder.html, Edge Function — go back to single-page model).

## What changed in each file

### 097_rollback_to_singlepage.sql
Deactivates the multi-page prompts (home_multipage, menu, about, gallery, contact). Resets Indian Curry quota for testing. Pages stay in DB but unused.

### 098_website_prompt_v18.sql
Inserts website_v1 v18 with:
- Long single-page spec (5-7 sections, 3-5 screens of scroll)
- Modal trigger buttons `data-sbp-modal="services"` etc.
- Heavy motion data attributes (`data-aos`, `data-sbp-parallax`, `data-sbp-counter`)
- Per-vertical guidance (food/beauty/healthcare/etc.)
- Color/contrast rules preserved
- Real data integration via `data-sbp` placeholders

### lib/live-site.js → v5 (file: lib_live-site-v5.js)
Strictly additive on v4.8 (~20KB added):
- 6 new modals (services, gallery, rooms, amenities, stylists, doctors)
- Modal click handler (`data-sbp-modal` attribute)
- Progressive enhancement (`detectCapability()` → high/medium/low)
- Lazy-loaded AOS (from CDN)
- Number counter animations (IntersectionObserver)
- Parallax effect (IntersectionObserver, high-capability only)
- Smooth-scroll for anchor links
- All v4.8 booking flows preserved unchanged

### s.html
Removes the buggy `business_only` branch in `renderShop()` that referenced undefined variables. Kept `renderBusinessOnlyPage` function for future multi-page reintroduction.

### website-builder.html
Reverts M2 chained generation. Back to single-call `_sb.functions.invoke('generate-ai-website', ...)`. Removes ~6KB of M2 code.

### generate-ai-website-v3.11.ts
Removes multi-page routing. Keeps {SHOP_SLUG} + {PHONE} token substitution from v3.10. Adds phone fallback (direct shops table fetch if state RPC doesn't return phone).

## TEST PLAN (in order)

### Test 1 — Verify rollback worked
After running 097 + 098:
```sql
SELECT version, page_slug, is_active, length(prompt_text) AS bytes
FROM ai_prompt_templates
WHERE name = 'website_v1' AND is_active = true;
```
**Expected:** 1 row → version=18, page_slug='home', is_active=true, bytes ~15000.

### Test 2 — Hard refresh and verify code loaded
1. Open website-builder for any shop
2. Press **Ctrl+Shift+R**
3. F12 → Console → look for: `[live-site v5] device capability: ...`
4. If you see that line, the new code is loaded.

### Test 3 — Generate website
1. Click **Regenerate Website**
2. Wait ~15-30 seconds (single-call now, no per-page progress UI)
3. Toast shows "Website generated! Click Push Live to publish."

### Test 4 — Visit the live site
1. Click Push Live
2. Visit `app.shopbillpro.in/s/<slug>` (e.g. `/s/glitz-glam`)
3. Verify:
   - Hero loads with parallax background
   - Sections animate in as you scroll (AOS effects)
   - Hover on cards lifts them slightly
   - Anchor links in nav smooth-scroll to sections
   - WhatsApp / Call / Directions buttons are present and work
   - "View Full Menu" button exists in the menu section

### Test 5 — Open the modal
1. Click "View Full Menu" (or "View All Photos", etc.)
2. Verify:
   - Full-screen overlay slides up
   - Dim background, modal box centered
   - All menu items render with categories (if categorized)
   - Scroll inside the modal works
   - X button closes the modal
   - Escape key closes the modal
   - Clicking outside the box closes the modal

### Test 6 — Mobile responsive
1. F12 → Toggle device toolbar → iPhone size
2. Reload the public site
3. Verify:
   - No horizontal scroll
   - Hero fits screen, doesn't break
   - Modal slides up from bottom (mobile sheet style)
   - Cards stack vertically
   - Nav adapts (or hides on small screens)

### Test 7 — Progressive enhancement (DevTools throttle)
1. DevTools → Network → throttle to "Slow 3G"
2. Reload public site
3. Verify in Console:
   - `device capability: low` shown
   - Motion library (AOS) does NOT load
   - Page still renders cleanly, just without scroll animations

### Test 8 — Booking flow
1. On public site, click "Reserve a Table" (or vertical-equivalent)
2. Verify the booking modal opens (this is v4.8 booking, should still work)
3. Submit a test booking
4. In admin panel, verify the booking appears in reservations.html

## ROLLBACK PLAN (if v18 generates badly)

If the new prompt produces visually bad output:

```sql
-- Quick rollback to v16 (old single-page prompt):
UPDATE ai_prompt_templates SET is_active = false WHERE name = 'website_v1' AND version = 18;
UPDATE ai_prompt_templates SET is_active = true  WHERE name = 'website_v1' AND version = 16 AND page_slug IS NULL;

-- Then regenerate.
```

If live-site.js v5 has a bug, revert to v4.8:
```bash
git checkout HEAD~1 -- lib/live-site.js
git commit -m "rollback live-site.js to v4.8"
git push
```

## HONEST FLAGS

1. **First-regen variability:** This is the first deploy of prompt v18. AI output may need iteration. If the first generation looks off (wrong colors, missing sections, etc.), tell me what's wrong and I'll iterate the prompt to v19.

2. **Modal data depends on admin data:** Modals fetch from public RPCs that read admin data. If a shop has 0 menu items in `sbp_services`, the services modal shows "No items available yet." That's not a bug — it's a prompt to fill in the admin panel.

3. **Heavy motion is opt-out for low-capability devices:** A user on a cheap Android phone won't see parallax or scroll animations. The page is still beautiful — just static. This is intentional progressive enhancement.

4. **The `sbp_website_pages` table stays:** Unused for now, but kept as infrastructure. If you ever want multi-page Business-tier upsell later, the table is ready. No data is being written to it.

5. **Existing shops with multi-page rows in `sbp_website_pages` are unaffected:** The resolver still returns `legacy_home` (from `ai_generated_html`) for shops not yet regenerated. New regenerations write to `ai_generated_html` only.

## POST-DEPLOY ITERATIONS

After this deploys and is verified:
- If you want different sections per vertical → iterate prompt v18 → v19
- If you want different animation styles → adjust prompt's motion-attribute guidance
- If owners want to toggle visual richness → add `visual_perf_mode` column + settings UI (already planned, not in this bundle to keep scope tight)

This is a foundation. Iterate from here, don't fight it.
