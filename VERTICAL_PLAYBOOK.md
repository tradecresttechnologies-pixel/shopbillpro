# ShopBill Pro — Vertical Playbook v1.1

**Purpose:** Single source of truth for "how does each vertical work in our system."

For each of the 12 macro categories and 85 sub-types: which sidebar items show, which modules apply, which features we've built, which we still owe.

**Date:** 6 May 2026
**Version:** v1.1 — locked decisions from 6 May session baked in (§11 resolved)
**Maintained alongside:** `CURRENT_STATE_AUDIT.md` (build state) + `BUG_FIX_PLAN.md` (next sprint)
**Source of authority:** `db/migrations/003_business_categories.sql` + `db/migrations/012_module_status_updates.sql` + `lib/sidebar-engine.js`

When this document and code disagree → **code wins**, but file an item in §10 (Drift Tracker) so we can reconcile.

**v1.1 changelog (6 May 2026):**
- §11.1 (tea stall website) → RESOLVED: every business gets a website (locked decision 3)
- §11.2 (wholesale website) → RESOLVED: kept active per locked decision 3
- §11.4 (Stylists vs Providers) → RESOLVED: Stylists is a deeper salon-specific feature, not the same as Providers
- §4.18 (`minimal` profile) updated to include website module
- §6.3 vertical-specific module status: Loyalty flipped from `soon` to `active` (Batch 012)

---

## §1. The Architecture in One Page

Every shop has one `shop_type` (e.g., `salon`, `kirana`, `pharmacy`).
Every `shop_type` maps to one `module_profile` (e.g., `salon`, `kirana`, `pharmacy`).
Every `module_profile` has a list of `(module_code, status, badge)` rows in `sbp_module_profiles`.

```
shop signup
  ↓
shop_type chosen (e.g. 'salon' from 9 beauty options)
  ↓
sbp_business_categories.module_profile lookup → 'salon'
  ↓
sbp_module_profiles WHERE profile='salon' → 9 rows
  ↓
get_shop_modules(shop_id) RPC → JSON array
  ↓
lib/sidebar-engine.js render() → renders sidebar with universal core +
                                  these vertical-specific items
```

**Universal core** is hardcoded in JS (`UNIVERSAL_CORE` in sidebar-engine.js) and shown to every shop regardless of vertical:
Home · Bills · New Bill (FAB) · Customers · Stock · Reports · POS Admin · Templates · Settings.

**Vertical-specific** items (Website, Marketing, WhatsApp, Recurring, Cash Register, Suppliers, Team, Subscription, plus the vertical-unique ones) come from the database and respect the shop's `module_profile`.

This means: **the same codebase ships a totally different sidebar to a salon, a kirana, and a clinic.** No code changes needed when adding a new vertical — only DB rows.

---

## §2. The 12 Macro Categories

All 85 sub-types fall under one of these. Macros drive the signup wizard (Step 1), the marketing site landing pages (`/for/<macro>`), and the AI website prompt selection.

| Code | Display | Hindi | Emoji | Sub-types | Lead module profile |
|------|---------|-------|-------|-----------|---------------------|
| `retail` | Retail (Goods) | खुदरा (सामान) | 🛒 | 18 | `kirana` / `pharmacy` / `mobile` / `garments` / `jewellery` / `auto` / `standard` / `minimal` |
| `food` | Food Service | खाद्य सेवा | 🍽️ | 9 | `restaurant` / `food` / `subscription` |
| `beauty` | Beauty & Wellness | सौंदर्य व कल्याण | ✂️ | 9 | `salon` / `subscription` |
| `healthcare` | Healthcare | स्वास्थ्य सेवा | 🏥 | 7 | `healthcare` |
| `education` | Education & Coaching | शिक्षा व कोचिंग | 🎓 | 7 | `education` |
| `services` | Services (skilled labor) | सेवाएं | 🔧 | 11 | `services` |
| `wholesale` | Wholesale / B2B | थोक व्यापार | 📦 | 5 | `wholesale` |
| `online` | Online / D2C | ऑनलाइन / D2C | 🌐 | 4 | `online` |
| `subscription` | Subscription | सब्सक्रिप्शन | 🔁 | 4 | `subscription` |
| `property` | Real Estate / Property | रियल एस्टेट | 🏠 | 3 | `property` |
| `hospitality` | Hospitality | आतिथ्य | 🏨 | 3 | `hospitality` |
| `specialized` | Specialized | विशेष | ⭐ | 5 | `services` / `standard` |

**Total: 85 sub-types across 12 macros, mapped to 19 module profiles.**

