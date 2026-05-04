-- ════════════════════════════════════════════════════════════════
-- ShopBill Pro — Migration 003: Business Categories & Module Profiles
-- ════════════════════════════════════════════════════════════════
-- Run AFTER admin_panel_full.sql.
-- Idempotent — safe to re-run.
--
-- v1.1 (May 2026) FIX: corrected `sbp_shop` references to `shops`
--   to match the actual production schema. No other behavior changes.
--
-- This migration introduces the shop_type system that powers:
--   - Smart sidebar (vertical-aware module visibility)
--   - Vertical-aware sample data on signup
--   - Vertical-tailored website templates (Batch 1B)
--   - 12 vertical landing pages on marketing site
--
-- Architecture:
--   sbp_macro_categories  — 12 high-level business groupings
--   sbp_business_categories — 80+ specific business sub-types
--   sbp_module_profiles   — maps macro category → enabled modules
--   shops.shop_type    — FK to a business category (added below)
-- ════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════
-- 1. Macro Categories (12 high-level buckets)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS sbp_macro_categories (
  code         text PRIMARY KEY,                 -- 'retail', 'food', 'beauty', etc.
  name_en      text NOT NULL,
  name_hi      text,
  emoji        text,
  description  text,
  display_order integer DEFAULT 100,
  is_active    boolean DEFAULT true,
  created_at   timestamptz DEFAULT now()
);

INSERT INTO sbp_macro_categories (code, name_en, name_hi, emoji, description, display_order) VALUES
  ('retail',        'Retail (Goods)',      'खुदरा (सामान)',     '🛒', 'Sells physical goods over the counter',                10),
  ('food',          'Food Service',        'खाद्य सेवा',         '🍽️', 'Restaurants, cafes, bakeries, catering, tiffin',       20),
  ('beauty',        'Beauty & Wellness',   'सौंदर्य व कल्याण',    '✂️', 'Salons, spas, gyms, yoga studios, fitness',            30),
  ('healthcare',    'Healthcare',          'स्वास्थ्य सेवा',      '🏥', 'Clinics, dentists, opticians, vets, labs',             40),
  ('education',     'Education & Coaching','शिक्षा व कोचिंग',    '🎓', 'Tuition, music, online courses, libraries',            50),
  ('services',      'Services',            'सेवाएं',             '🔧', 'Plumber, photographer, mover, tailor, repair',         60),
  ('wholesale',     'Wholesale / B2B',     'थोक व्यापार',        '📦', 'Distributors, mandi, manufacturers, stockists',         70),
  ('online',        'Online / D2C',        'ऑनलाइन / D2C',      '🌐', 'D2C brands, resellers, handmade, digital sellers',     80),
  ('subscription',  'Subscription',        'सब्सक्रिप्शन',       '🔁', 'Co-working, recurring fees, content subscriptions',    90),
  ('property',      'Real Estate / Property','रियल एस्टेट',      '🏠', 'Real estate agents, PG/hostels, builders',            100),
  ('hospitality',   'Hospitality',         'आतिथ्य',             '🏨', 'Hotels, homestays, banquet halls',                    110),
  ('specialized',   'Specialized',         'विशेष',              '⭐', 'Wedding, DJ, print, travel, transport',               120)
ON CONFLICT (code) DO UPDATE SET
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  description = EXCLUDED.description,
  display_order = EXCLUDED.display_order;


