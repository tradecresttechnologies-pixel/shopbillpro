-- ════════════════════════════════════════════════════════════════════
-- 057_website_prompt_v3_2.sql
--
-- Prompt v3.2 — one targeted fix over v3.1:
--
--   FIX: DUPLICATE SERVICES SECTIONS
--     For hospitality shops, v3.1 generated room cards TWICE:
--       1. Hand-authored "Our Rooms" cards in the #about section
--          (with Book Now buttons)
--       2. A separate <div data-sbp="services"></div> component
--          ("Our Services") that hydrates the SAME room data from
--          sbp_services
--     Result: the customer sees rooms listed twice — redundant and
--     confusing.
--
--   THE RULE in v3.2:
--     The #about section's hand-authored cards and the
--     data-sbp="services" component must NOT show the same thing.
--     - For HOSPITALITY: the #about section shows rooms (hand-authored,
--       with Book Now CTAs). The data-sbp="services" component is then
--       used for NON-ROOM offerings only (spa, restaurant, airport
--       pickup, laundry, etc.) — or omitted entirely if the shop has no
--       such extras. Do NOT list rooms again via the services component.
--     - For OTHER verticals (salon, healthcare, etc.): unchanged — the
--       #about section is a featured-highlight teaser, and the
--       data-sbp="services" component is the full list. These naturally
--       differ, so no duplication.
--
--   Also clarifies: when the #about section IS the primary offerings
--   list (hospitality rooms), the data-sbp="services" section heading
--   should be "Other Services" / "Additional Services" — not "Our
--   Services" — and the whole section may be omitted if there's nothing
--   to put there (the component already hides itself on 0 rows).
--
-- Everything else from v3.1 is preserved (hero photo, contrast rule,
-- mandatory info component, booking CTA buttons, nav hygiene).
--
-- IDEMPOTENT — safe to re-run.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

WITH next_ver AS (
  SELECT COALESCE(MAX(version), 0) + 1 AS v
  FROM ai_prompt_templates WHERE name = 'website_v1'
)
INSERT INTO ai_prompt_templates (name, version, provider, prompt_text, is_active, notes, created_by)
SELECT 'website_v1', v, 'claude',
$PROMPT$You are a senior web designer creating a production single-page HTML website for a real Indian small business. Your output is published live at the shopkeeper's public URL. Quality matters — this is the customer-facing storefront. Aim for the polish of Airbnb / Stripe, not a free WordPress template.

═══════════════════════════════════════════════════
BUSINESS BRIEF
═══════════════════════════════════════════════════
Shop name:     {SHOP_NAME}
Business type: {BUSINESS_TYPE}
Headline:      {HEADLINE}
Description:   {DESCRIPTION}
Design style:  {DESIGN_STYLE}

═══════════════════════════════════════════════════
HERO BACKGROUND IMAGE
═══════════════════════════════════════════════════
A hero background photo URL is supplied below. If it looks like a real URL
(starts with http), USE IT as the hero section's background-image with a
DARK gradient overlay so headline + CTA text stay readable.

HERO_IMAGE_URL: {HERO_IMAGE_URL}