---

## §3. The 19 Module Profiles

Each sub-type maps to one of these. The profile name lives in `sbp_business_categories.module_profile`. Module assignments live in `sbp_module_profiles`.

### 3.1 Retail Profiles (8 profiles — the most fragmented macro)

| Profile | Used by | Distinguishing modules |
|---------|---------|-----------------------|
| `kirana` | grocery, dairy, fruit_veg | wa_catalog (soon), home_delivery (soon), loyalty (soon) |
| `pharmacy` | pharmacy/medical store | drug_db (soon), expiry_alerts (soon), prescriptions (soon) |
| `mobile` | mobile/electronics | imei_tracking (soon), warranty (soon), repair_tickets (soon) |
| `garments` | garments, footwear | variants (soon), alterations (soon) |
| `jewellery` | jewellery/bullion | gold_rate (soon), hallmarking (soon) |
| `auto` | cycle/auto parts/garage | vehicle_tracking (soon), service_history (soon) |
| `standard` | furniture, hardware, stationery, gift, pet, plants, general retail | generic — supplier, marketing, etc. only |
| `minimal` | tea stall, pan shop | bare bones: cash_register, wa_center, subscription |

### 3.2 Food Profiles (3 profiles)

| Profile | Used by | Distinguishing modules |
|---------|---------|-----------------------|
| `restaurant` | restaurant, cafe, qsr, cloud_kitchen, bar | qr_menu (soon), tables (soon), online_orders (soon), kitchen (soon) |
| `food` | bakery_retail, ice_cream, catering, food_other | online_orders (soon) — lighter than restaurant |
| `subscription` | tiffin (cross-listed) | members (soon), recurring billing |

### 3.3 Beauty Profiles (2 profiles)

| Profile | Used by | Distinguishing modules |
|---------|---------|-----------------------|
| `salon` | salon, spa, nail_beauty, unisex_salon, wellness, tattoo | **services + appointments (active NEW)**, stylists (soon), customer_history (soon) |
| `subscription` | gym, yoga, sports_club | members (soon), recurring billing |

### 3.4 Healthcare / Education / Services / Wholesale / Online / Subscription / Property / Hospitality (1 profile each)

| Profile | Distinguishing modules |
|---------|-----------------------|
| `healthcare` | **services + appointments (active NEW)**, patients (soon), prescriptions (soon) |
| `education` | **services + appointments (active NEW)**, batches (soon), attendance (soon) |
| `services` | **services + appointments (active NEW)**, service_tickets (soon) |
| `wholesale` | salesman_app (soon), credit_limits (soon) |
| `online` | online_orders (soon), courier (soon) |
| `subscription` | recurring (active), members (soon) |
| `property` | listings (soon), leads (soon) |
| `hospitality` | rooms (soon), bookings (soon), folio (soon) |

**Insight:** Only 4 of 19 profiles get the universal **Service Catalog + Appointments** modules: `salon`, `healthcare`, `education`, `services`. These are the four "service-led" verticals where time-slot booking is core.

The other 15 profiles are "goods-led" or "subscription-led" and don't need appointments.

This is documented in `sbp_module_profiles` and respected by `get_shop_modules` — it just wasn't visible until now.

---

## §4. Per-Vertical Sidebar Maps

Each table below shows EXACTLY what menu items render for that profile in the order they appear, with status. **Universal core items (Home / Bills / New Bill / Customers / Stock / Reports / POS Admin / Templates / Settings) are shown to all profiles and are omitted from these tables for clarity.**

### 4.1 `salon` — Salon · Spa · Beauty Parlour · Wellness · Tattoo

| Order | Module | Status | Badge | Page route |
|-------|--------|--------|-------|------------|
| 10 | Website | active | BIZ | settings.html#website |
| 15 | **Services** | active | NEW | services.html |
| 20 | **Appointments** | active | NEW | appointments.html |
| 30 | Marketing | active | — | marketing.html |
| 40 | WhatsApp | active | — | wa-center.html |
| 50 | Cash Register | active | — | cash-register.html |
| 60 | Team | active | — | team.html |
| 70 | Stylists | soon | SOON | (placeholder) |
| 80 | Customer History | soon | SOON | (placeholder) |
| 90 | Plans | active | — | subscription.html |

**Compliance snippets:** Hours format (10am-9pm, Closed Mondays). No FSSAI/Schedule-H needed.

**AI website prompt:** Brochure-style (Phase 5a). Hero, About, Services list, Stylists section, Gallery, Booking CTA, Contact. Tone: warm, premium, confidence-building.