-- ══════════════════════════════════════════════════════════════
-- 2. Business Categories (80+ specific business types)
-- ══════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS sbp_business_categories (
  code         text PRIMARY KEY,                 -- 'kirana', 'salon', 'pharmacy', etc.
  macro_code   text NOT NULL REFERENCES sbp_macro_categories(code) ON DELETE RESTRICT,
  name_en      text NOT NULL,
  name_hi      text,
  emoji        text,
  description  text,
  module_profile text DEFAULT 'standard',       -- which module profile to apply
  display_order integer DEFAULT 100,
  is_active    boolean DEFAULT true,
  created_at   timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bc_macro ON sbp_business_categories(macro_code);
CREATE INDEX IF NOT EXISTS idx_bc_active ON sbp_business_categories(is_active) WHERE is_active = true;


-- Seed 80+ business types (idempotent via UPSERT)
-- ──────────────── RETAIL (18 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('kirana',         'retail', 'Kirana / Grocery / Provision', 'किराना / जनरल स्टोर',  '🛒', 'kirana',     10),
  ('dairy',          'retail', 'Dairy / Milk Booth',           'डेयरी / दूध',         '🥛', 'kirana',     11),
  ('fruit_veg',      'retail', 'Fruits & Vegetables',          'फल-सब्जी',           '🥬', 'kirana',     12),
  ('bakery_retail',  'retail', 'Bakery / Sweets (retail)',     'बेकरी / मिठाई',      '🍞', 'food',       13),
  ('pharmacy',       'retail', 'Pharmacy / Medical Store',     'फार्मेसी / दवा',     '💊', 'pharmacy',   14),
  ('mobile_elec',    'retail', 'Mobile / Electronics',         'मोबाइल / इलेक्ट्रॉनिक्स','📱', 'mobile',     15),
  ('garments',       'retail', 'Garments / Textile / Boutique','कपड़े / बुटीक',      '👕', 'garments',   16),
  ('jewellery',      'retail', 'Jewellery / Bullion',          'ज्वेलरी / सोना',     '💎', 'jewellery',  17),
  ('furniture',      'retail', 'Furniture / Home Decor',       'फर्नीचर / घर सजावट', '🛏️', 'standard',   18),
  ('hardware',       'retail', 'Hardware / Building Material', 'हार्डवेयर / निर्माण', '🛠️', 'standard',   19),
  ('stationery',     'retail', 'Stationery / Books',           'स्टेशनरी / किताबें',  '📚', 'standard',   20),
  ('footwear',       'retail', 'Footwear / Shoes',             'जूते / चप्पल',       '👞', 'garments',   21),
  ('gift_shop',      'retail', 'Gift / Card Shop',             'गिफ्ट शॉप',          '🎁', 'standard',   22),
  ('pet_shop',       'retail', 'Pet Shop / Pet Food',          'पेट शॉप',            '🐾', 'standard',   23),
  ('plant_nursery',  'retail', 'Plant Nursery / Garden',       'पौधे की दुकान',      '🌱', 'standard',   24),
  ('auto_parts',     'retail', 'Cycle / Auto Parts / Garage',  'ऑटो पार्ट्स',        '🚲', 'auto',       25),
  ('tea_pan',        'retail', 'Tea Stall / Pan Shop',         'चाय / पान',          '🍵', 'minimal',    26),
  ('general_retail', 'retail', 'General Retail (other)',       'सामान्य दुकान',      '⚡', 'standard',   99)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── FOOD SERVICE (9 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('restaurant',     'food', 'Restaurant / Family Dining',     'रेस्तरां',            '🍽️', 'restaurant', 10),
  ('cafe',           'food', 'Café / Coffee Shop',             'कैफे',                '☕', 'restaurant', 11),
  ('qsr',            'food', 'Pizza / Fast Food / QSR',        'फास्ट फूड',           '🍕', 'restaurant', 12),
  ('ice_cream',      'food', 'Ice Cream / Juice / Shake',      'आइसक्रीम / जूस',      '🍦', 'food',       13),
  ('cloud_kitchen',  'food', 'Food Truck / Cloud Kitchen',     'क्लाउड किचन',         '🥪', 'restaurant', 14),
  ('tiffin',         'food', 'Tiffin Service / Mess',          'टिफिन सेवा',          '🍱', 'subscription',15),
  ('catering',       'food', 'Catering Service',               'कैटरिंग',             '🥘', 'food',       16),
  ('bar_lounge',     'food', 'Bar / Lounge / Pub',             'बार',                 '🍷', 'restaurant', 17),
  ('food_other',     'food', 'Other Food Business',            'अन्य खाद्य',          '🍽️', 'food',       99)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── BEAUTY & WELLNESS (9 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('salon',          'beauty', 'Salon / Hair / Barber',        'सैलून / नाई',         '✂️', 'salon',      10),
  ('spa',            'beauty', 'Spa / Massage',                'स्पा / मसाज',         '💆', 'salon',      11),
  ('nail_beauty',    'beauty', 'Nail / Beauty Parlour',        'ब्यूटी पार्लर',       '💅', 'salon',      12),
  ('unisex_salon',   'beauty', 'Unisex Salon',                 'यूनिसेक्स सैलून',     '💇', 'salon',      13),
  ('wellness',       'beauty', 'Wellness Center / Ayurveda',   'वेलनेस / आयुर्वेद',   '🧖', 'salon',      14),
  ('gym',            'beauty', 'Gym / Fitness Center',         'जिम / फिटनेस',        '💪', 'subscription',15),
  ('yoga',           'beauty', 'Yoga / Pilates Studio',        'योग स्टूडियो',         '🧘', 'subscription',16),
  ('sports_club',    'beauty', 'Swimming / Sports Club',       'स्पोर्ट्स क्लब',      '🏊', 'subscription',17),
  ('tattoo',         'beauty', 'Tattoo / Piercing',            'टैटू',                '💉', 'salon',      18)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── HEALTHCARE (7 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('clinic',         'healthcare', 'Clinic / Doctor',          'क्लिनिक / डॉक्टर',    '🏥', 'healthcare', 10),
  ('dentist',        'healthcare', 'Dentist',                  'दंत चिकित्सक',        '🦷', 'healthcare', 11),
  ('optician',       'healthcare', 'Optician / Eyewear',       'चश्मा / ऑप्टिशियन',   '👁️', 'healthcare', 12),
  ('vet',            'healthcare', 'Veterinary Clinic',        'पशु चिकित्सक',        '🐕', 'healthcare', 13),
  ('lab',            'healthcare', 'Diagnostic Lab / Pathology','डायग्नोस्टिक लैब',   '🧪', 'healthcare', 14),
  ('physio',         'healthcare', 'Physiotherapy',            'फिजियोथेरेपी',         '🩺', 'healthcare', 15),
  ('counselling',    'healthcare', 'Counselling / Therapy',    'काउंसलिंग',           '💆', 'healthcare', 16)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── EDUCATION & COACHING (7 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('coaching',       'education', 'Coaching Class / Tuition',  'कोचिंग क्लास',        '🏫', 'education',  10),
  ('art_class',      'education', 'Art / Music / Dance Class', 'कला / संगीत क्लास',  '🎨', 'education',  11),
  ('online_course',  'education', 'Online Course Creator',     'ऑनलाइन कोर्स',         '🌐', 'subscription',12),
  ('library',        'education', 'Library / Book Rental',     'लाइब्रेरी',            '📖', 'subscription',13),
  ('driving_school', 'education', 'Driving School',            'ड्राइविंग स्कूल',     '🚗', 'education',  14),
  ('skill_training', 'education', 'Computer / Skill Training', 'कंप्यूटर ट्रेनिंग',   '💻', 'education',  15),
  ('personal_coach', 'education', 'Personal Trainer / Coach',  'पर्सनल ट्रेनर',       '🏋️', 'salon',      16)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── SERVICES (11 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('handyman',       'services', 'Plumber / Electrician / AC','प्लंबर / इलेक्ट्रीशियन','🔧', 'services',  10),
  ('home_services',  'services', 'Home Services',              'होम सर्विसेज',        '🏠', 'services',  11),
  ('device_repair',  'services', 'Computer / Phone Repair',    'रिपेयर शॉप',          '💻', 'services',  12),
  ('photographer',   'services', 'Photographer / Videographer','फोटोग्राफर',          '📷', 'services',  13),
  ('event_mgr',      'services', 'Event Manager / Decorator',  'इवेंट मैनेजर',         '🎉', 'services',  14),
  ('car_wash',       'services', 'Car Wash / Detailing',       'कार वॉश',             '🚗', 'services',  15),
  ('interior',       'services', 'Interior Designer / Architect','इंटीरियर डिजाइनर', '🪞', 'services',  16),
  ('agency_help',    'services', 'Maid / Cook Agency',         'मेड एजेंसी',          '🧹', 'services',  17),
  ('movers',         'services', 'Local Movers / Packers',     'पैकर्स मूवर्स',       '🚚', 'services',  18),
  ('tailor',         'services', 'Tailor / Boutique services', 'दर्जी',               '📐', 'services',  19),
  ('pet_groomer',    'services', 'Pet Groomer / Walker',       'पेट ग्रूमर',          '🐕', 'services',  20)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── WHOLESALE / B2B (5 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('distributor',    'wholesale', 'Wholesale Distributor',     'थोक डिस्ट्रीब्यूटर', '📦', 'wholesale',  10),
  ('mandi',          'wholesale', 'Agri / Mandi / Commodity',  'मंडी',                '🌾', 'wholesale',  11),
  ('manufacturer',   'wholesale', 'Manufacturer (small)',      'निर्माता',            '🏭', 'wholesale',  12),
  ('stockist',       'wholesale', 'Stockist / Super-Stockist', 'स्टॉकिस्ट',           '🛒', 'wholesale',  13),
  ('importer',       'wholesale', 'Importer / Exporter',       'इंपोर्टर',            '📦', 'wholesale',  14)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── ONLINE / D2C (5 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('d2c_brand',      'online', 'D2C Brand (own products)',     'D2C ब्रांड',          '🛍️', 'online',     10),
  ('online_reseller','online', 'Online Reseller',              'ऑनलाइन रीसेलर',       '📲', 'online',     11),
  ('handmade',       'online', 'Etsy / Handmade Seller',       'हैंडमेड सेलर',        '🎨', 'online',     12),
  ('digital_seller', 'online', 'Digital Product Seller',       'डिजिटल प्रोडक्ट',      '🎓', 'subscription',13),
  ('marketplace',    'online', 'Marketplace Seller',           'मार्केटप्लेस सेलर',    '📦', 'online',     14)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── SUBSCRIPTION / RECURRING (4 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('coworking',      'subscription', 'Co-working Space',       'को-वर्किंग',          '💼', 'subscription',10),
  ('content_sub',    'subscription', 'Content / Subscription', 'कंटेंट सब्सक्रिप्शन', '🎬', 'subscription',11),
  ('laundry_sub',    'subscription', 'Laundry / Dry Clean',    'लॉन्ड्री',            '🛁', 'subscription',12),
  ('fee_recurring',  'subscription', 'Recurring Fees / Tuition','मासिक फीस',          '📚', 'subscription',13)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── PROPERTY (3 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('real_estate',    'property', 'Real Estate Agent',          'रियल एस्टेट एजेंट',   '🏠', 'property',   10),
  ('pg_hostel',      'property', 'PG / Hostel',                'PG / हॉस्टल',         '🏘️', 'property',   11),
  ('builder',        'property', 'Builder (small)',            'बिल्डर',              '🏗️', 'property',   12)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── HOSPITALITY (3 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('hotel',          'hospitality', 'Hotel / Lodge',           'होटल / लॉज',         '🏨', 'hospitality',10),
  ('homestay',       'hospitality', 'Homestay / B&B',          'होमस्टे',             '🏖️', 'hospitality',11),
  ('banquet',        'hospitality', 'Banquet Hall / Event Space','बैंक्वेट हॉल',     '🎪', 'hospitality',12)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;

-- ──────────────── SPECIALIZED (5 types) ────────────────
INSERT INTO sbp_business_categories (code, macro_code, name_en, name_hi, emoji, module_profile, display_order) VALUES
  ('wedding_planner','specialized', 'Wedding Planner',         'वेडिंग प्लानर',        '💒', 'services',  10),
  ('dj_musician',    'specialized', 'DJ / Musician',           'DJ / संगीतकार',       '🎵', 'services',  11),
  ('print_shop',     'specialized', 'Print Shop / Xerox',      'प्रिंट शॉप',          '🖨️', 'services',  12),
  ('travel_agent',   'specialized', 'Travel Agent / Tour',     'ट्रैवल एजेंट',        '🚖', 'services',  13),
  ('cab_transport',  'specialized', 'Cab / Transport (small)', 'कैब / ट्रांसपोर्ट',   '🚌', 'services',  14)
ON CONFLICT (code) DO UPDATE SET
  macro_code = EXCLUDED.macro_code,
  name_en = EXCLUDED.name_en,
  name_hi = EXCLUDED.name_hi,
  emoji = EXCLUDED.emoji,
  module_profile = EXCLUDED.module_profile,
  display_order = EXCLUDED.display_order;


-- ══════════════════════════════════════════════════════════════
-- 3. Module Profiles — which modules are enabled per profile
-- ══════════════════════════════════════════════════════════════
-- Drives the smart sidebar (lib/sidebar-engine.js) and feature toggles.
-- Each module has 3 states: 'active' (live now), 'soon' (Coming Soon badge),
-- or NULL (hidden — not relevant for this vertical).

CREATE TABLE IF NOT EXISTS sbp_module_profiles (
  profile      text NOT NULL,                    -- 'standard', 'restaurant', 'salon', etc.
  module_code  text NOT NULL,                    -- 'billing', 'appointments', 'qr_menu', etc.
  status       text NOT NULL CHECK (status IN ('active','soon','hidden')),
  badge        text,                             -- optional 'NEW', 'BIZ', 'PRO'
  display_order integer DEFAULT 100,
  PRIMARY KEY (profile, module_code)
);

-- Universal core modules — visible to all profiles
-- (kept implicit in code — sidebar always shows: dashboard, billing, bills, customers, stock, reports, settings)

-- Standard profile (default for retail / generic)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('standard', 'website',        'active', 'BIZ', 10),
  ('standard', 'marketing',      'active', NULL,  20),
  ('standard', 'wa_center',      'active', NULL,  30),
  ('standard', 'recurring',      'active', NULL,  40),
  ('standard', 'cash_register',  'active', NULL,  50),
  ('standard', 'supplier',       'active', NULL,  60),
  ('standard', 'team',           'active', NULL,  70),
  ('standard', 'subscription',   'active', NULL,  80)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Kirana profile (standard + delivery later)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('kirana', 'website',          'active', 'BIZ', 10),
  ('kirana', 'marketing',        'active', NULL,  20),
  ('kirana', 'wa_center',        'active', NULL,  30),
  ('kirana', 'recurring',        'active', NULL,  40),
  ('kirana', 'cash_register',    'active', NULL,  50),
  ('kirana', 'supplier',         'active', NULL,  60),
  ('kirana', 'team',             'active', NULL,  70),
  ('kirana', 'wa_catalog',       'soon',   'SOON',80),
  ('kirana', 'home_delivery',    'soon',   'SOON',90),
  ('kirana', 'loyalty',          'soon',   'SOON',100),
  ('kirana', 'subscription',     'active', NULL, 110)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Restaurant profile (QR menu, tables, orders coming)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('restaurant', 'website',      'active', 'BIZ', 10),
  ('restaurant', 'marketing',    'active', NULL,  20),
  ('restaurant', 'wa_center',    'active', NULL,  30),
  ('restaurant', 'cash_register','active', NULL,  40),
  ('restaurant', 'supplier',     'active', NULL,  50),
  ('restaurant', 'team',         'active', NULL,  60),
  ('restaurant', 'qr_menu',      'soon',   'SOON',70),
  ('restaurant', 'tables',       'soon',   'SOON',80),
  ('restaurant', 'online_orders','soon',   'SOON',90),
  ('restaurant', 'kitchen',      'soon',   'SOON',100),
  ('restaurant', 'subscription', 'active', NULL, 110)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Salon profile (appointments, services, stylists)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('salon', 'website',           'active', 'BIZ', 10),
  ('salon', 'services',          'active', 'NEW', 15),  -- universal Service Catalog (Batch 1B)
  ('salon', 'appointments',      'active', 'NEW', 20),  -- universal Appointments (Batch 1B)
  ('salon', 'marketing',         'active', NULL,  30),
  ('salon', 'wa_center',         'active', NULL,  40),
  ('salon', 'cash_register',     'active', NULL,  50),
  ('salon', 'team',              'active', NULL,  60),
  ('salon', 'stylists',          'soon',   'SOON',70),
  ('salon', 'customer_history',  'soon',   'SOON',80),
  ('salon', 'subscription',      'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Pharmacy profile (drug DB, expiry tracking)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('pharmacy', 'website',         'active', 'BIZ', 10),
  ('pharmacy', 'marketing',       'active', NULL,  20),
  ('pharmacy', 'wa_center',       'active', NULL,  30),
  ('pharmacy', 'cash_register',   'active', NULL,  40),
  ('pharmacy', 'supplier',        'active', NULL,  50),
  ('pharmacy', 'team',            'active', NULL,  60),
  ('pharmacy', 'drug_db',         'soon',   'SOON',70),
  ('pharmacy', 'expiry_alerts',   'soon',   'SOON',80),
  ('pharmacy', 'prescriptions',   'soon',   'SOON',90),
  ('pharmacy', 'subscription',    'active', NULL, 100)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Mobile / Electronics profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('mobile', 'website',           'active', 'BIZ', 10),
  ('mobile', 'marketing',         'active', NULL,  20),
  ('mobile', 'wa_center',         'active', NULL,  30),
  ('mobile', 'cash_register',     'active', NULL,  40),
  ('mobile', 'supplier',          'active', NULL,  50),
  ('mobile', 'team',              'active', NULL,  60),
  ('mobile', 'imei_tracking',     'soon',   'SOON',70),
  ('mobile', 'warranty',          'soon',   'SOON',80),
  ('mobile', 'repair_tickets',    'soon',   'SOON',90),
  ('mobile', 'subscription',      'active', NULL, 100)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Garments profile (variants, alterations)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('garments', 'website',         'active', 'BIZ', 10),
  ('garments', 'marketing',       'active', NULL,  20),
  ('garments', 'wa_center',       'active', NULL,  30),
  ('garments', 'cash_register',   'active', NULL,  40),
  ('garments', 'supplier',        'active', NULL,  50),
  ('garments', 'team',            'active', NULL,  60),
  ('garments', 'variants',        'soon',   'SOON',70),
  ('garments', 'alterations',     'soon',   'SOON',80),
  ('garments', 'subscription',    'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Jewellery profile (gold rate, hallmarking)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('jewellery', 'website',        'active', 'BIZ', 10),
  ('jewellery', 'marketing',      'active', NULL,  20),
  ('jewellery', 'wa_center',      'active', NULL,  30),
  ('jewellery', 'cash_register',  'active', NULL,  40),
  ('jewellery', 'supplier',       'active', NULL,  50),
  ('jewellery', 'team',           'active', NULL,  60),
  ('jewellery', 'gold_rate',      'soon',   'SOON',70),
  ('jewellery', 'hallmarking',    'soon',   'SOON',80),
  ('jewellery', 'subscription',   'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Auto profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('auto', 'website',             'active', 'BIZ', 10),
  ('auto', 'marketing',           'active', NULL,  20),
  ('auto', 'wa_center',           'active', NULL,  30),
  ('auto', 'cash_register',       'active', NULL,  40),
  ('auto', 'supplier',            'active', NULL,  50),
  ('auto', 'team',                'active', NULL,  60),
  ('auto', 'vehicle_tracking',    'soon',   'SOON',70),
  ('auto', 'service_history',     'soon',   'SOON',80),
  ('auto', 'subscription',        'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Healthcare profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('healthcare', 'website',       'active', 'BIZ', 10),
  ('healthcare', 'services',      'active', 'NEW', 15),
  ('healthcare', 'appointments',  'active', 'NEW', 20),
  ('healthcare', 'marketing',     'active', NULL,  30),
  ('healthcare', 'wa_center',     'active', NULL,  40),
  ('healthcare', 'cash_register', 'active', NULL,  50),
  ('healthcare', 'team',          'active', NULL,  60),
  ('healthcare', 'patients',      'soon',   'SOON',70),
  ('healthcare', 'prescriptions', 'soon',   'SOON',80),
  ('healthcare', 'subscription',  'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Education profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('education', 'website',        'active', 'BIZ', 10),
  ('education', 'services',       'active', 'NEW', 15),
  ('education', 'appointments',   'active', 'NEW', 20),
  ('education', 'marketing',      'active', NULL,  30),
  ('education', 'wa_center',      'active', NULL,  40),
  ('education', 'cash_register',  'active', NULL,  50),
  ('education', 'team',           'active', NULL,  60),
  ('education', 'batches',        'soon',   'SOON',70),
  ('education', 'attendance',     'soon',   'SOON',80),
  ('education', 'subscription',   'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Services profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('services', 'website',         'active', 'BIZ', 10),
  ('services', 'services',        'active', 'NEW', 15),
  ('services', 'appointments',    'active', 'NEW', 20),
  ('services', 'marketing',       'active', NULL,  30),
  ('services', 'wa_center',       'active', NULL,  40),
  ('services', 'cash_register',   'active', NULL,  50),
  ('services', 'team',            'active', NULL,  60),
  ('services', 'service_tickets', 'soon',   'SOON',70),
  ('services', 'subscription',    'active', NULL,  80)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Wholesale profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('wholesale', 'website',        'active', 'BIZ', 10),
  ('wholesale', 'marketing',      'active', NULL,  20),
  ('wholesale', 'wa_center',      'active', NULL,  30),
  ('wholesale', 'cash_register',  'active', NULL,  40),
  ('wholesale', 'supplier',       'active', NULL,  50),
  ('wholesale', 'team',           'active', NULL,  60),
  ('wholesale', 'salesman_app',   'soon',   'SOON',70),
  ('wholesale', 'credit_limits',  'soon',   'SOON',80),
  ('wholesale', 'subscription',   'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Online / D2C profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('online', 'website',           'active', 'BIZ', 10),
  ('online', 'marketing',         'active', NULL,  20),
  ('online', 'wa_center',         'active', NULL,  30),
  ('online', 'cash_register',     'active', NULL,  40),
  ('online', 'supplier',          'active', NULL,  50),
  ('online', 'team',              'active', NULL,  60),
  ('online', 'online_orders',     'soon',   'SOON',70),
  ('online', 'courier',           'soon',   'SOON',80),
  ('online', 'subscription',      'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Subscription profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('subscription', 'website',         'active', 'BIZ', 10),
  ('subscription', 'recurring',       'active', NULL,  20),
  ('subscription', 'marketing',       'active', NULL,  30),
  ('subscription', 'wa_center',       'active', NULL,  40),
  ('subscription', 'cash_register',   'active', NULL,  50),
  ('subscription', 'team',            'active', NULL,  60),
  ('subscription', 'members',         'soon',   'SOON',70),
  ('subscription', 'subscription',    'active', NULL,  80)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Property profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('property', 'website',         'active', 'BIZ', 10),
  ('property', 'marketing',       'active', NULL,  20),
  ('property', 'wa_center',       'active', NULL,  30),
  ('property', 'cash_register',   'active', NULL,  40),
  ('property', 'team',            'active', NULL,  60),
  ('property', 'listings',        'soon',   'SOON',70),
  ('property', 'leads',           'soon',   'SOON',80),
  ('property', 'subscription',    'active', NULL,  90)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Hospitality profile
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('hospitality', 'website',      'active', 'BIZ', 10),
  ('hospitality', 'marketing',    'active', NULL,  20),
  ('hospitality', 'wa_center',    'active', NULL,  30),
  ('hospitality', 'cash_register','active', NULL,  40),
  ('hospitality', 'team',         'active', NULL,  60),
  ('hospitality', 'rooms',        'soon',   'SOON',70),
  ('hospitality', 'bookings',     'soon',   'SOON',80),
  ('hospitality', 'folio',        'soon',   'SOON',90),
  ('hospitality', 'subscription', 'active', NULL, 100)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Food (lighter than restaurant)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('food', 'website',             'active', 'BIZ', 10),
  ('food', 'marketing',           'active', NULL,  20),
  ('food', 'wa_center',           'active', NULL,  30),
  ('food', 'cash_register',       'active', NULL,  40),
  ('food', 'supplier',            'active', NULL,  50),
  ('food', 'team',                'active', NULL,  60),
  ('food', 'online_orders',       'soon',   'SOON',70),
  ('food', 'subscription',        'active', NULL,  80)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;

-- Minimal profile (tea stalls, pan shops — bare-bones)
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('minimal', 'cash_register',    'active', NULL,  10),
  ('minimal', 'wa_center',        'active', NULL,  20),
  ('minimal', 'subscription',     'active', NULL,  30)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;


-- ══════════════════════════════════════════════════════════════
-- 4. Add shop_type column to shops
-- ══════════════════════════════════════════════════════════════
-- Defaults to 'general_retail' for any existing shops that signed up
-- before the shop type system existed.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'shops' AND column_name = 'shop_type'
  ) THEN
    ALTER TABLE shops
      ADD COLUMN shop_type text DEFAULT 'general_retail'
        REFERENCES sbp_business_categories(code) ON DELETE SET DEFAULT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_shop_type ON shops(shop_type);


-- ══════════════════════════════════════════════════════════════
-- 5. Helper RPCs — read-only category and module data
-- ══════════════════════════════════════════════════════════════

-- Returns all macro categories (for signup wizard step 1)
CREATE OR REPLACE FUNCTION public.get_macro_categories()
RETURNS TABLE (
  code text, name_en text, name_hi text, emoji text, display_order integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT code, name_en, name_hi, emoji, display_order
  FROM sbp_macro_categories
  WHERE is_active = true
  ORDER BY display_order, name_en;
$$;

-- Returns business categories under one macro (for signup wizard step 2)
CREATE OR REPLACE FUNCTION public.get_business_categories(p_macro text)
RETURNS TABLE (
  code text, name_en text, name_hi text, emoji text, module_profile text, display_order integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT code, name_en, name_hi, emoji, module_profile, display_order
  FROM sbp_business_categories
  WHERE macro_code = p_macro
    AND is_active = true
  ORDER BY display_order, name_en;
$$;

-- Resolves a shop's module visibility — used by lib/sidebar-engine.js
-- Returns the modules that should show for a given shop, with status + badge
CREATE OR REPLACE FUNCTION public.get_shop_modules(p_shop_id uuid)
RETURNS TABLE (
  module_code text, status text, badge text, display_order integer
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
AS $$
DECLARE
  v_profile text;
BEGIN
  -- Look up the shop's profile via shop_type → business_category → module_profile
  SELECT bc.module_profile INTO v_profile
  FROM shops s
  LEFT JOIN sbp_business_categories bc ON bc.code = s.shop_type
  WHERE s.id = p_shop_id;

  -- Fallback to 'standard' if shop has no type set or category not found
  IF v_profile IS NULL THEN
    v_profile := 'standard';
  END IF;

  RETURN QUERY
  SELECT mp.module_code, mp.status, mp.badge, mp.display_order
  FROM sbp_module_profiles mp
  WHERE mp.profile = v_profile
    AND mp.status IN ('active','soon')
  ORDER BY mp.display_order, mp.module_code;
END $$;

GRANT EXECUTE ON FUNCTION public.get_macro_categories() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_business_categories(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.get_shop_modules(uuid) TO authenticated;


-- ══════════════════════════════════════════════════════════════
-- DONE — Migration 003 complete.
-- ══════════════════════════════════════════════════════════════
-- Verify with:
--   SELECT count(*) FROM sbp_macro_categories;       -- expect 12
--   SELECT count(*) FROM sbp_business_categories;    -- expect 80+
--   SELECT count(DISTINCT profile) FROM sbp_module_profiles;  -- expect 18+
--   SELECT * FROM get_macro_categories();
--   SELECT * FROM get_business_categories('beauty');
-- ══════════════════════════════════════════════════════════════
