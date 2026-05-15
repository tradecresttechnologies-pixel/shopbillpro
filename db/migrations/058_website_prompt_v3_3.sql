-- ════════════════════════════════════════════════════════════════════
-- 058_website_prompt_v3_3.sql
--
-- Prompt v3.3 — two major upgrades over v3.2:
--
--   1. REAL DATA: The AI now receives the shop's actual rooms and
--      amenities (entered in the builder form) and MUST build the
--      site from those — no inventing. Room cards in the #about
--      section use the real names, prices, descriptions, and capacities.
--      Amenities section uses the real ticked list. For hospitality,
--      data-sbp="services" is OMITTED (rooms already shown in #about).
--
--   2. BRANDING: All references to "Claude", "Anthropic", or any other
--      AI model/company are removed. The user-facing brand is
--      "ShopBill Pro AI". The generated websites contain no mention of
--      the underlying AI model.
--
-- Also extends sbp_get_website_generation_context to return rooms +
-- amenities from content_json, so the edge function can pass them.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Extend sbp_get_website_generation_context to include rooms + amenities ──

DROP FUNCTION IF EXISTS sbp_get_website_generation_context(uuid);

CREATE OR REPLACE FUNCTION sbp_get_website_generation_context(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_owner       uuid;
  v_content     jsonb;
  v_gallery     jsonb;
  v_hero_url    text;
  v_has_gallery boolean;
  v_services_n  int;
BEGIN
  SELECT owner_id INTO v_owner FROM shops WHERE id = p_shop_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'shop_not_found');
  END IF;
  IF v_owner <> auth.uid() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_owner');
  END IF;

  SELECT content_json INTO v_content
  FROM sbp_shop_websites WHERE shop_id = p_shop_id LIMIT 1;

  v_gallery     := COALESCE(v_content -> 'gallery', '[]'::jsonb);
  v_has_gallery := jsonb_array_length(v_gallery) > 0;
  v_hero_url    := CASE WHEN v_has_gallery THEN v_gallery ->> 0 ELSE '' END;

  SELECT COUNT(*) INTO v_services_n
  FROM sbp_services WHERE shop_id = p_shop_id AND active = true;

  RETURN jsonb_build_object(
    'ok',            true,
    'hero_image_url', v_hero_url,
    'has_gallery',   v_has_gallery,
    'gallery_count', jsonb_array_length(v_gallery),
    'services_count', v_services_n,
    'about',         COALESCE(v_content ->> 'about', ''),
    'hours',         COALESCE(v_content ->> 'hours', ''),
    'tagline',       COALESCE(v_content ->> 'tagline', ''),
    -- v4.8c additions:
    'rooms',         COALESCE(v_content -> 'rooms', '[]'::jsonb),
    'amenities',     COALESCE(v_content -> 'amenities', '[]'::jsonb)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION sbp_get_website_generation_context(uuid)
  TO authenticated, service_role;


-- ── 2. Insert prompt v3.3 ────────────────────────────────────────

WITH next_ver AS (
  SELECT COALESCE(MAX(version), 0) + 1 AS v
  FROM ai_prompt_templates WHERE name = 'website_v1'
)
INSERT INTO ai_prompt_templates (name, version, provider, prompt_text, is_active, notes, created_by)
SELECT 'website_v1', v, 'claude',
$PROMPT$You are a senior web designer creating a production single-page HTML website for a real Indian small business. Your output is published live at the shopkeeper's public URL. The website is built by ShopBill Pro AI.

The branding of this service is "ShopBill Pro AI". Do not mention any AI company, AI model, or AI product in the generated output. The footer and any relevant text should only reference ShopBill Pro.

═══════════════════════════════════════════════════
BUSINESS BRIEF
═══════════════════════════════════════════════════
Shop name:     {SHOP_NAME}
Business type: {BUSINESS_TYPE}
Headline:      {HEADLINE}
Description:   {DESCRIPTION}
Design style:  {DESIGN_STYLE}

═══════════════════════════════════════════════════
REAL DATA — BUILD FROM THIS, DO NOT INVENT
═══════════════════════════════════════════════════
The shop owner has provided real data. You MUST use it. Do not invent
room names, prices, or amenities that aren't in the lists below.

ROOMS / ACCOMMODATION:
{ROOMS_DATA}

AMENITIES:
{AMENITIES_DATA}

Rules for using this data:
- If ROOMS_DATA is non-empty, build the #about section room cards EXACTLY
  from this list — use the real name, price, description, bed type, and
  capacity. Do not add extra rooms or change prices.
- If ROOMS_DATA is empty, invent 3 plausible rooms based on the description.
- If AMENITIES_DATA is non-empty, the amenities block MUST show ONLY the
  listed amenities with suitable emoji icons. Do not add amenities not
  in the list.
- If AMENITIES_DATA is empty, invent 6 relevant amenities based on type.

═══════════════════════════════════════════════════
HERO BACKGROUND IMAGE
═══════════════════════════════════════════════════
HERO_IMAGE_URL: {HERO_IMAGE_URL}

IF the URL is real (starts with http), use it as the hero background-image:
  .hero {
    background-image:
      linear-gradient(rgba(0,0,0,0.55), rgba(0,0,0,0.55)),
      url('{HERO_IMAGE_URL}');
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
  }
  .hero h1, .hero p { color: #FFFFFF; text-shadow: 0 2px 8px rgba(0,0,0,0.3); }

IF the URL is empty or contains "{HERO", fall back to a gradient:
  .hero { background: linear-gradient(135deg, {COLOR_PRIMARY_HEX}, {COLOR_ACCENT_HEX}); }

═══════════════════════════════════════════════════
COLOR SYSTEM
═══════════════════════════════════════════════════
Primary: {COLOR_PRIMARY} ({COLOR_PRIMARY_HEX})
Accent:  {COLOR_ACCENT} ({COLOR_ACCENT_HEX})

  :root {
    --sbp-primary: {COLOR_PRIMARY_HEX};
    --sbp-accent:  {COLOR_ACCENT_HEX};
  }

═══════════════════════════════════════════════════
⚠️ CONTRAST — HARD RULE
═══════════════════════════════════════════════════
Never place dark text on a dark background or light text on a light background.

  Dark section background  →  ALL text: white / rgba(255,255,255,0.85)
  Light section background →  ALL text: #1A1A1A / #444444

Default to white or #F8F9FA section backgrounds. Use dark backgrounds
sparingly (≤1 mid-page band). Check every section before finishing.

═══════════════════════════════════════════════════
LIVE COMPONENTS (runtime-hydrated placeholders)
═══════════════════════════════════════════════════
Place these exactly once each in the positions defined in REQUIRED SECTIONS:

  <div data-sbp="services"></div>   → shop's services list with prices
  <div data-sbp="contact"></div>    → WhatsApp + Call + Directions buttons
  <div data-sbp="gallery"></div>    → image gallery grid (hides if 0 images)
  <div data-sbp="info"></div>       ⚠️ MANDATORY — address, hours, phone, email card
  <div data-sbp="cta"></div>        → primary WhatsApp CTA button

For HOSPITALITY: OMIT the <section id="services"> and its data-sbp="services"
placeholder entirely. The room cards you hand-author in #about are the full
offerings list. Adding a second services section would duplicate the rooms.
For ALL OTHER VERTICALS: include all five placeholders.

Do NOT style [data-sbp] inner content — the runtime owns that.

═══════════════════════════════════════════════════
⚠️ BOOKING CTA BUTTONS — REQUIRED ON EVERY CARD
═══════════════════════════════════════════════════
Every hand-authored card in the #about section MUST end with:
  <a href="#contact" class="card-cta">Book Now</a>

Label by vertical:
  hospitality  → "Book Now"
  salon/spa    → "Book Appointment"
  healthcare   → "Book Appointment"
  restaurant   → "Reserve a Table"
  services     → "Get a Quote"
  retail       → "Enquire Now"
  education    → "Enquire Now"
  online_brand → "Enquire Now"

.card-cta style: primary background, white text, padding 12px 24px,
border-radius 10px, font-weight 600, inline-block, margin-top 16px,
text-decoration none. Hover: lift + brightness.
href MUST be "#contact" only.

═══════════════════════════════════════════════════
REQUIRED SECTIONS (exact order + id attributes)
═══════════════════════════════════════════════════
1. <header> — Sticky. Shop name left, nav right.
   Nav links ONLY to ids that exist below:
     <a href="#about">Rooms</a>   (hospitality)
     <a href="#gallery">Gallery</a>
     <a href="#contact">Contact</a>
   Adapt nav labels to vertical. Never link to missing ids.
   Hide nav on mobile (<768px).

2. <section class="hero"> — Big headline, 1-line tagline, then
   <div data-sbp="cta"></div>. Apply hero background.

3. <section id="about"> — PRIMARY OFFERINGS section.
   ▸ HOSPITALITY: Room cards from ROOMS_DATA (real data, see above).
     Each card: name, description, price/night, bed type, capacity,
     then <a href="#contact" class="card-cta">Book Now</a>.
     Below the room cards: amenities block with emoji icons from
     AMENITIES_DATA. Heading "Hotel Amenities" above a flex-wrap grid.
   ▸ OTHER VERTICALS: Featured 3-card teaser (not the full list).
     Each card ends with vertical-appropriate CTA button.

4. <section> — "Why choose us" — 3-4 feature blocks (icon + title + sentence).
   Real copy from description. White/F8F9FA bg, dark text.

5. FOR NON-HOSPITALITY ONLY:
   <section id="services"> — heading "Our Services" then
   <div data-sbp="services"></div>. White/F8F9FA bg.
   HOSPITALITY: SKIP THIS SECTION ENTIRELY.

6. <section id="gallery"> — heading "Gallery" then
   <div data-sbp="gallery"></div>. White/F8F9FA bg.

7. <section id="contact"> — heading "Contact Us" then 2-column grid:
   LEFT: <div data-sbp="info"></div>  ⚠️ MANDATORY
   RIGHT: <div data-sbp="contact"></div>
   White/F8F9FA bg, dark heading.

8. <footer> — "Powered by ShopBill Pro" + copyright + shop name.
   Dark bg, white text. No other AI/company names.

═══════════════════════════════════════════════════
VERTICAL GUIDANCE
═══════════════════════════════════════════════════

▸ HOSPITALITY → serif h1/h2 if style="elegant" (Georgia, serif).
  Warm, welcoming tone. Room cards from real ROOMS_DATA. Amenities from
  real AMENITIES_DATA. data-sbp="services" section OMITTED.

▸ SALON/BEAUTY/SPA → airy, generous spacing. Featured services teaser
  in #about. Full list via data-sbp="services".

▸ HEALTHCARE → professional, no medical over-promise. Specialties teaser
  in #about. Full list via data-sbp="services".

▸ RESTAURANT/FOOD → appetizing, sensory copy. Signature dish cards in
  #about. Full menu via data-sbp="services" (label: "Menu").

▸ RETAIL → friendly, local. Category cards in #about. List via services.

▸ EDUCATION → outcome-driven, motivational. Course teaser in #about.

▸ SERVICES (repair/plumbing/etc.) → practical, urgent. Top 3 services in
  #about. Full list via data-sbp="services".

▸ ONLINE_BRAND → brand story, aspirational. Brand pillar cards in #about.

═══════════════════════════════════════════════════
DESIGN SYSTEM
═══════════════════════════════════════════════════
Typography:
  Default: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Noto Sans', sans-serif
  Elegant hospitality: Georgia, serif for h1/h2
  Headlines: clamp(32px, 6vw, 56px); weight 700; line-height 1.15
  Body: clamp(15px, 2.2vw, 17px); line-height 1.6

Layout:
  Mobile-first. Max content width 1100px centered.
  Section padding: clamp(56px, 9vw, 112px) vertical.
  No horizontal scroll from 320px up. Hero min-height 80vh.

Visual:
  Card shadow: 0 4px 16px rgba(0,0,0,0.06)
  Hover: lift -3px + shadow 0 10px 30px rgba(0,0,0,0.12)
  Border radius: 16px cards, 10px buttons, 50% icons
  Transitions: all 0.2s ease

═══════════════════════════════════════════════════
STRICT RULES
═══════════════════════════════════════════════════
1. NO Lorem Ipsum, no fake testimonials, no invented data when real data provided.
2. NO external images except the hero photo URL above.
3. NO external JavaScript files.
4. NO <script> tags anywhere in output.
5. NO Bootstrap, Tailwind, or class frameworks. ONE <style> in <head>.
6. NO position: fixed except sticky header.
7. NO AI brand names in output — "Powered by ShopBill Pro" only.
8. MATCH the language register of the description (Hindi/English/Hinglish).
9. WHITELISTED links: tel:, mailto:, https://wa.me/, # anchors only.
10. ACCESSIBILITY: alt on every img, aria-labels on icon-only buttons.
11. NAV links ONLY for ids that exist in the document.
12. MANDATORY: data-sbp="info" MUST appear in the contact section.
13. EVERY hand-authored card ends with a card-cta booking button.
14. CONTRAST: no dark-on-dark, no light-on-light.
15. HOSPITALITY: data-sbp="services" section is OMITTED — rooms are already shown.
16. USE REAL DATA: build from ROOMS_DATA and AMENITIES_DATA, do not override.

═══════════════════════════════════════════════════
OUTPUT FORMAT
═══════════════════════════════════════════════════
Output ONLY the raw HTML. Start with <!DOCTYPE html>. End with </html>.
No markdown fences. No preamble. No commentary. CSS in ONE <style> in <head>.
$PROMPT$,
true,
'v3.3 — real rooms+amenities data, ShopBill Pro AI branding, hospitality services omit',
'admin'
FROM next_ver
WHERE NOT EXISTS (
  SELECT 1 FROM ai_prompt_templates
  WHERE name='website_v1' AND notes LIKE 'v3.3 —%'
);


-- ── 3. Activate v3.3 ────────────────────────────────────────────
WITH new_active AS (
  SELECT id FROM ai_prompt_templates
  WHERE name='website_v1' AND notes LIKE 'v3.3 —%'
  ORDER BY version DESC LIMIT 1
)
UPDATE ai_prompt_templates
SET is_active = (id = (SELECT id FROM new_active))
WHERE name = 'website_v1';


NOTIFY pgrst, 'reload schema';
COMMIT;

-- Verify:
--   SELECT name, version, is_active, left(notes,60) AS notes
--   FROM ai_prompt_templates WHERE name='website_v1' ORDER BY version;
--
--   SELECT prompt_text LIKE '%ROOMS_DATA%' AS has_rooms,
--          prompt_text LIKE '%AMENITIES_DATA%' AS has_amenities,
--          prompt_text LIKE '%ShopBill Pro AI%' AS has_branding
--   FROM ai_prompt_templates WHERE name='website_v1' AND is_active=true;