### 4.2 `healthcare` — Clinic · Dentist · Optician · Vet · Lab · Physio · Counseling

| Order | Module | Status | Badge | Page route |
|-------|--------|--------|-------|------------|
| 10 | Website | active | BIZ | settings.html#website |
| 15 | **Services** | active | NEW | services.html |
| 20 | **Appointments** | active | NEW | appointments.html |
| 30 | Marketing | active | — | marketing.html |
| 40 | WhatsApp | active | — | wa-center.html |
| 50 | Cash Register | active | — | cash-register.html |
| 60 | Team | active | — | team.html |
| 70 | Patients | soon | SOON | (placeholder) |
| 80 | Prescriptions | soon | SOON | (placeholder) |
| 90 | Plans | active | — | subscription.html |

**Compliance snippets:** "Consult a registered medical practitioner. This website is informational only." Schedule H/X applies if pharmacy attached.

**AI website prompt:** Trust-led brochure. Doctor credentials, services with conditions treated, patient testimonials, hours, emergency contact, location map.

### 4.3 `education` — Tuition · Music · Online Courses · Library · Driving · Coaching

| Order | Module | Status | Badge | Page route |
|-------|--------|--------|-------|------------|
| 10 | Website | active | BIZ | settings.html#website |
| 15 | **Services** | active | NEW | services.html |
| 20 | **Appointments** | active | NEW | appointments.html |
| 30 | Marketing | active | — | marketing.html |
| 40 | WhatsApp | active | — | wa-center.html |
| 50 | Cash Register | active | — | cash-register.html |
| 60 | Team | active | — | team.html |
| 70 | Batches | soon | SOON | (placeholder) |
| 80 | Attendance | soon | SOON | (placeholder) |
| 90 | Plans | active | — | subscription.html |

**Compliance snippets:** No specific compliance unless education registration relevant.

**AI website prompt:** Outcome-led brochure. Faculty, courses with batch timings, results/placements, fees, free demo CTA, location.

### 4.4 `services` — Plumber · Photographer · Mover · Tailor · Pet Groomer · Print Shop · CA · Lawyer

| Order | Module | Status | Badge | Page route |
|-------|--------|--------|-------|------------|
| 10 | Website | active | BIZ | settings.html#website |
| 15 | **Services** | active | NEW | services.html |
| 20 | **Appointments** | active | NEW | appointments.html |
| 30 | Marketing | active | — | marketing.html |
| 40 | WhatsApp | active | — | wa-center.html |
| 50 | Cash Register | active | — | cash-register.html |
| 60 | Team | active | — | team.html |
| 70 | Service Tickets | soon | SOON | (placeholder) |
| 80 | Plans | active | — | subscription.html |

**Compliance snippets:** Professional qualifications/license number (CA, lawyer). Service area disclosure (movers, plumbers).

**AI website prompt:** Action-led brochure. What we do, service areas, sample work / portfolio, transparent pricing, urgent contact button.

### 4.5 `kirana` — Grocery · Provision · Dairy · Fruit & Veg

| Order | Module | Status | Badge | Page route |
|-------|--------|--------|-------|------------|
| 10 | Website | active | BIZ | settings.html#website |
| 20 | Marketing | active | — | marketing.html |
| 30 | WhatsApp | active | — | wa-center.html |
| 40 | Recurring | active | — | recurring.html |
| 50 | Cash Register | active | — | cash-register.html |
| 60 | Suppliers | active | — | supplier.html |
| 70 | Team | active | — | team.html |
| 80 | WA Catalog | soon | SOON | (placeholder) |
| 90 | Home Delivery | soon | SOON | (placeholder) |
| 100 | Loyalty | soon | SOON | (placeholder, **already built — needs status flip**) |
| 110 | Plans | active | — | subscription.html |

**Note:** Loyalty module IS built (Batch shipped 5 May 2026) but `sbp_module_profiles` still has it as `soon`. Needs status flip in 003_business_categories.sql for `kirana` profile (and other retail profiles where applicable).

**Compliance snippets:** GST registration display, weights & measures certification reference.

**AI website prompt:** Catalog-style (Phase 5b). Product categories, contact for orders, delivery zones, hours.

### 4.6 `restaurant` — Restaurant · Cafe · QSR · Cloud Kitchen · Bar

