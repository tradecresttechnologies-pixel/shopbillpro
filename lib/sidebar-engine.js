/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Smart Sidebar Engine v1.0
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Single-source-of-truth for the sidebar across all user pages.
   Replaces the 6 inconsistent inline sidebars currently scattered
   across dashboard.html, billing.html, bills.html, customers.html,
   stock.html, reports.html (audit Bug #1).

   Architecture:
     1. Read shop_type from localStorage.sbp_shop
     2. Call get_shop_modules(shop_id) RPC to know which modules apply
        - If offline / no shop_id, fall back to localStorage cache
     3. Render the sidebar with universal core + vertical-specific items
     4. Items have status='active' (clickable) or 'soon' (Coming Soon badge)

   Usage (from a page in Batch 1B):
     <div id="sbp-sidebar"></div>
     <script src="lib/sidebar-engine.js"></script>
     <script>
       SBPSidebar.render({
         container: '#sbp-sidebar',
         currentPage: 'dashboard',  // matches module.code
         layout: 'desktop',         // 'desktop' or 'mobile-bottom'
       });
     </script>

   The same engine drives the desktop side rail AND the mobile bottom
   nav by passing layout='mobile-bottom' (which trims to 5 items).
══════════════════════════════════════════════════════════════════ */

window.SBPSidebar = (function() {
  'use strict';

  // ── Vertical taxonomy (single source of truth) ─────────────────────
  // Maps every shop_type code to its macro_category. Mirrors the DB
  // table sbp_business_categories (003_business_categories.sql +
  // 015_hospitality.sql). The sidebar engine reads this map at runtime
  // to apply per-vertical ordering (order_for_verticals) and Quick
  // Action sets (in dashboard.html).
  //
  // To add a new shop_type:
  //   1. Add the row in the sbp_business_categories migration
  //   2. Add the same mapping here
  //
  // Cross-macro override: pg_hostel is DB-classified as 'property' but
  // its daily workflow is hospitality (rooms, bookings, residents).
  // We route it to 'hospitality' for sidebar purposes only.
  const MACRO_BY_SHOP_TYPE = {
    // retail (18) — default behavior, no order overrides applied
    kirana: 'retail', dairy: 'retail', fruit_veg: 'retail',
    bakery_retail: 'retail', pharmacy: 'retail', mobile_elec: 'retail',
    garments: 'retail', jewellery: 'retail', furniture: 'retail',
    hardware: 'retail', stationery: 'retail', footwear: 'retail',
    gift_shop: 'retail', pet_shop: 'retail', plant_nursery: 'retail',
    auto_parts: 'retail', tea_pan: 'retail', general_retail: 'retail',

    // food (9) — Restaurants, cafes, QSR, tiffin etc.
    restaurant: 'food', cafe: 'food', qsr: 'food', ice_cream: 'food',
    cloud_kitchen: 'food', tiffin: 'food', catering: 'food',
    bar_lounge: 'food', food_other: 'food',

    // beauty (9) — Salon, spa, gym, yoga, tattoo
    salon: 'beauty', spa: 'beauty', nail_beauty: 'beauty',
    unisex_salon: 'beauty', wellness: 'beauty', gym: 'beauty',
    yoga: 'beauty', sports_club: 'beauty', tattoo: 'beauty',

    // healthcare (7) — Clinics, dentists, opticians, vets, labs
    clinic: 'healthcare', dentist: 'healthcare', optician: 'healthcare',
    vet: 'healthcare', lab: 'healthcare', physio: 'healthcare',
    counselling: 'healthcare',

    // education (7) — Coaching, art classes, libraries, online courses
    coaching: 'education', art_class: 'education', online_course: 'education',
    library: 'education', driving_school: 'education',
    skill_training: 'education', personal_coach: 'education',

    // services + specialized merged (16) — same daily flow (book → do → bill)
    handyman: 'services', home_services: 'services', device_repair: 'services',
    photographer: 'services', event_mgr: 'services', car_wash: 'services',
    interior: 'services', agency_help: 'services', movers: 'services',
    tailor: 'services', pet_groomer: 'services',
    wedding_planner: 'services', dj_musician: 'services',
    print_shop: 'services', travel_agent: 'services', cab_transport: 'services',

    // wholesale (5) — B2B distributors, mandis, manufacturers
    distributor: 'wholesale', mandi: 'wholesale', manufacturer: 'wholesale',
    stockist: 'wholesale', importer: 'wholesale',

    // online / D2C (4) — Online resellers, handmade, marketplaces
    online_reseller: 'online', handmade: 'online',
    digital_seller: 'online', marketplace: 'online',

    // subscription (4) — Coworking, content, laundry, recurring fees
    coworking: 'subscription', content_sub: 'subscription',
    laundry_sub: 'subscription', fee_recurring: 'subscription',

    // property (2) — Real estate, builders. pg_hostel routed to hospitality below.
    real_estate: 'property', builder: 'property',

    // hospitality (11 native + pg_hostel cross-routed = 12)
    hotel: 'hospitality', homestay: 'hospitality', banquet: 'hospitality',
    resort: 'hospitality', guesthouse: 'hospitality',
    service_apartment: 'hospitality', hostel: 'hospitality',
    dharamshala: 'hospitality', day_room: 'hospitality',
    boutique_hotel: 'hospitality', camping: 'hospitality',
    pg_hostel: 'hospitality',  // CROSS-MACRO: DB says property, behaves like hospitality
  };

  function _macroForShop(shopType) {
    if (!shopType) return 'retail';
    return MACRO_BY_SHOP_TYPE[shopType] || 'retail';
  }

  function _isHospitalityShop(shopType) {
    return _macroForShop(shopType) === 'hospitality';
  }

  // ── Universal core (always shown for every shop, every plan) ───
  // order_for_verticals overrides the default `order` field when the
  // shop's macro_category matches a key. Used to reshape the sidebar
  // around each vertical's daily workflow without changing module
  // visibility (the server's get_shop_modules RPC handles visibility).
  const UNIVERSAL_CORE = [
    { code: 'dashboard', href: 'dashboard.html', icon: '🏠', label_en: 'Home',     label_hi: 'होम',       order: 0 },
    // Bills/New Bill default to retail-flow (order 10/20 — top of list).
    // For service-flow verticals (beauty/healthcare/education/services/subscription/property),
    // billing is secondary to scheduling — push it below the daily-flow modules.
    // For hospitality, the folio finalize flow is the primary billing path; bills list is reference.
    { code: 'bills',     href: 'bills.html',     icon: '🧾', label_en: 'Bills',    label_hi: 'बिल',       order: 10,
      order_for_verticals: { hospitality: 45, beauty: 30, healthcare: 35, education: 35, services: 30, subscription: 30, property: 30 } },
    { code: 'billing',   href: 'billing.html',   icon: '＋', label_en: 'New Bill', label_hi: 'नया बिल',   order: 20, isFab: true,
      order_for_verticals: { hospitality: 48, beauty: 35, healthcare: 40, education: 40, services: 35, subscription: 35, property: 35 } },
    { code: 'customers', href: 'customers.html', icon: '👥', label_en: 'Customers',label_hi: 'ग्राहक',    order: 30,
      // education uses Customers as Students — promote it. beauty/services keep default 30 which sits naturally.
      order_for_verticals: { education: 5, subscription: 15, hospitality: 35, healthcare: 10, services: 15, property: 15, beauty: 20 } },
    // Stock is irrelevant for service-flow verticals (no inventory in salons, clinics, schools, services).
    // Pushed to "More" group via more_for_categories.
    { code: 'stock',     href: 'stock.html',     icon: '📦', label_en: 'Stock',    label_hi: 'स्टॉक',     order: 40,
      more_for_verticals: ['hotel','homestay','pg_hostel','banquet','hospitality','day_room'],
      more_for_categories: ['hospitality','beauty','healthcare','education','services','subscription','property'] },
    { code: 'reports',   href: 'reports.html',   icon: '📊', label_en: 'Reports',  label_hi: 'रिपोर्ट',   order: 50 },
    // POS Admin: same — only retail/food/wholesale/online actually run a POS counter.
    { code: 'pos-admin', href: 'pos-admin.html', icon: '🛒', label_en: 'POS Admin', label_hi: 'POS एडमिन', order: 55,
      more_for_verticals: ['hotel','homestay','pg_hostel','banquet','hospitality','day_room'],
      more_for_categories: ['hospitality','beauty','healthcare','education','services','subscription','property'] },
    // Hotel-polish (12 May 2026): bill-templates removed from sidebar. Page file kept on disk; just unlinked.
    // { code: 'bill-templates', href: 'bill-templates.html', icon: '🗂️', label_en: 'Templates', label_hi: 'टेम्पलेट', order: 135 },
    // BATCH 1B-C: 'settings' is "More" on mobile bnav (5-slot overflow), "Settings" on desktop side rail
    { code: 'settings',  href: 'settings.html',  icon: '⚙️', label_en: 'Settings', label_hi: 'सेटिंग्स',  order: 200, mobileLabel_en: 'More', mobileLabel_hi: 'अधिक', mobileIcon: '☰' },
  ];

  // ── Module catalog: every vertical module mapped to icon/href/label
  // Each entry can declare:
  //   - order: default position (used for retail and as fallback)
  //   - order_for_verticals: { food: 25, beauty: 5, ... } — per-macro override
  //   - more_for_verticals: [shop_type codes] — legacy, exact match
  //   - more_for_categories: [macro codes] — moves item to "More" group
  //   - owner_only: true — hidden for non-owner accounts
  //   - more_group: true — always in "More" group
  const MODULE_CATALOG = {
    'website':         { href: 'website-builder.html',  icon: '🌐', label_en: 'Website',          label_hi: 'वेबसाइट',         order: 60 },
    'marketing':       { href: 'marketing.html',        icon: '📢', label_en: 'Marketing',        label_hi: 'मार्केटिंग',       order: 70 },
    'wa_center':       { href: 'wa-center.html',        icon: '💬', label_en: 'WhatsApp',         label_hi: 'व्हाट्सऐप',        order: 80 },
    // Recurring is THE primary action for subscription + education (monthly fees) — promote heavily
    'recurring':       { href: 'recurring.html',        icon: '🔁', label_en: 'Recurring',        label_hi: 'रिकरिंग',         order: 90,
      order_for_verticals: { subscription: 10, education: 20 },
      more_for_verticals: ['hotel','homestay','pg_hostel','banquet','hospitality','day_room'],
      more_for_categories: ['hospitality','beauty','healthcare','services','property'] },
    'cash_register':   { href: 'cash-register.html',    icon: '💵', label_en: 'Cash Register',    label_hi: 'कैश रजिस्टर',     order: 100 },
    'supplier':        { href: 'supplier.html',         icon: '🏭', label_en: 'Suppliers',        label_hi: 'सप्लायर',         order: 110,
      // Suppliers very relevant for wholesale; irrelevant for service-flow verticals
      order_for_verticals: { wholesale: 45 },
      more_for_verticals: ['hotel','homestay','pg_hostel','banquet','hospitality','day_room'],
      more_for_categories: ['hospitality','beauty','healthcare','education','services','subscription','property'] },
    'team':            { href: 'team.html',             icon: '👨‍👩‍👧', label_en: 'Team',           label_hi: 'टीम',             order: 120, owner_only: true, more_group: true },
    // 022D Link Wiring: Authorized Users + Audit Log (server-side enforces owner-only access)
    // 022E: also flag client-side owner_only so non-owner accounts don't even see the menu entries.
    'authorized_users':{ href: 'authorized-users.html', icon: '🔒', label_en: 'Authorized Users', label_hi: 'अधिकृत उपयोगकर्ता', order: 122, owner_only: true, more_group: true },
    'audit_log':       { href: 'audit-log.html',        icon: '📋', label_en: 'Audit Log',        label_hi: 'ऑडिट लॉग',          order: 124, owner_only: true, more_group: true },
    'subscription':    { href: 'subscription.html',     icon: '💎', label_en: 'Plans',            label_hi: 'प्लान',            order: 130, owner_only: true, more_group: true },
    // Universal add-ons — Appointments/Services are THE primary daily action for beauty/healthcare/services
    'services':        { href: 'services.html',         icon: '🛎️', label_en: 'Services',         label_hi: 'सेवाएं',           order: 140,
      order_for_verticals: { beauty: 8, healthcare: 25, services: 8, hospitality: 70 } },
    'appointments':    { href: 'appointments.html',     icon: '📅', label_en: 'Appointments',     label_hi: 'अपॉइंटमेंट',       order: 150,
      order_for_verticals: { beauty: 5, healthcare: 5, services: 5, education: 25, hospitality: 75 } },
    // ── Vertical-specific modules ──
    // Food/Restaurant family
    'menu':            { href: 'menu.html',    icon: '🍽️', label_en: 'Menu',            label_hi: 'मेनू',              order: 155,
      order_for_verticals: { food: 22 } },
    'qr_menu':         { href: 'tables.html', icon: '📱', label_en: 'QR Menu',         label_hi: 'QR मेनू',          order: 160,
      order_for_verticals: { food: 42 } },
    'tables':          { href: 'tables.html',         icon: '🍽️', label_en: 'Tables',          label_hi: 'टेबल',             order: 170,
      order_for_verticals: { food: 25 } },
    'online_orders':   { icon: '🛒', label_en: 'Online Orders',   label_hi: 'ऑनलाइन ऑर्डर',     order: 180,
      order_for_verticals: { food: 35 } },
    'kitchen':         { href: 'kitchen.html', icon: '👨‍🍳', label_en: 'Kitchen',        label_hi: 'किचन',             order: 190,
      order_for_verticals: { food: 28 } },
    'restaurant_reports':{ href: 'restaurant-reports.html', icon: '📈', label_en: 'Restaurant Reports', label_hi: 'रेस्तरां रिपोर्ट', order: 195,
      order_for_verticals: { food: 30, hospitality: 80 } },
    // Beauty/Salon family
    'stylists':        { icon: '✂️', label_en: 'Stylists',        label_hi: 'स्टाइलिस्ट',        order: 160,
      order_for_verticals: { beauty: 12 } },
    'customer_history':{ href: 'customer-history.html', icon: '📋', label_en: 'History',         label_hi: 'इतिहास',           order: 170,
      // History view is daily-useful for service-flow verticals
      order_for_verticals: { beauty: 38, healthcare: 15, services: 20, property: 25 } },
    // Healthcare family — Drug DB / Expiry / Prescriptions are catalog placeholders (no href yet)
    'drug_db':         { icon: '💊', label_en: 'Drug Database',   label_hi: 'दवा डेटाबेस',       order: 160,
      order_for_verticals: { healthcare: 25 } },
    'expiry_alerts':   { icon: '⏰', label_en: 'Expiry',           label_hi: 'समाप्ति',           order: 170,
      order_for_verticals: { healthcare: 28 } },
    'prescriptions':   { icon: '📝', label_en: 'Prescriptions',   label_hi: 'पर्ची',            order: 180,
      order_for_verticals: { healthcare: 20 } },
    // Mobile/electronics (placeholders)
    'imei_tracking':   { icon: '📲', label_en: 'IMEI',             label_hi: 'IMEI',             order: 160 },
    'warranty':        { icon: '🛡️', label_en: 'Warranty',        label_hi: 'वारंटी',           order: 170 },
    'repair_tickets':  { icon: '🔧', label_en: 'Repairs',          label_hi: 'मरम्मत',           order: 180 },
    // Apparel (placeholders)
    'variants':        { icon: '🎨', label_en: 'Variants',        label_hi: 'वेरिएंट',          order: 160 },
    'alterations':     { icon: '📐', label_en: 'Alterations',     label_hi: 'अल्टरेशन',         order: 170 },
    // Jewellery (placeholders)
    'gold_rate':       { icon: '🏆', label_en: 'Gold Rate',       label_hi: 'सोने की दर',       order: 160 },
    'hallmarking':     { icon: '✨', label_en: 'Hallmarking',     label_hi: 'हॉलमार्किंग',      order: 170 },
    // Auto (placeholders)
    'vehicle_tracking':{ icon: '🚗', label_en: 'Vehicle',          label_hi: 'गाड़ी',           order: 160 },
    'service_history': { icon: '📋', label_en: 'Service History', label_hi: 'सर्विस इतिहास',    order: 170 },
    // Healthcare patients (placeholder — currently aliases to customers)
    'patients':        { icon: '🏥', label_en: 'Patients',         label_hi: 'मरीज',             order: 160,
      order_for_verticals: { healthcare: 8 } },
    // Education (placeholders)
    'batches':         { icon: '👨‍🎓', label_en: 'Batches',        label_hi: 'बैच',              order: 160,
      order_for_verticals: { education: 10 } },
    'attendance':      { icon: '✅', label_en: 'Attendance',      label_hi: 'उपस्थिति',          order: 170,
      order_for_verticals: { education: 15, subscription: 20 } },
    // Services
    'service_tickets': { icon: '🎫', label_en: 'Tickets',          label_hi: 'टिकट',             order: 160,
      order_for_verticals: { services: 12 } },
    // Wholesale (placeholders)
    'salesman_app':    { icon: '🚶', label_en: 'Salesman',        label_hi: 'सेल्समैन',         order: 160,
      order_for_verticals: { wholesale: 40 } },
    'credit_limits':   { icon: '💳', label_en: 'Credit Limits',   label_hi: 'क्रेडिट लिमिट',    order: 170,
      order_for_verticals: { wholesale: 32 } },
    // Online/D2C (placeholders)
    'wa_catalog':      { icon: '🛍️', label_en: 'WA Catalog',      label_hi: 'WA कैटलॉग',       order: 160,
      order_for_verticals: { online: 41 } },
    'home_delivery':   { icon: '🛵', label_en: 'Delivery',        label_hi: 'डिलीवरी',         order: 170,
      order_for_verticals: { online: 42 } },
    'loyalty':         { href: 'loyalty.html', icon: '⭐', label_en: 'Loyalty',          label_hi: 'लॉयल्टी',         order: 180,
      order_for_verticals: { beauty: 40 } },
    'courier':         { icon: '📮', label_en: 'Courier',         label_hi: 'कूरियर',           order: 180,
      order_for_verticals: { online: 35 } },
    // Subscription (placeholder)
    'members':         { icon: '🎟️', label_en: 'Members',         label_hi: 'सदस्य',           order: 160,
      order_for_verticals: { subscription: 5 } },
    // Property (placeholders)
    'listings':        { icon: '🏘️', label_en: 'Listings',        label_hi: 'लिस्टिंग',         order: 160,
      order_for_verticals: { property: 5 } },
    'leads':           { icon: '📞', label_en: 'Leads',           label_hi: 'लीड्स',            order: 170,
      order_for_verticals: { property: 8 } },
    // ── Hospitality family (built in Batch 015 + 021) ──
    'rooms':           { href: 'rooms.html',       icon: '🛏️', label_en: 'Rooms',           label_hi: 'कमरे',             order: 160,
      order_for_verticals: { hospitality: 12 } },
    'folio':           { href: 'folio.html',       icon: '📋', label_en: 'Folio',           label_hi: 'फ़ोलियो',           order: 165,
      order_for_verticals: { hospitality: 18 } },
    'bookings':        { href: 'bookings.html',    icon: '📆', label_en: 'Bookings',        label_hi: 'बुकिंग',           order: 170,
      order_for_verticals: { hospitality: 15 } },
    'front_desk':      { href: 'front-desk.html',  icon: '🛎️', label_en: 'Front Desk',      label_hi: 'फ्रंट डेस्क',      order: 155,
      order_for_verticals: { hospitality: 5 } },
    'walk_in':         { href: 'walk-in.html',     icon: '⚡', label_en: 'Walk-in',         label_hi: 'वॉक-इन',           order: 156,
      order_for_verticals: { hospitality: 8 } },
    'compliance':      { href: 'compliance.html',  icon: '📋', label_en: 'Compliance',     label_hi: 'अनुपालन',          order: 175,
      order_for_verticals: { hospitality: 22 } },
    // BATCH 017 BUG-021 FIX: 'folio' menu item removed. It pointed to bookings.html
    // (since folio is per-booking, not a standalone page) and confused users.
    // Folio is accessed inline via Bookings → tap booking → folio section.
    // Server-side module profile may still mark folio as 'active' for hospitality
    // shops; sidebar engine simply ignores codes without a catalog entry now.
  };

  // ── Helpers ────────────────────────────────────────────────────
  function _shop() {
    try { return JSON.parse(localStorage.getItem('sbp_shop') || '{}'); }
    catch (_) { return {}; }
  }

  function _cacheKey(shopId) { return 'sbp_modules_cache:' + (shopId || 'anon'); }
  function _saveCache(shopId, modules) {
    try { localStorage.setItem(_cacheKey(shopId), JSON.stringify({ ts: Date.now(), modules })); } catch (_) {}
  }
  function _loadCache(shopId) {
    try {
      const raw = localStorage.getItem(_cacheKey(shopId));
      if (!raw) return null;
      return JSON.parse(raw).modules;
    } catch (_) { return null; }
  }

  // Sensible default when shop has no DB type yet (new install, offline)
  const DEFAULT_FALLBACK = [
    { module_code: 'website',       status: 'active', badge: 'BIZ',  display_order: 60  },
    { module_code: 'marketing',     status: 'active', badge: null,   display_order: 70  },
    { module_code: 'wa_center',     status: 'active', badge: null,   display_order: 80  },
    { module_code: 'recurring',     status: 'active', badge: null,   display_order: 90  },
    { module_code: 'cash_register', status: 'active', badge: null,   display_order: 100 },
    { module_code: 'supplier',      status: 'active', badge: null,   display_order: 110 },
    { module_code: 'team',          status: 'active', badge: null,   display_order: 120 },
    // 022D Link Wiring: Security + audit are universal across all shops/verticals
    { module_code: 'authorized_users', status: 'active', badge: null, display_order: 122 },
    { module_code: 'audit_log',     status: 'active', badge: null,   display_order: 124 },
    { module_code: 'subscription',  status: 'active', badge: null,   display_order: 130 },
  ];

  async function _fetchModules(sbClient, shopId) {
    if (!sbClient || !shopId) return DEFAULT_FALLBACK;
    try {
      const { data, error } = await sbClient.rpc('get_shop_modules', { p_shop_id: shopId });
      if (error) {
        console.warn('[SBPSidebar] RPC error, falling back to cache:', error.message);
        return _loadCache(shopId) || DEFAULT_FALLBACK;
      }
      const modules = data || [];
      _saveCache(shopId, modules);
      return modules;
    } catch (e) {
      console.warn('[SBPSidebar] Fetch failed:', e);
      return _loadCache(shopId) || DEFAULT_FALLBACK;
    }
  }

  // ── BATCH 1B-G-Hotfix: pending pages get forced to 'soon' until built ──
  // These pages don't exist yet — clicking them would 404. Force 'soon' status
  // so they show "Coming Soon" toast instead of navigating. As pages get built,
  // remove from this set.
  // ── BATCH 012 (6 May 2026): services + appointments BUILT and shipped.
  // ── BATCH 013 (6 May 2026): customer_history BUILT and shipped.
  //    Removed from PENDING_PAGES — they now navigate normally and show
  //    their 'NEW' badge from sbp_module_profiles.
  const PENDING_PAGES = new Set([
    // 'services',          — built and shipped 5 May 2026 (Service Catalog)
    // 'appointments',      — built and shipped 5 May 2026 (Universal Appointments)
    // 'customer_history',  — built and shipped 6 May 2026 (Batch 013)
    'stylists',          // stylists.html — placeholder (deeper salon feature, future batch)
  ]);

  // ── 022E: Owner detection ───────────────────────────────────────
  // The single signal across the app is localStorage.sbp_is_staff === '1'.
  // Any non-staff session is treated as owner-class (Admin/Owner).
  // Used to filter out owner_only modules for cashier/manager/viewer accounts.
  function _isOwner() {
    try {
      return localStorage.getItem('sbp_is_staff') !== '1';
    } catch (e) {
      return true;  // Safer default — RPCs still enforce server-side
    }
  }

  // ── Build the full ordered list (universal core + vertical) ────
  function _buildItems(verticalModules, currentPage) {
    const isOwner = _isOwner();
    // Read shop_type and resolve macro category once per build.
    // The engine uses macro to apply per-vertical ordering and to
    // route items into the "More" group on verticals where they
    // don't fit (e.g. Stock + POS Admin for hospitality/salon/clinic).
    const shopType = (_shop() || {}).shop_type || '';
    const macro    = _macroForShop(shopType);

    function _inMoreForVertical(itemCat) {
      // 1. Exact shop_type match in more_for_verticals (legacy)
      if (Array.isArray(itemCat.more_for_verticals)
          && itemCat.more_for_verticals.indexOf(shopType) !== -1) return true;
      // 2. Macro category match in more_for_categories (preferred — covers all sub-types)
      if (Array.isArray(itemCat.more_for_categories)
          && itemCat.more_for_categories.indexOf(macro) !== -1) return true;
      return false;
    }

    function _orderFor(itemCat) {
      // Per-macro override wins; exact shop_type next; default order last.
      const map = itemCat.order_for_verticals;
      if (map) {
        // Exact shop_type match (rare, for ultra-specific tuning)
        if (map[shopType] !== undefined) return map[shopType];
        // Macro category match (the common case)
        if (map[macro] !== undefined) return map[macro];
      }
      return itemCat.order;
    }

    const items = [];
    UNIVERSAL_CORE.forEach(c => {
      // Universal items never get owner_only flag — they're always shown.
      items.push({
        ...c,
        order: _orderFor(c),
        status: 'active',
        active: c.code === currentPage,
        more_group: !!c.more_group || _inMoreForVertical(c),
      });
    });
    (verticalModules || []).forEach(m => {
      const cat = MODULE_CATALOG[m.module_code];
      if (!cat) return;
      // 022E: owner_only modules are hidden entirely for non-owner accounts.
      // Server-side RPCs also enforce owner check, so hiding here is just UX —
      // a non-owner can't reach the page even via direct URL.
      if (cat.owner_only && !isOwner) return;
      // BATCH 1B-G-Hotfix: force 'soon' for pages not yet built
      const effectiveStatus = PENDING_PAGES.has(m.module_code) ? 'soon' : m.status;
      // Order resolution: vertical override → catalog default → server display_order
      const overrideOrder = _orderFor(cat);
      const resolvedOrder = (overrideOrder !== undefined) ? overrideOrder : m.display_order;
      items.push({
        code: m.module_code,
        href: effectiveStatus === 'active' ? (cat.href || '#') : '#',
        icon: cat.icon,
        label_en: cat.label_en,
        label_hi: cat.label_hi,
        order: resolvedOrder,
        status: effectiveStatus,
        badge: m.badge || null,
        active: m.module_code === currentPage,
        owner_only: !!cat.owner_only,  // propagated for potential downstream use
        more_group: !!cat.more_group || _inMoreForVertical(cat),
      });
    });
    // BATCH 1B-C-Pilot: fix falsy-0 bug — Home has order:0 which || treats as undefined
    items.sort((a, b) => {
      const oa = (a.order === undefined || a.order === null) ? 999 : a.order;
      const ob = (b.order === undefined || b.order === null) ? 999 : b.order;
      return oa - ob;
    });
    return items;
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  function _renderItem(item, layout) {
    // BATCH 1B-C: desktop layout uses .dsb-* classes that match existing styles.css rules
    if (layout === 'desktop') {
      const cls = ['dsb-item'];
      if (item.active) cls.push('active');
      if (item.isFab) cls.push('fab-sb');
      if (item.status === 'soon') cls.push('coming-soon');
      const isSoon = item.status === 'soon';
      const href = isSoon ? '#' : (item.href || '#');
      const onclickAttr = isSoon
        ? ` onclick="event.preventDefault(); SBPSidebar._showSoon('${esc(item.label_en)}'); return false;"`
        : '';
      const badgeHtml = item.badge
        ? `<span class="dsb-badge" style="margin-left:auto;font-size:9px;font-weight:800;background:linear-gradient(135deg,#F59E0B,#EF4444);color:#fff;border-radius:4px;padding:2px 5px;letter-spacing:.3px">${esc(item.badge)}</span>`
        : '';
      return `<a class="${cls.join(' ')}" href="${esc(href)}"${onclickAttr}>` +
        `<span class="dsb-ic">${item.icon}</span>` +
        `<span><span class="lang-en">${esc(item.label_en)}</span><span class="lang-hi">${esc(item.label_hi || item.label_en)}</span></span>` +
        badgeHtml +
        `</a>`;
    }

    // BATCH 1B-F: mobile-drawer layout — full vertical list, all items, tap to navigate
    if (layout === 'mobile-drawer') {
      const cls = ['drawer-item'];
      if (item.active) cls.push('active');
      if (item.status === 'soon') cls.push('coming-soon');
      const isSoon = item.status === 'soon';
      // FAB (+New Bill) gets special treatment in drawer — visible like a normal nav item, not a floating button
      const onclickAttr = isSoon
        ? ` onclick="event.preventDefault(); SBPSidebar._closeDrawer(); SBPSidebar._showSoon('${esc(item.label_en)}'); return false;"`
        : ` onclick="SBPSidebar._closeDrawer();"`;
      const href = isSoon ? '#' : (item.href || '#');
      const badgeHtml = item.badge
        ? `<span class="drawer-badge" style="margin-left:auto;font-size:9px;font-weight:800;background:linear-gradient(135deg,#F59E0B,#EF4444);color:#fff;border-radius:4px;padding:2px 6px;letter-spacing:.3px">${esc(item.badge)}</span>`
        : '';
      return `<a class="${cls.join(' ')}" href="${esc(href)}"${onclickAttr}>` +
        `<span class="drawer-ic">${item.icon}</span>` +
        `<span class="drawer-lb"><span class="lang-en">${esc(item.label_en)}</span><span class="lang-hi">${esc(item.label_hi || item.label_en)}</span></span>` +
        badgeHtml +
        `</a>`;
    }

    // Mobile bnav layout (existing — unchanged)
    const cls = ['ni'];
    if (item.active) cls.push('on');
    if (item.isFab) cls.push('fab-item');
    if (item.status === 'soon') cls.push('coming-soon');
    const onclick = item.status === 'soon'
      ? `SBPSidebar._showSoon('${esc(item.label_en)}')`
      : `window.location.href='${esc(item.href)}'`;
    const badgeHtml = item.badge
      ? `<span class="ni-badge" data-b="${esc(item.badge)}" style="position:absolute;top:2px;right:8px;font-size:7px;font-weight:800;background:linear-gradient(135deg,#F59E0B,#EF4444);color:#fff;border-radius:4px;padding:1px 4px;letter-spacing:.3px">${esc(item.badge)}</span>`
      : '';
    if (item.isFab) {
      return `<div class="${cls.join(' ')}" onclick="${onclick}" style="align-items:center;justify-content:center"><div class="nav-fab">${item.icon}</div></div>`;
    }
    // BATCH 1B-C: mobile uses mobileLabel_* + mobileIcon if defined (Settings → "More" on mobile)
    // BATCH 1B-F: 'settings' becomes "More" on mobile and opens drawer instead of navigating
    const mobLabelEn = item.mobileLabel_en || item.label_en;
    const mobLabelHi = item.mobileLabel_hi || item.label_hi || item.label_en;
    const mobIcon    = item.mobileIcon    || item.icon;
    // BATCH 1B-F: if this is the "More" item (settings), override onclick to open drawer
    const isMoreButton = item.code === 'settings';
    const mobOnclick = isMoreButton
      ? `SBPSidebar._openDrawer()`
      : onclick;
    return `<div class="${cls.join(' ')}" onclick="${mobOnclick}" style="position:relative"><span class="ni-ic">${mobIcon}</span><span class="ni-lb"><span class="lang-en">${esc(mobLabelEn)}</span><span class="lang-hi">${esc(mobLabelHi)}</span></span>${badgeHtml}</div>`;
  }

  // BATCH 1B-C: SVG logo (copied from existing inline sidebars in dashboard.html etc.)
  const _DSB_SVG = '<svg width="22" height="24" viewBox="0 0 56 62" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M28 2L4 14V32C4 46 28 60 28 60C28 60 52 46 52 32V14L28 2Z" fill="url(#sg1)"/><rect x="18" y="18" width="20" height="26" rx="2" fill="#0A0E1A" fill-opacity=".6"/><rect x="18" y="18" width="20" height="26" rx="2" stroke="#fff" stroke-width="1.5" fill="none"/><line x1="22" y1="24" x2="34" y2="24" stroke="#F5A623" stroke-width="1.5" stroke-linecap="round"/><line x1="22" y1="28" x2="30" y2="28" stroke="rgba(255,255,255,.4)" stroke-width="1" stroke-linecap="round"/><line x1="22" y1="31" x2="32" y2="31" stroke="rgba(255,255,255,.4)" stroke-width="1" stroke-linecap="round"/><line x1="22" y1="34" x2="28" y2="34" stroke="rgba(255,255,255,.4)" stroke-width="1" stroke-linecap="round"/><circle cx="32" cy="37" r="5" fill="#F5A623"/><polyline points="30,37 31.5,38.5 34.5,35.5" fill="none" stroke="#0A0E1A" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><defs><linearGradient id="sg1" x1="4" y1="2" x2="52" y2="60" gradientUnits="userSpaceOnUse"><stop offset="0%" stop-color="#F5A623"/><stop offset="100%" stop-color="#FF6B35"/></linearGradient></defs></svg>';

  function _renderSidebar(items, layout) {
    if (layout === 'mobile-bottom') {
      // Bottom nav: 5-slot pattern [Home] [Bills] [+] [Marketing] [Settings]
      const list = items.filter(i => !i.isFab);
      const fab  = items.find(i => i.isFab);
      const get  = code => list.find(i => i.code === code);
      const slots = [];
      const home = get('dashboard');     if (home) slots.push(home);
      const bills = get('bills');        if (bills) slots.push(bills);
      if (fab) slots.push(fab);
      const mkt = get('marketing');      if (mkt) slots.push(mkt);
      const set = get('settings');       if (set) slots.push(set);
      return slots.map(i => _renderItem(i, layout)).join('');
    }
    // BATCH 1B-F: mobile-drawer layout — full menu in slide-out panel
    if (layout === 'mobile-drawer') {
      // Header (close button + title) and footer (logout + version)
      // Items themselves rendered by _renderItem with layout='mobile-drawer'
      // Note: the bnav already shows Home/Bills/+/Marketing/More — drawer can omit those
      // OR include them so users can see "everything in one place". We include them all.
      return '<div class="drawer-header">' +
          '<div class="drawer-title">' + _DSB_SVG + '<span class="drawer-brand">ShopBill Pro</span></div>' +
          '<button class="drawer-close" type="button" onclick="SBPSidebar._closeDrawer()" aria-label="Close menu">✕</button>' +
        '</div>' +
        '<div class="drawer-nav">' + items.map(i => _renderItem(i, layout)).join('') + '</div>' +
        '<div class="drawer-footer">' +
          '<button class="drawer-item" id="drawer-logout" type="button">' +
            '<span class="drawer-ic">🚪</span>' +
            '<span class="drawer-lb"><span class="lang-en">Logout</span><span class="lang-hi">लॉगआउट</span></span>' +
          '</button>' +
          '<div class="drawer-ver">ShopBill Pro v1.0</div>' +
        '</div>';
    }
    // BATCH 1B-C: Desktop layout — full structure matching styles.css .dsb-* rules
    // 022E: split items into primary (always visible) + collapsible "More" group.
    //       Items flagged `more_group: true` (Team / Authorized Users / Audit Log /
    //       Plans) are tucked behind a "More ⚙️" toggle to keep the sidebar tight.
    //       Settings is part of universal core and stays at the very bottom.
    if (layout === 'desktop') {
      const primary  = items.filter(i => !i.more_group);
      const moreItems = items.filter(i => i.more_group);
      // If "More" group has the active page, force it open on initial render
      const anyMoreActive = moreItems.some(i => i.active);
      const initiallyOpen = anyMoreActive
        || (function(){ try { return localStorage.getItem('sbp_sidebar_more_open') === '1'; } catch(e){ return false; } })();
      const moreHtml = moreItems.length === 0
        ? ''
        : (function(){
            const groupClasses = ['dsb-more-group'];
            if (initiallyOpen) groupClasses.push('open');
            return '<div class="' + groupClasses.join(' ') + '" id="dsb-more-group">' +
              '<button type="button" class="dsb-more-toggle" onclick="SBPSidebar._toggleMore()" aria-expanded="' + (initiallyOpen ? 'true' : 'false') + '">' +
                '<span class="dsb-ic">⚙️</span>' +
                '<span class="dsb-more-label">' +
                  '<span class="lang-en">More</span>' +
                  '<span class="lang-hi">अधिक</span>' +
                '</span>' +
                '<span class="dsb-more-arr">›</span>' +
              '</button>' +
              '<div class="dsb-more-list">' +
                moreItems.map(i => _renderItem(i, layout)).join('') +
              '</div>' +
            '</div>';
          })();
      return '<div class="dsb-logo">' + _DSB_SVG + '<span class="dsb-brand">ShopBill Pro</span></div>' +
        '<div class="dsb-nav">' + primary.map(i => _renderItem(i, layout)).join('') + moreHtml + '</div>' +
        '<div class="dsb-footer">' +
          '<button class="dsb-item" id="dsb-logout" type="button">' +
            '<span class="dsb-ic">🚪</span>' +
            '<span><span class="lang-en">Logout</span><span class="lang-hi">लॉगआउट</span></span>' +
          '</button>' +
          '<div class="dsb-ver">ShopBill Pro v1.0</div>' +
        '</div>';
    }
    // Default: simple list (used by mobile bnav non-bottom variant or custom containers)
    return items.map(i => _renderItem(i, layout)).join('');
  }

  function _showSoon(label) {
    // Soft floating toast — non-blocking
    const t = document.createElement('div');
    t.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);background:rgba(20,18,32,.95);border:1px solid #F5A623;color:#F5A623;padding:12px 22px;border-radius:24px;font-weight:700;z-index:9999;font-size:13px;font-family:Outfit,sans-serif;box-shadow:0 4px 24px rgba(0,0,0,.5)';
    t.textContent = '✨ ' + label + ' — Coming Soon!';
    document.body.appendChild(t);
    setTimeout(() => { t.style.transition = 'opacity .3s'; t.style.opacity = '0'; }, 1800);
    setTimeout(() => { t.remove(); }, 2200);
  }

  // ── BATCH 1B-G-Hotfix: inject critical CSS rules at runtime ────
  // Some pages have stray brace bugs in their <style> blocks that break
  // .lang-en/.lang-hi rules. This injects them via a dynamic <style> tag at
  // end of <head>, which lands AFTER any in-page CSS and applies regardless
  // of broken-CSS pages. Idempotent (only injects once per page load).
  function _injectStyles() {
    if (document.getElementById('sbp-lib-styles')) return;
    const style = document.createElement('style');
    style.id = 'sbp-lib-styles';
    style.textContent =
      '/* SBPSidebar lib runtime CSS — bilingual toggle (works even on pages with broken CSS) */' +
      '.lang-hi{display:none!important}' +
      '.lang-en{display:inline!important}' +
      'html[lang="hi"] .lang-hi{display:inline!important}' +
      'html[lang="hi"] .lang-en{display:none!important}' +
      /* ── Canonical sidebar CSS (BATCH UI-3: scoped under #dsb.dsb-root) ──
         The engine tags its mounted container with .dsb-root. Scoping every
         rule under #dsb.dsb-root gives (id+class) specificity, which strictly
         outranks any per-page bare #dsb / .dsb-item duplicate. Result: the
         sidebar renders identically on every page from this single source,
         WITHOUT editing or deleting any per-page CSS. Per-page .dsb-* blocks
         become harmless dead overrides (lower specificity, ignored). */
      '#dsb.dsb-root{position:fixed;left:0;top:0;bottom:0;width:220px;background:var(--surf);border-right:1px solid var(--bord);display:flex;flex-direction:column;z-index:200;overflow-y:auto}' +
      '#dsb.dsb-root .dsb-logo{display:flex;align-items:center;gap:10px;padding:20px 16px 14px;border-bottom:1px solid var(--bord)}' +
      '#dsb.dsb-root .dsb-brand{font-family:var(--font-h),system-ui,sans-serif;font-size:15px;font-weight:800;color:var(--acc)}' +
      '#dsb.dsb-root .dsb-nav{flex:1;padding:10px 8px;display:flex;flex-direction:column;gap:2px;overflow-y:auto}' +
      '#dsb.dsb-root .dsb-item{display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:10px;cursor:pointer;text-decoration:none;color:var(--t2);font-size:13px;font-weight:600;transition:.15s ease;white-space:nowrap;border:none;background:none;width:100%}' +
      '#dsb.dsb-root .dsb-item:hover{background:var(--surf2);color:var(--text)}' +
      '#dsb.dsb-root .dsb-item.active{background:rgba(245,166,35,.12);color:var(--acc)}' +
      '#dsb.dsb-root .dsb-item.fab-sb{background:linear-gradient(135deg,#F5A623,#FF8A00);color:#fff;margin:4px 0 8px;font-weight:700}' +
      '#dsb.dsb-root .dsb-item.fab-sb:hover{opacity:.88}' +
      '#dsb.dsb-root .dsb-ic{font-size:17px;width:22px;text-align:center;flex-shrink:0}' +
      '#dsb.dsb-root .dsb-sep{height:1px;background:var(--bord);margin:6px 12px}' +
      '#dsb.dsb-root .dsb-footer{padding:8px;border-top:1px solid var(--bord)}' +
      '#dsb.dsb-root .dsb-ver{font-size:10px;color:var(--t3);text-align:center;padding:8px 0 4px}' +
      '@media(max-width:1023px){#dsb.dsb-root{display:none!important}}' +
      /* 022E: Collapsible "More" group in desktop sidebar */
      '#dsb.dsb-root .dsb-more-group{display:flex;flex-direction:column;margin-top:4px}' +
      '#dsb.dsb-root .dsb-more-toggle{display:flex;align-items:center;gap:12px;width:100%;padding:10px 12px;background:transparent;border:none;border-radius:10px;cursor:pointer;color:inherit;font:inherit;text-align:left;transition:background .15s}' +
      '#dsb.dsb-root .dsb-more-toggle:hover{background:rgba(255,255,255,.04)}' +
      '[data-theme="light"] #dsb.dsb-root .dsb-more-toggle:hover{background:rgba(0,0,0,.04)}' +
      '#dsb.dsb-root .dsb-more-toggle .dsb-ic{font-size:18px;width:24px;text-align:center}' +
      '#dsb.dsb-root .dsb-more-label{flex:1;font-weight:600;font-size:14px}' +
      '#dsb.dsb-root .dsb-more-arr{font-size:18px;color:#8A8AA8;transition:transform .2s;line-height:1}' +
      '#dsb.dsb-root .dsb-more-group.open .dsb-more-arr{transform:rotate(90deg)}' +
      '#dsb.dsb-root .dsb-more-list{display:none;flex-direction:column;padding-left:14px;margin-top:2px;border-left:1.5px solid rgba(255,255,255,.06)}' +
      '[data-theme="light"] #dsb.dsb-root .dsb-more-list{border-left-color:rgba(0,0,0,.08)}' +
      '#dsb.dsb-root .dsb-more-group.open .dsb-more-list{display:flex}';
    (document.head || document.documentElement).appendChild(style);
  }

  // ── Public API ─────────────────────────────────────────────────
  // BATCH HOTFIX (sidebar legacy-signature compat):
// Restaurant/hotel pages (tables/kitchen/running-order/menu/walk-in/folio/
// rooms/bookings/housekeeping/restaurant-reports) call the OLD signature
// SBPSidebar.render('pagename'). UI-3 rewrote render() to require an
// options object {layout,currentPage,container}; the string form silently
// no-ops (no #dsb created, .bnav left empty) -> sidebar absent on the
// entire restaurant vertical. This wrapper accepts the legacy string and
// expands it to a full desktop + mobile render with auto containers.
// Object-form callers are passed through unchanged.
async function render(opts) {
    // Legacy string form: SBPSidebar.render('tables')
    if (typeof opts === 'string') {
      var page = opts;
      try {
        if (window.innerWidth >= 1024) {
          return await _renderOne({ layout: 'desktop', currentPage: page });
        }
        var hasBnav   = document.querySelector('.bnav');
        var hasDrawer = document.querySelector('.bnav-drawer');
        if (hasBnav)   await _renderOne({ layout: 'mobile-bottom', currentPage: page, container: '.bnav' });
        if (hasDrawer) await _renderOne({ layout: 'mobile-drawer', currentPage: page, container: '.bnav-drawer' });
        if (!hasBnav && !hasDrawer) {
          // No mobile containers on this page -> fall back to desktop mount
          return await _renderOne({ layout: 'desktop', currentPage: page });
        }
        return;
      } catch (e) { console.warn('[SBPSidebar] legacy render failed:', e); return; }
    }
    // Object form: unchanged behaviour.
    return await _renderOne(opts);
}

async function _renderOne(opts) {
    opts = opts || {};
    const layout = opts.layout || 'desktop';

    // BATCH 1B-G-Hotfix: ensure critical CSS rules exist on every page
    _injectStyles();

    // BATCH 1B-C: Normalize currentPage. Accepts 'dashboard', 'dashboard.html', or auto-derives.
    let currentPage = opts.currentPage || '';
    if (currentPage.endsWith('.html')) currentPage = currentPage.slice(0, -5);
    if (!currentPage) {
      const path = (window.location.pathname.split('/').pop() || '').replace('.html', '');
      currentPage = path || 'dashboard';
    }
    // Map filename-style codes that differ from item.code (billing.html → 'billing' which IS the code, so direct match works)
    // 'index' has no sidebar item, defaults to 'dashboard'
    if (currentPage === 'index') currentPage = 'dashboard';

    // BATCH 1B-C: Desktop layout — only mount on screens >= 1024px (matches existing #dsb media rule)
    if (layout === 'desktop' && window.innerWidth < 1024) {
      return; // mobile/tablet: bnav handles nav, desktop sidebar is hidden anyway
    }

    // BATCH 1B-C: Container resolution
    // - Explicit opts.container: use it
    // - Else if layout='desktop': auto-mount <div id="dsb"> on body (or reuse existing)
    // - Else: error (caller must provide container for non-desktop layouts)
    let containers;
    if (opts.container) {
      containers = (typeof opts.container === 'string')
        ? Array.from(document.querySelectorAll(opts.container))
        : (Array.isArray(opts.container) ? opts.container : [opts.container]);
    } else if (layout === 'desktop') {
      let dsb = document.getElementById('dsb');
      if (!dsb) {
        dsb = document.createElement('div');
        dsb.id = 'dsb';
        document.body.prepend(dsb);
      }
      // BATCH UI-3: tag the canonical container so engine CSS (scoped under
      // #dsb.dsb-root) outranks any per-page duplicate .dsb-* rule.
      dsb.classList.add('dsb-root');
      containers = [dsb];
    } else {
      console.warn('[SBPSidebar] No container specified for layout=' + layout);
      return;
    }

    // 1. Quick first paint with cached or default
    const shop = _shop();
    const cached = _loadCache(shop.id) || DEFAULT_FALLBACK;
    let items = _buildItems(cached, currentPage);
    containers.filter(Boolean).forEach(c => { c.innerHTML = _renderSidebar(items, layout); });
    _wireDesktopLogout(layout);
    _wireScrollPersist(layout, containers);  // BATCH 013 HOTFIX: preserve scroll position
    if (layout === 'mobile-drawer') _wireDrawerLogout();

    // 2. Async refresh from RPC if Supabase + shop_id available
    let sbClient = window._sb || window.SBP_SUPABASE;
    if (!sbClient && window.supabase && typeof window.supabase.createClient === 'function') {
      try {
        const SB_URL = window.SB_URL || (window.SBP_CONFIG && window.SBP_CONFIG.SB_URL);
        const SB_KEY = window.SB_KEY || (window.SBP_CONFIG && window.SBP_CONFIG.SB_KEY);
        if (SB_URL && SB_KEY) sbClient = window.supabase.createClient(SB_URL, SB_KEY);
      } catch (_) {}
    }

    if (sbClient && shop.id) {
      const fresh = await _fetchModules(sbClient, shop.id);
      const newItems = _buildItems(fresh, currentPage);
      const oldKey = items.map(x => x.code + (x.status || '')).join('|');
      const newKey = newItems.map(x => x.code + (x.status || '')).join('|');
      if (oldKey !== newKey) {
        containers.filter(Boolean).forEach(c => { c.innerHTML = _renderSidebar(newItems, layout); });
        _wireDesktopLogout(layout);
        _wireScrollPersist(layout, containers);  // re-wire after innerHTML replacement
        if (layout === 'mobile-drawer') _wireDrawerLogout();
      }
    }
  }

  // ── BATCH 013 HOTFIX (6 May 2026): Preserve sidebar scroll position ──
  // Problem: every page navigation re-renders the sidebar via innerHTML, which
  // wipes the .dsb-nav scrollTop back to 0. For shops with many menu items
  // (16+ vertical modules), users have to re-scroll to find their place every
  // time they click around — feels broken vs. how desktop apps behave.
  // Fix: persist .dsb-nav scrollTop to sessionStorage; restore on each render.
  // sessionStorage (not localStorage) — it should reset between browser sessions.
  //
  // ── Hotel polish (12 May 2026): "few stable, few moving upward" fix ──
  // The BATCH 013 fix preserves scroll, but it doesn't help in this case:
  // User is on Page A (saved scroll = 0 because they didn't scroll), clicks
  // "More ⚙️" which expands items at the BOTTOM of the sidebar, then clicks
  // one of those More items. New page loads with scrollTop = 0 restored, but
  // the active More item is below the visible area — feels like the sidebar
  // jumped upward away from where they clicked.
  // Fix: after restoring saved scroll, check if the active item is in view.
  // If not (which happens when the active item is in the More group on a tall
  // sidebar), scroll it into view explicitly. Uses 'block:nearest' so already-
  // visible items don't trigger unnecessary scrolling.
  function _wireScrollPersist(layout, containers) {
    if (layout !== 'desktop') return;  // only the desktop side rail scrolls; bnav is fixed; drawer reopens fresh
    const KEY = 'sbp_dsb_scroll';
    containers.forEach(container => {
      if (!container) return;
      const navEl = container.querySelector('.dsb-nav');
      if (!navEl) return;
      // Restore (synchronously, before paint)
      const saved = parseInt(sessionStorage.getItem(KEY) || '0', 10);
      if (saved > 0) navEl.scrollTop = saved;
      // Hotel polish: ensure active item is visible after restore.
      // requestAnimationFrame defers the check until after the browser has
      // computed layout, so getBoundingClientRect() returns final positions.
      requestAnimationFrame(() => {
        try {
          const active = navEl.querySelector('.dsb-item.active');
          if (!active) return;
          const itemRect = active.getBoundingClientRect();
          const navRect  = navEl.getBoundingClientRect();
          // Visible if both top and bottom are within nav viewport
          const isVisible = itemRect.top >= navRect.top && itemRect.bottom <= navRect.bottom;
          if (!isVisible) {
            // 'nearest' + 'auto' = instant scroll to the closest edge that brings
            // the item fully into view; no animation, no surprise
            active.scrollIntoView({ block: 'nearest', behavior: 'auto' });
          }
        } catch (_) {}
      });
      // Save on scroll (debounced so we don't thrash sessionStorage)
      let scrollTimer = null;
      navEl.addEventListener('scroll', () => {
        if (scrollTimer) clearTimeout(scrollTimer);
        scrollTimer = setTimeout(() => {
          try { sessionStorage.setItem(KEY, String(navEl.scrollTop)); } catch(e) {}
        }, 80);
      }, { passive: true });
    });
  }

  // SECURITY (16-May): clear account-scoped storage on logout so a
  // shared device doesn't leave the prior account's data sitting in
  // localStorage. Mirrors sbpPurgeAccountData() in index.html.
  function _purgeAccountStorage() {
    try {
      var KEEP = {
        'sbp_theme':1,'sbp_lang':1,'sbp_font_size':1,'sbp_digit_style':1,
        'sbp_device_tag':1,'sbp_session_timeout':1,'sbp_sidebar_more_open':1,
        'sbp_menu_view':1,'sbp_printer_enabled':1,'sbp_printer_type':1,
        'sbp_default_share':1,'sbp_hide_gst':1,'sbp_pin_migration_dismissed_at':1
      };
      var doomed = [];
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (k && k.indexOf('sbp_') === 0 && !KEEP[k]) doomed.push(k);
      }
      doomed.forEach(function(k){ try { localStorage.removeItem(k); } catch(e){} });
    } catch (e) { /* non-fatal */ }
  }

  // BATCH 1B-C: Wire the logout button after each render (innerHTML wipes prior listeners)
  function _wireDesktopLogout(layout) {
    if (layout !== 'desktop') return;
    const btn = document.getElementById('dsb-logout');
    if (!btn) return;
    btn.onclick = function() {
      const sbClient = window._sb;
      _purgeAccountStorage();
      if (sbClient && sbClient.auth && typeof sbClient.auth.signOut === 'function') {
        sbClient.auth.signOut().then(function() { window.location.href = 'index.html'; });
      } else {
        window.location.href = 'index.html';
      }
    };
  }

  // BATCH 1B-F: drawer logout wiring (called after drawer renders since innerHTML wipes listeners)
  function _wireDrawerLogout() {
    const btn = document.getElementById('drawer-logout');
    if (!btn) return;
    btn.onclick = function() {
      _closeDrawer();
      const sbClient = window._sb;
      _purgeAccountStorage();
      if (sbClient && sbClient.auth && typeof sbClient.auth.signOut === 'function') {
        sbClient.auth.signOut().then(function() { window.location.href = 'index.html'; });
      } else {
        window.location.href = 'index.html';
      }
    };
  }

  // BATCH 1B-F: Open the mobile drawer + show overlay
  function _openDrawer() {
    const drawer = document.querySelector('.bnav-drawer');
    const overlay = document.querySelector('.bnav-overlay');
    if (drawer) drawer.classList.add('open');
    if (overlay) overlay.classList.add('open');
    // Lock body scroll
    document.body.style.overflow = 'hidden';
  }

  // BATCH 1B-F: Close the mobile drawer + hide overlay
  function _closeDrawer() {
    const drawer = document.querySelector('.bnav-drawer');
    const overlay = document.querySelector('.bnav-overlay');
    if (drawer) drawer.classList.remove('open');
    if (overlay) overlay.classList.remove('open');
    document.body.style.overflow = '';
  }

  // 022E: toggle the collapsible "More" group in the desktop sidebar.
  // Persists state in localStorage so it stays open/closed across page nav.
  function _toggleMore() {
    const grp = document.getElementById('dsb-more-group');
    if (!grp) return;
    const isOpen = grp.classList.toggle('open');
    const btn = grp.querySelector('.dsb-more-toggle');
    if (btn) btn.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
    try { localStorage.setItem('sbp_sidebar_more_open', isOpen ? '1' : '0'); } catch (e) {}
  }

  return {
    render,
    _showSoon,
    _openDrawer,
    _closeDrawer,
    _wireDrawerLogout,
    _toggleMore,
    UNIVERSAL_CORE,
    MODULE_CATALOG,
    // ── Vertical helpers (Batch 12-May-26 #3) ───────────────────────
    // Used by dashboard.html to choose Quick Action button sets per
    // vertical, and by any future page that needs to adapt UI based
    // on shop type. Single source of truth lives in MACRO_BY_SHOP_TYPE
    // above; do not maintain parallel taxonomies elsewhere.
    //
    // Usage:
    //   const macro = SBPSidebar.macroFor();           // current shop
    //   const macro = SBPSidebar.macroFor('day_room'); // explicit
    //   if (SBPSidebar.isHospitality()) {...}          // boolean convenience
    macroFor: function(shopType) {
      const t = (shopType !== undefined) ? shopType : ((_shop() || {}).shop_type || '');
      return _macroForShop(t);
    },
    isHospitality: function(shopType) {
      const t = (shopType !== undefined) ? shopType : ((_shop() || {}).shop_type || '');
      return _isHospitalityShop(t);
    },
    MACRO_BY_SHOP_TYPE,
  };
})();