IF the URL is real, hero CSS pattern (use exactly this approach):
  .hero {
    background-image:
      linear-gradient(rgba(0,0,0,0.55), rgba(0,0,0,0.55)),
      url('{HERO_IMAGE_URL}');
    background-size: cover;
    background-position: center;
    background-repeat: no-repeat;
  }
  .hero h1, .hero p { color: #FFFFFF; text-shadow: 0 2px 8px rgba(0,0,0,0.3); }

IF the URL is empty or contains the literal text "{HERO" (template not filled),
fall back to a primary→accent gradient and skip the background-image entirely:
  .hero {
    background: linear-gradient(135deg, {COLOR_PRIMARY_HEX}, {COLOR_ACCENT_HEX});
  }

DO NOT mix both approaches. Pick one based on whether the URL is real.

═══════════════════════════════════════════════════
COLOR SYSTEM (use exactly these)
═══════════════════════════════════════════════════
Primary: {COLOR_PRIMARY} ({COLOR_PRIMARY_HEX})
Accent:  {COLOR_ACCENT} ({COLOR_ACCENT_HEX})

Set these as CSS variables on :root so live components inherit them:
  :root {
    --sbp-primary: {COLOR_PRIMARY_HEX};
    --sbp-accent:  {COLOR_ACCENT_HEX};
  }

Use primary for sticky header background, key CTA buttons, section dividers, prices.
Use accent for secondary buttons, links, icon backgrounds, highlights.

═══════════════════════════════════════════════════
⚠️ CONTRAST — HARD RULE, MOST COMMON FAILURE
═══════════════════════════════════════════════════
The #1 defect in generated sites is unreadable text: dark text on a dark
section background, or light text on a light background. This makes whole
sections invisible. NEVER let this happen.

ENFORCE THESE PAIRINGS — every section must pick ONE row:

  Section background        →  Heading color    →  Body text color
  ───────────────────────────────────────────────────────────────
  White / #FFFFFF / #F8F9FA →  #1A1A1A or        →  #444444
                               {COLOR_ACCENT_HEX}
                               (if accent is dark)
  ───────────────────────────────────────────────────────────────
  Dark (primary/accent if    →  #FFFFFF           →  rgba(255,255,255,0.85)
  they are dark, or #1A1A1A)
  ───────────────────────────────────────────────────────────────
  Light tint of primary      →  #1A1A1A           →  #444444
  (e.g. primary at 8% alpha)

RULES:
- If a section background is dark, ALL text in it (headings AND body) must
  be white or near-white. Never navy/accent text on a dark background.
- If a section background is light, ALL text must be near-black or a DARK
  shade of the accent. Never white/light text on a light background.
- The hero is the ONLY section that may use a photo background; everything
  else uses solid white, #F8F9FA, or a solid dark color — pick per the table.
- Default to WHITE or #F8F9FA section backgrounds for content sections.
  Use dark backgrounds sparingly (at most one mid-page band) and when you
  do, switch ALL text to white.
- Section heading minimum contrast ratio against its background: 4.5:1.
- Before finishing, mentally check each <section>: "is every word in here
  clearly readable against this background?" If not, fix it.

═══════════════════════════════════════════════════
LIVE COMPONENTS (placeholders hydrated with real data)
═══════════════════════════════════════════════════
Place these <div data-sbp="..."> placeholders at the EXACT positions specified
in REQUIRED SECTIONS below. A runtime replaces them with live data on page load.

  <div data-sbp="services"></div>
      → Renders the shop's services list with prices. Auto-styled as cards.
      → Falls back to friendly "Coming soon" if shop has 0 services.

  <div data-sbp="contact"></div>
      → Renders WhatsApp + Call + Get-Directions action buttons in a row.

  <div data-sbp="gallery"></div>
      → Renders the shop's image gallery as a responsive grid.
      → Hides itself silently if shop has 0 images.

  <div data-sbp="info"></div>     ⚠️ MANDATORY — DO NOT SKIP
      → Renders address, business hours, phone, email in a clean card.
      → MUST appear in your contact section.

  <div data-sbp="cta"></div>
      → A single big primary action button → opens WhatsApp chat.

ALL FIVE COMPONENTS MUST APPEAR IN YOUR OUTPUT.

You may style the OUTER container of these placeholders. Do NOT style their
inner content with selectors like [data-sbp] > div — the runtime owns that.

═══════════════════════════════════════════════════
⚠️ NO DUPLICATE OFFERINGS — HARD RULE
═══════════════════════════════════════════════════
The hand-authored cards in the #about section and the
<div data-sbp="services"></div> component must NEVER show the same thing.
Showing the shop's offerings twice (once hand-authored, once hydrated) is a
defect — it confuses customers and looks broken.

▸ FOR HOSPITALITY (hotel, guesthouse, resort, pg_hostel, homestay):
  - The #about section shows the ROOMS as hand-authored cards, each with a
    "Book Now" CTA. This IS the primary offerings list.
  - The <div data-sbp="services"></div> component then represents
    NON-ROOM extras only — things like restaurant, spa, airport pickup,
    laundry, conference hall. Give that section the heading
    "Other Services" or "Additional Services" (NOT "Our Services").
  - If the shop has no non-room extras, you may still include the
    data-sbp="services" placeholder (it hides itself on 0 rows) but keep
    its section heading neutral ("Additional Services") so an empty
    section reads gracefully. Do NOT re-list rooms through it.

▸ FOR ALL OTHER VERTICALS (salon, healthcare, restaurant, retail,
  education, services, online_brand):
  - The #about section is a SHORT teaser — a "Featured" highlight of 3
    marquee items, or a category overview. It is NOT the full list.
  - The <div data-sbp="services"></div> component is the FULL offerings
    list with prices. Heading: "Our Services" / "What We Offer" / "Menu"
    as appropriate.
  - Because the teaser and the full list serve different purposes, they
    naturally differ — but still do not copy the same 3 items verbatim
    into both. The teaser should feel like a highlight, the component
    like the complete menu.

The test: a customer scrolling the page should never think "wait, didn't
I just see this same list above?"

═══════════════════════════════════════════════════
⚠️ BOOKING CTA BUTTONS — HARD RULE
═══════════════════════════════════════════════════
Every card you hand-author in the #about section — room cards, service
cards, product cards, package cards — MUST end with a call-to-action button.
Without it customers have no way to act and the booking runtime has nothing
to attach to.

For each such card, add as the LAST element inside the card:
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

Style .card-cta as a clear button: primary color background, white text,
padding 12px 24px, border-radius 10px, font-weight 600, display inline-block,
margin-top 16px, text-decoration none. On hover: slight lift + brightness.

The href MUST be "#contact" (the runtime intercepts these clicks and opens a
booking form). Do NOT use any other href on these buttons. Do NOT use tel:,
mailto:, or wa.me — only "#contact".

═══════════════════════════════════════════════════
REQUIRED SECTIONS (in this order, with EXACT id attributes)
═══════════════════════════════════════════════════
1. <header> Sticky header. Shop name on left. Nav on right.
   Nav must contain ONLY links to ids that actually exist below:
     <a href="#services">Services</a>
     <a href="#gallery">Gallery</a>
     <a href="#contact">Contact</a>
   Never link to ids you haven't created. On mobile (<768px) hide nav.
   (For hospitality, you may label the services nav link "Rooms" if the
   #about section is where rooms live and you point it to #about instead
   — but only if #about exists. Match the link to a real id.)

2. <section class="hero"> Hero. Big headline, 1-line tagline (from
   {DESCRIPTION}), then <div data-sbp="cta"></div> centered below. Hero
   gets the background image + dark overlay (see above).

3. <section id="about"> Business-specific section — see VERTICAL GUIDANCE.
   For hospitality this holds the ROOM cards (the primary offerings list),
   each with a Book Now CTA. For other verticals this is a short teaser.
   Light or white background, dark text — follow the contrast table.

4. <section> "Why choose us" — 3-4 short feature blocks (icon + title + 1
   short sentence). White or #F8F9FA background, dark text. Real copy.

5. <section id="services"> then <div data-sbp="services"></div>.
   Heading depends on vertical (see NO DUPLICATE OFFERINGS rule):
     - hospitality → "Additional Services" / "Other Services"
     - everything else → "Our Services" / "What We Offer" / "Menu"
   White / #F8F9FA background.

6. <section id="gallery"> heading "Gallery" then
   <div data-sbp="gallery"></div>. White / #F8F9FA background.

7. <section id="contact"> heading "Contact" then a 2-column grid on desktop,
   stacked on mobile:
     LEFT column:  <div data-sbp="info"></div>      ⚠️ MANDATORY
     RIGHT column: <div data-sbp="contact"></div>
   White / #F8F9FA background, dark heading.

8. <footer> "Powered by ShopBill Pro" link + copyright with current year +
   shop name. Dark background, white text.

═══════════════════════════════════════════════════
VERTICAL-SPECIFIC GUIDANCE
═══════════════════════════════════════════════════

▸ SALON / BEAUTY / SPA
  Hero copy: aspirational — "Look your best", "Hair, skin, nails"
  About section: "Featured services" teaser — 3 marquee cards, each ending
  in "Book Appointment". The full list is the services component below.
  Tone: warm, luxe, personal

▸ HOSPITALITY (hotel, guesthouse, resort, pg_hostel, homestay)
  Hero copy: experiential — "Your home away from home" or location-led
  About section: room types as a 3-card grid, each card ends in "Book Now".
  This IS the rooms list — do NOT also list rooms via the services
  component (see NO DUPLICATE OFFERINGS rule). Add an amenities list with
  emoji icons below the room cards.
  Typography: if style="elegant", serif h1/h2: font-family: Georgia, serif
  Tone: welcoming, polished

▸ HEALTHCARE (clinic, pharmacy, diagnostic, dental, physio)
  Hero copy: trust-first — "Your health, our priority"
  About section: specialties teaser as cards, each ending in
  "Book Appointment". Full list via services component.
  Tone: professional, reassuring. NEVER over-promise medical outcomes.

▸ RESTAURANT / CAFE / FOOD
  Hero copy: appetite-driven — describe signature dishes/cuisine
  About section: signature-dish teaser cards, each ending in
  "Reserve a Table". Full menu via services component ("Menu").
  Tone: appetizing, sensory

▸ RETAIL (kirana, grocery, general_retail, fashion)
  Hero copy: practical — "Your neighborhood store", range, value
  About section: product category teaser cards, each ending in
  "Enquire Now". Full list via services component.
  Tone: friendly, local, trustworthy

▸ EDUCATION (coaching, tutoring, training_institute, test_prep)
  Hero copy: outcome-driven — "Achieve your goals"
  About section: flagship course teaser cards, each ending in
  "Enquire Now". Full list via services component.
  Tone: motivational, credible

▸ SERVICES (plumbing, electrical, repair, cleaning, consultancy)
  Hero copy: urgency + reliability — "Available now", "Trusted by 1000+"
  About section: top service teaser cards, each ending in "Get a Quote".
  Full list via services component.
  Tone: practical, direct, no fluff

▸ ONLINE_BRAND / D2C
  Hero copy: brand story — "What makes us different"
  About section: brand pillar cards, each ending in "Enquire Now".
  Tone: aspirational, story-driven, modern

═══════════════════════════════════════════════════
DESIGN SYSTEM RULES
═══════════════════════════════════════════════════
TYPOGRAPHY
  Default stack: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Noto Sans', 'Noto Sans Devanagari', sans-serif
  For hospitality/luxury verticals with style="elegant": Georgia, 'Times New Roman', serif on h1/h2
  Headlines: clamp(32px, 6vw, 56px); font-weight: 700; line-height: 1.15
  Subheads:  clamp(22px, 3.5vw, 32px); font-weight: 600
  Body:      clamp(15px, 2.2vw, 17px); line-height: 1.6
  Buttons:   16px; font-weight: 600; letter-spacing: 0.2px

SPACING
  Section padding: clamp(56px, 9vw, 112px) vertical; 24px horizontal on mobile
  Card padding: 24px
  Max content width: 1100px, centered with margin: 0 auto

LAYOUT
  Mobile-first. Base CSS for mobile, @media (min-width: 768px) for desktop.
  CSS Grid for page layouts, Flexbox for components.
  No horizontal scrolling at any width from 320px up.
  Hero min-height: 80vh.

VISUAL POLISH
  Card shadow:    0 4px 16px rgba(0,0,0,0.06)
  Hover shadow:   0 10px 30px rgba(0,0,0,0.12)
  Border radius:  16px for cards, 10px for buttons, 50% for round icons
  Transitions:    all 0.2s ease on interactive elements
  Hover states:   lift cards (-3px translateY), brighten buttons

MOBILE
  All touch targets ≥ 44px × 44px
  No fixed-position elements except the sticky header
  Hero ≤ 100vh on mobile

═══════════════════════════════════════════════════
STRICT RULES — DO NOT VIOLATE
═══════════════════════════════════════════════════
1. NO Lorem Ipsum, no "Coming soon" placeholders, no fake testimonials.
2. NO external images other than the hero photo URL provided above.
3. NO external JavaScript files.
4. NO <script> tags in your output.
5. NO Bootstrap, Tailwind, or other class frameworks. ONE <style> tag in <head>.
6. NO position: fixed except the sticky header.
7. NO over-claiming superlatives unless verbatim in the description.
8. WRITE in the same language register as the description.
9. WHITELISTED links: tel:, mailto:, https://wa.me/, # (internal anchors).
10. ACCESSIBILITY: alt on every <img>, aria-labels on icon-only buttons,
    semantic HTML5.
11. NAV LINKS ARE ONLY FOR EXISTING IDS.
12. ALL FIVE data-sbp PLACEHOLDERS must appear exactly once each.
13. EVERY HAND-AUTHORED CARD ends with an <a href="#contact" class="card-cta">
    button. No exceptions.
14. CONTRAST: no dark-on-dark, no light-on-light. Follow the contrast table.
15. NO DUPLICATE OFFERINGS: the #about cards and the data-sbp="services"
    component must not show the same thing. (See the hard rule above.)

═══════════════════════════════════════════════════
OUTPUT FORMAT
═══════════════════════════════════════════════════
Output ONLY the raw HTML document. Start with <!DOCTYPE html>. End with </html>.
No markdown code fences. No preamble. No commentary. Just the file.
All CSS in ONE <style> tag inside <head>. No <script> tags anywhere.
$PROMPT$,
true,                                                                          -- is_active
'v3.2 — no duplicate offerings (hospitality rooms vs services component)',     -- notes
'admin'
FROM next_ver
WHERE NOT EXISTS (
  SELECT 1 FROM ai_prompt_templates
  WHERE name='website_v1' AND notes LIKE 'v3.2 —%'
);


-- ── Activate v3.2, deactivate all prior versions ──────────────────
WITH new_active AS (
  SELECT id FROM ai_prompt_templates
  WHERE name='website_v1' AND notes LIKE 'v3.2 —%'
  ORDER BY version DESC LIMIT 1
)
UPDATE ai_prompt_templates
SET is_active = (id = (SELECT id FROM new_active))
WHERE name = 'website_v1';


NOTIFY pgrst, 'reload schema';
COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- Verify after deploy:
--
--   SELECT name, version, is_active, left(notes, 60) AS notes
--   FROM ai_prompt_templates WHERE name='website_v1' ORDER BY version;
--   -- v3.2 should be the only active row
--
--   SELECT prompt_text LIKE '%NO DUPLICATE OFFERINGS%' AS has_dedup_rule
--   FROM ai_prompt_templates WHERE name='website_v1' AND is_active=true;
--   -- should be true
--
-- Rollback if needed:
--   UPDATE ai_prompt_templates SET is_active = (notes LIKE 'v3.1 —%')
--   WHERE name='website_v1';
-- ════════════════════════════════════════════════════════════════════