| Order | Module | Status | Badge | Page route |
|-------|--------|--------|-------|------------|
| 10 | Website | active | BIZ | settings.html#website |
| 20 | Marketing | active | — | marketing.html |
| 30 | WhatsApp | active | — | wa-center.html |
| 40 | Cash Register | active | — | cash-register.html |
| 50 | Suppliers | active | — | supplier.html |
| 60 | Team | active | — | team.html |
| 70 | QR Menu | soon | SOON | (placeholder) |
| 80 | Tables | soon | SOON | (placeholder) |
| 90 | Online Orders | soon | SOON | (placeholder) |
| 100 | Kitchen | soon | SOON | (placeholder) |
| 110 | Plans | active | — | subscription.html |

**Compliance snippets:** FSSAI license number must show. Veg/non-veg indicator on menu items. Bar requires liquor license display.

**AI website prompt:** Brochure or catalog (depends on online orders). Hero food photo, menu (dishes with prices), hours, location, reservation/order CTA.

### 4.7 `pharmacy` — Pharmacy / Medical Store

| Order | Module | Status | Badge | Page route |
|-------|--------|--------|-------|------------|
| 10 | Website | active | BIZ | settings.html#website |
| 20 | Marketing | active | — | marketing.html |
| 30 | WhatsApp | active | — | wa-center.html |
| 40 | Cash Register | active | — | cash-register.html |
| 50 | Suppliers | active | — | supplier.html |
| 60 | Team | active | — | team.html |
| 70 | Drug Database | soon | SOON | (placeholder) |
| 80 | Expiry Alerts | soon | SOON | (placeholder) |
| 90 | Prescriptions | soon | SOON | (placeholder) |
| 100 | Plans | active | — | subscription.html |

**Compliance snippets:** Drug license number display. "Schedule H/X drugs sold against valid prescription only." No online sale of restricted drugs.

**AI website prompt:** Brochure-style. Pharmacy hours (often 24/7), contact, prescription upload via WhatsApp, list of services (home delivery, oxygen/medical equipment).

### 4.8 `mobile` — Mobile / Electronics

(Identical structure to pharmacy with modules: imei_tracking, warranty, repair_tickets all soon.)

### 4.9 `garments` — Garments / Textile / Boutique / Footwear

(Identical structure with modules: variants, alterations soon.)

### 4.10 `jewellery` — Jewellery / Bullion

(Identical structure with modules: gold_rate, hallmarking soon.)

### 4.11 `auto` — Cycle / Auto Parts / Garage

(Identical structure with modules: vehicle_tracking, service_history soon.)

### 4.12 `wholesale` — Distributor · Mandi · Manufacturer · Stockist · Importer

(Identical structure with modules: salesman_app, credit_limits soon. **No website** — wholesale shops typically do not need public-facing pages.)

**Note:** Currently `website` is set active for wholesale. Should consider whether this is appropriate or if it should be `soon` / hidden by default.

### 4.13 `online` — D2C Brand · Reseller · Handmade · Digital · Marketplace

(Identical structure with modules: online_orders, courier soon. This profile is the target for Phase 5c transactional websites.)

### 4.14 `subscription` — Co-working · Tuition Fees · Content · Laundry · Gym · Yoga · Sports · Tiffin

| Order | Module | Status | Badge |
|-------|--------|--------|-------|
| 10 | Website | active | BIZ |
| 20 | Recurring | active | — |
| 30 | Marketing | active | — |
| 40 | WhatsApp | active | — |
| 50 | Cash Register | active | — |
| 60 | Team | active | — |
| 70 | Members | soon | SOON |
| 80 | Plans | active | — |

### 4.15 `property` — Real Estate Agent · PG/Hostel · Builder

(Identical structure with modules: listings, leads soon. **No supplier/cash_register relevance.**)

### 4.16 `hospitality` — Hotel · Homestay · Banquet

| Order | Module | Status | Badge |
|-------|--------|--------|-------|
| 10 | Website | active | BIZ |
| 20 | Marketing | active | — |
| 30 | WhatsApp | active | — |
| 40 | Cash Register | active | — |
| 60 | Team | active | — |
| 70 | Rooms | soon | SOON |
| 80 | Bookings | soon | SOON |
| 90 | Folio | soon | SOON |
| 100 | Plans | active | — |

**Compliance snippets:** Hotel license number. GST + luxury tax display. Tariff card (govt-mandated).

### 4.17 `food` — Bakery · Ice Cream · Catering · Food (other)

(Identical structure to restaurant but lighter — no QR menu, tables, kitchen modules.)

### 4.18 `minimal` — Tea Stall · Pan Shop

| Order | Module | Status | Badge |
|-------|--------|--------|-------|
| 5 | Website | active | BIZ |
| 10 | Cash Register | active | — |
| 20 | WhatsApp | active | — |
| 30 | Plans | active | — |

**Even tea stalls and pan shops get a website.** Per locked decision 3 (6 May 2026): every business deserves a digital presence. The shop page on `/s/<slug>` is a genuine differentiator for street-vendor / micro-MSME shops trying to build any online presence at all.

Otherwise the bare-bones profile remains: cash, WhatsApp, plans. The shopkeeper doesn't need stock or suppliers — they just need to make bills, track cash, and now have a tappable shop link.

### 4.19 `standard` — Default (for any retail without a specific profile)

| Order | Module | Status | Badge |
|-------|--------|--------|-------|
| 10 | Website | active | BIZ |
| 20 | Marketing | active | — |
| 30 | WhatsApp | active | — |
| 40 | Recurring | active | — |
| 50 | Cash Register | active | — |
| 60 | Suppliers | active | — |
| 70 | Team | active | — |
| 80 | Plans | active | — |

---

## §5. Sub-Type → Profile Map (All 85)

This is the source of truth. Lookup by sub-type code, get the profile.

### Retail (18)

| Sub-type | Display | Profile |
|----------|---------|---------|
| kirana | Kirana / Grocery / Provision | kirana |
| dairy | Dairy / Milk Booth | kirana |
| fruit_veg | Fruits & Vegetables | kirana |
| bakery_retail | Bakery / Sweets | food |
| pharmacy | Pharmacy / Medical Store | pharmacy |
| mobile_elec | Mobile / Electronics | mobile |
| garments | Garments / Textile / Boutique | garments |
| jewellery | Jewellery / Bullion | jewellery |
| furniture | Furniture / Home Decor | standard |
| hardware | Hardware / Building Material | standard |
| stationery | Stationery / Books | standard |
| footwear | Footwear / Shoes | garments |
| gift_shop | Gift / Card Shop | standard |
| pet_shop | Pet Shop / Pet Food | standard |
| plant_nursery | Plant Nursery / Garden | standard |
| auto_parts | Cycle / Auto Parts / Garage | auto |
| tea_pan | Tea Stall / Pan Shop | minimal |
| general_retail | General Retail (other) | standard |

### Food Service (9)

| Sub-type | Profile |
|----------|---------|
| restaurant | restaurant |
| cafe | restaurant |
| qsr | restaurant |
| ice_cream | food |
| cloud_kitchen | restaurant |
| tiffin | subscription |
| catering | food |
| bar_lounge | restaurant |
| food_other | food |

### Beauty & Wellness (9)

| Sub-type | Profile |
|----------|---------|
| salon | salon |
| spa | salon |
| nail_beauty | salon |
| unisex_salon | salon |
| wellness | salon |
| gym | subscription |
| yoga | subscription |
| sports_club | subscription |
| tattoo | salon |

### Healthcare (7)

All 7 sub-types (clinic, dentist, optician, vet, lab, physio, counselling) → `healthcare` profile.

### Education & Coaching (7)

All 7 sub-types (tuition, music, online_courses, library, driving_school, coaching, education_other) → `education` profile.

### Services (11)

All 11 sub-types (plumber, photographer, mover, tailor, pet_groomer, dj, print_shop, ca_lawyer, etc.) → `services` profile.

### Wholesale / B2B (5)

All 5 sub-types (distributor, mandi, manufacturer, stockist, importer) → `wholesale` profile.

### Online / D2C (4)

All 4 sub-types (d2c_brand, reseller, handmade, digital_seller) → `online` profile.

### Subscription (4)

All 4 sub-types (coworking, content_subscription, tuition_fees, laundry) → `subscription` profile.

### Property (3)

All 3 sub-types (real_estate_agent, pg_hostel, builder) → `property` profile.

### Hospitality (3)

All 3 sub-types (hotel, homestay, banquet) → `hospitality` profile.

### Specialized (5)

All 5 sub-types (wedding_planner, dj_event, print_shop, travel_agent, transport) → mostly `services` with some `standard`.

---

## §6. Module Catalog (Complete)

Every module that can appear in any sidebar, with current build status.

### 6.1 Universal Core (always shown — hardcoded in sidebar-engine.js)

| Module | Page | Build status |
|--------|------|--------------|
| dashboard | dashboard.html | ✅ Built |
| bills | bills.html | ✅ Built |
| billing (FAB) | billing.html | ✅ Built (POS + Manual modes) |
| customers | customers.html | ✅ Built |
| stock | stock.html | ✅ Built |
| reports | reports.html | ✅ Built (Reports Pro: GSTR-1/3B, P&L, Payments, Forecast) |
| pos-admin | pos-admin.html | ✅ Built |
| bill-templates | bill-templates.html | ✅ Built |
| settings | settings.html | ⚠️ Built, has structural bug (orphan modal at top, see audit) |

### 6.2 Universal Add-ons (toggle by profile)

| Module | Page | Build status | Notes |
|--------|------|--------------|-------|
| website | settings.html#website | ✅ Built (Pro+: about + gallery; Business: full website coming Phase 5a) |
| marketing | marketing.html | ✅ Built |
| wa_center | wa-center.html | ✅ Built (bulk send + 30/day cap) |
| recurring | recurring.html | ✅ Built |
| cash_register | cash-register.html | ✅ Built |
| supplier | supplier.html | ✅ Built |
| team | team.html | ✅ Built |
| subscription | subscription.html | ✅ Built |
| **services** | services.html | ⚠️ Built but BROKEN (row_to_jsonb + sidebar missing) |
| **appointments** | appointments.html | ⚠️ Built but BROKEN (row_to_jsonb + sidebar missing) |

### 6.3 Vertical-Specific (most still placeholders)

| Module | Used by profiles | Build status |
|--------|------------------|--------------|
| qr_menu | restaurant | ❌ Placeholder |
| tables | restaurant | ❌ Placeholder |
| online_orders | restaurant, food, online | ❌ Placeholder |
| kitchen | restaurant | ❌ Placeholder |
| stylists | salon | ❌ Placeholder |
| customer_history | salon | ❌ Placeholder |
| drug_db | pharmacy | ❌ Placeholder |
| expiry_alerts | pharmacy | ❌ Placeholder |
| prescriptions | pharmacy, healthcare | ❌ Placeholder |
| imei_tracking | mobile | ❌ Placeholder |
| warranty | mobile | ❌ Placeholder |
| repair_tickets | mobile | ❌ Placeholder |
| variants | garments | ❌ Placeholder |
| alterations | garments | ❌ Placeholder |
| gold_rate | jewellery | ❌ Placeholder |
| hallmarking | jewellery | ❌ Placeholder |
| vehicle_tracking | auto | ❌ Placeholder |
| service_history | auto | ❌ Placeholder |
| patients | healthcare | ❌ Placeholder |
| batches | education | ❌ Placeholder |
| attendance | education | ❌ Placeholder |
| service_tickets | services | ❌ Placeholder |
| salesman_app | wholesale | ❌ Placeholder |
| credit_limits | wholesale | ❌ Placeholder |
| wa_catalog | kirana | ❌ Placeholder |
| home_delivery | kirana | ❌ Placeholder |
| **loyalty** | kirana | ✅ **Built (5 May)** but DB still says SOON — needs status flip |
| courier | online | ❌ Placeholder |
| members | subscription | ❌ Placeholder |
| listings | property | ❌ Placeholder |
| leads | property | ❌ Placeholder |
| rooms | hospitality | ❌ Placeholder |
| bookings | hospitality | ❌ Placeholder |
| folio | hospitality | ❌ Placeholder |

**Counts:** 9 universal core modules built, 8 universal add-ons built (2 broken), 1 vertical-specific built (loyalty, status drift), 33 vertical-specific placeholders.

---

## §7. Vertical Coverage Scoring

How "complete" each vertical feels to a shop owner today, based on what's built vs what their profile expects.

| Profile | Coverage today | Blockers | Closes to 100% when… |
|---------|----------------|----------|----------------------|
| `salon` | ~55% (will jump to **95%**) | services + appointments broken | row_to_jsonb fix lands |
| `healthcare` | ~55% (will jump to **95%**) | same as salon + patients/prescriptions are nice-to-haves | row_to_jsonb fix lands |
| `education` | ~55% (will jump to **95%**) | same | row_to_jsonb fix lands |
| `services` | ~55% (will jump to **95%**) | same | row_to_jsonb fix lands |
| `kirana` | ~95% | loyalty status drift | DB profile flip + module added |
| `restaurant` | ~70% | QR menu, tables, online orders missing | Restaurant module batch (8-12 hr session, post-CIN) |
| `pharmacy` | ~70% | drug DB, expiry alerts not yet | Pharmacy module batch (Month 3 per Master Plan) |
| `mobile` | ~70% | IMEI/warranty placeholders | Vehicle/IMEI batch (Month 4) |
| `garments` | ~80% | variants matrix is the big one | Variants batch (Month 4) |
| `jewellery` | ~80% | gold rate sync is differentiator | Future batch |
| `auto` | ~80% | vehicle tracking soon | Future batch |
| `online` | ~70% | online orders + courier needed | Phase 5c (Month 10) |
| `wholesale` | ~85% | salesman app for B2B | Future batch |
| `subscription` | ~85% | members module | Future batch |
| `property` | ~75% | listings + leads | Future batch |
| `hospitality` | ~70% | rooms + bookings + folio | Phase 4 priority (per Master Plan, Hotel parked) |
| `food` | ~85% | online orders the main gap | Future batch |
| `standard` | 100% | everything generic retail needs is shipped | — |
| `minimal` | 100% | everything tea stall needs is shipped | — |

**Read this:** The four service-led profiles (salon, healthcare, education, services) ALL share the same blocker — the row_to_jsonb bug. **One SQL fix unblocks four verticals to 95% coverage.** That's the highest-leverage repair available right now.

---

## §8. Sample Data Per Vertical (signup seed)

When a new shop signs up with a given `shop_type`, what sample data do we pre-load to make the app feel populated and useful?

This is **NOT YET IMPLEMENTED** — currently every signup gets the same empty-state. Vertical-aware seed is a Phase 1.5 / Phase 2 enhancement. Documented here as intent.

| Profile | Sample products / services | Sample customers | Sample bills |
|---------|----------------------------|------------------|--------------|
| salon | Haircut Men ₹150, Haircut Women ₹300, Hair Color ₹2000, Manicure ₹400, Spa ₹1500 | Riya (regular), Suresh (walk-in) | 1 sample bill |
| healthcare | Consultation ₹500, Follow-up ₹300, Dental Cleaning ₹1500, Eye Test ₹200 | Mr. Patel, Mrs. Sharma | 1 sample bill |
| education | Math Tuition ₹2000/mo, Music Class ₹1500/mo, Free Demo ₹0 | Aarav (Class 10), Pooja (Class 8) | 1 sample bill (recurring) |
| services | Plumbing visit ₹500, Pet grooming ₹800, Photo session ₹3000 | Local customers list | 1 sample bill |
| kirana | Atta 5kg ₹300, Sugar 1kg ₹50, Tea 250g ₹150, Oil 1L ₹200 | Daily customers, monthly khata | 5 sample bills |
| restaurant | Veg Thali ₹150, Paneer Butter Masala ₹220, Coke ₹40 | Walk-in, regulars | 3 sample bills |
| pharmacy | Crocin ₹30, Combiflam ₹45, Glucose 25g ₹15 | Regular customers | 3 sample bills |
| mobile | Phone case ₹200, Charger ₹300, Tempered glass ₹150 | Walk-in, repair customers | 2 sample bills |

**Implementation note:** Add a `seed_data jsonb` column to `sbp_business_categories` and run a server-side seed function on signup completion. Defer until post-CIN (low-priority polish).

---

## §9. AI Website Prompt Skeleton Per Vertical

For Phase 5a (brochure websites for service verticals — Month 5 of Master Plan).

The prompt template lives in `sbp_ai_prompts` table (Master Plan §6.5 schema). Each vertical gets a versioned prompt. The intent below is for the FIRST version.

### 9.1 Brochure Verticals (Phase 5a, Month 5)

For: `salon`, `healthcare`, `education`, `services`, hospitality (no booking initially).

**Prompt skeleton:**
```
You are writing a {vertical_name} brochure website for {shop_name}, located
in {city}. The owner described their business as: "{owner_description}".

Generate the following 5 sections in {language}:

1. Hero tagline (10-15 words, action-oriented)
2. About paragraph (50-80 words, warm, trust-building, mention years_in_business={years})
3. Services list (use exactly the {n} services provided: {services_array})
4. Why choose us (3 bullet points, 8-15 words each)
5. Closing CTA (15-20 words, ending with WhatsApp action)

Constraints:
- Hindi must read naturally — no romanized "kya hai" mixed with Devanagari
- No claims of medical efficacy ({vertical=healthcare} only)
- No price commitments unless specifically given
- No reference to features the shop doesn't have
```

**Tone variations per vertical:**
- `salon` — warm, glamorous, confidence-building
- `healthcare` — calm, professional, trust-led
- `education` — outcome-focused, parent-reassuring
- `services` — capable, dependable, urgency-friendly

### 9.2 Catalog Verticals (Phase 5b, Month 7)

For: `kirana`, `pharmacy`, `garments`, `jewellery`, `mobile`, `auto`, retail in general.

Prompt is mostly the same skeleton + extra section for product categories pulled from inventory.

### 9.3 Transactional Verticals (Phase 5c, Month 10)

For: `online` (D2C). Hand-designed templates with AI content assist — not full prompt-based generation.

---

## §10. Drift Tracker

When the doc and the code disagree, list the discrepancy here for reconciliation.

**Closed (Batch 012, 6 May 2026):**

| # | Item | Resolution |
|---|------|------------|
| 1 | Loyalty status for retail profiles | ✅ DB updated via `012_module_status_updates.sql` — flipped to `active` across 13 profiles |
| 2 | services + appointments forced to `soon` | ✅ Removed from `PENDING_PAGES` in `lib/sidebar-engine.js` |
| 3 | Website module for `wholesale` | ✅ Resolved per locked decision 3 (kept active for all profiles) |
| 4 | Website missing on `minimal` profile | ✅ Added via 012 migration (locked decision 3) |

**Currently open:** None. Doc and code are in sync as of 6 May 2026 v1.1.

---

## §11. Decisions Resolved (6 May 2026 founder session)

These were open in v1.0 — locked answers below.

### 11.1 — Tea Stall / Pan Shop website
**Status:** ✅ RESOLVED — Yes, websites for everyone
**Decision (Vinay, 6 May 2026):** "all business will have website"
**Reasoning:** Strategic positioning — ShopBill Pro = "every Indian shop deserves a digital presence." Even a tea stall or pan shop benefits from a tappable shop link they can share via WhatsApp.
**Implementation:** `db/migrations/012_module_status_updates.sql` adds website (active, BIZ) to `minimal` profile. See §4.18.

### 11.2 — Wholesale website
**Status:** ✅ RESOLVED — Yes, kept active
**Decision (Vinay, 6 May 2026):** "all business will have website" — no exceptions
**Reasoning:** B2B shops still benefit from a public page (catalog reference, contact info, professional credibility for buyers researching vendors).
**Implementation:** No code change needed (already active in v1.0).

### 11.3 — Subscription profile cross-listing
**Status:** ⏳ DEFERRED — Will revisit when first subscription-vertical complaint arrives
**Current state:** Tiffin + Gym + Coworking + Yoga all share one `subscription` profile. Different businesses but similar billing patterns (recurring fees, member rolls).
**Trigger to revisit:** A founder of one of these verticals reports the modules feel "off" — that's the signal to split.

### 11.4 — Stylists vs Providers
**Status:** ✅ RESOLVED — Stylists is a deeper feature, distinct from Providers
**Decision (Vinay, 6 May 2026):** "deeper feature"
**Difference clarified:**
- **Providers** (in Appointments/011): generic time-slot booking. Any vertical that takes appointments — salon, clinic, coaching, services — uses Providers. Spec: name, role, working days/hours, slot interval, buffer time.
- **Stylists** (future, ~6-8 hr session): salon-specific deeper roster. Spec includes — skills/expertise (haircut, coloring, makeup, bridal), commission percentage per service, performance metrics (revenue per stylist, customer retention), per-stylist package management (e.g., Stylist X exclusive packages), photo portfolio.
**Implication:** Salon shops eventually get BOTH modules — Providers (basic appointments, available now) + Stylists (deeper salon ops, future batch).
**Implementation:** No change to current Appointments. Stylists stays as `soon` in salon profile until separate dedicated batch builds it.

### 11.5 — Specialized macro is a catch-all
**Status:** ⏳ DEFERRED — Acceptable as-is for now
**Current state:** Wedding planner, DJ, print shop, travel agent, transport — all under `specialized` macro, mostly mapped to `services` profile.
**Trigger to revisit:** When we have ≥10 paying customers in any one of these sub-types and they need vertical-specific features.

---

## §12. Versioning & Maintenance

This document is `v1.1` (6 May 2026). Every time the following change, bump the version and update relevant section:

- New macro category added → §2 + §5
- New sub-type added → §5 + §6 (if introduces a new module)
- New module profile added → §3 + §4
- New module added or status changes → §6
- Module promoted from soon to active → §6 + remove from `PENDING_PAGES` in sidebar-engine.js

**Version history:**
- `v1.0` (6 May 2026 morning): Initial playbook based on first audit of shopbillpro.zip
- `v1.1` (6 May 2026 evening): Locked decisions baked in; drift items resolved via Batch 012 deploy

**File this document:** Keep at root of repo as `docs/VERTICAL_PLAYBOOK.md`. Commit on every change. Reference from session summaries for future Claude sessions.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Confidential — Internal Reference Document*
