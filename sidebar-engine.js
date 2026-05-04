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

  // ── Universal core (always shown for every shop, every plan) ───
  const UNIVERSAL_CORE = [
    { code: 'dashboard', href: 'dashboard.html', icon: '🏠', label_en: 'Home',     label_hi: 'होम',       order: 0 },
    { code: 'bills',     href: 'bills.html',     icon: '🧾', label_en: 'Bills',    label_hi: 'बिल',       order: 10 },
    { code: 'billing',   href: 'billing.html',   icon: '＋', label_en: 'New Bill', label_hi: 'नया बिल',   order: 20, isFab: true },
    { code: 'customers', href: 'customers.html', icon: '👥', label_en: 'Customers',label_hi: 'ग्राहक',    order: 30 },
    { code: 'stock',     href: 'stock.html',     icon: '📦', label_en: 'Stock',    label_hi: 'स्टॉक',     order: 40 },
    { code: 'reports',   href: 'reports.html',   icon: '📊', label_en: 'Reports',  label_hi: 'रिपोर्ट',   order: 50 },
    // BATCH 1B-C: 'settings' is "More" on mobile bnav (5-slot overflow), "Settings" on desktop side rail
    { code: 'settings',  href: 'settings.html',  icon: '⚙️', label_en: 'Settings', label_hi: 'सेटिंग्स',  order: 200, mobileLabel_en: 'More', mobileLabel_hi: 'अधिक', mobileIcon: '☰' },
  ];

  // ── Module catalog: every vertical module mapped to icon/href/label
  const MODULE_CATALOG = {
    'website':         { href: 'settings.html#website', icon: '🌐', label_en: 'Website',          label_hi: 'वेबसाइट',         order: 60 },
    'marketing':       { href: 'marketing.html',        icon: '📢', label_en: 'Marketing',        label_hi: 'मार्केटिंग',       order: 70 },
    'wa_center':       { href: 'wa-center.html',        icon: '💬', label_en: 'WhatsApp',         label_hi: 'व्हाट्सऐप',        order: 80 },
    'recurring':       { href: 'recurring.html',        icon: '🔁', label_en: 'Recurring',        label_hi: 'रिकरिंग',         order: 90 },
    'cash_register':   { href: 'cash-register.html',    icon: '💵', label_en: 'Cash Register',    label_hi: 'कैश रजिस्टर',     order: 100 },
    'supplier':        { href: 'supplier.html',         icon: '🏭', label_en: 'Suppliers',        label_hi: 'सप्लायर',         order: 110 },
    'team':            { href: 'team.html',             icon: '👨‍👩‍👧', label_en: 'Team',           label_hi: 'टीम',             order: 120 },
    'subscription':    { href: 'subscription.html',     icon: '💎', label_en: 'Plans',            label_hi: 'प्लान',            order: 130 },
    // Universal add-ons (Batch 1B will create these pages)
    'services':        { href: 'services.html',         icon: '🛎️', label_en: 'Services',         label_hi: 'सेवाएं',           order: 140 },
    'appointments':    { href: 'appointments.html',     icon: '📅', label_en: 'Appointments',     label_hi: 'अपॉइंटमेंट',       order: 150 },
    // Vertical-specific (most ship later — soon = Coming Soon badge)
    'qr_menu':         { icon: '📱', label_en: 'QR Menu',         label_hi: 'QR मेनू',          order: 160 },
    'tables':          { icon: '🍽️', label_en: 'Tables',          label_hi: 'टेबल',             order: 170 },
    'online_orders':   { icon: '🛒', label_en: 'Online Orders',   label_hi: 'ऑनलाइन ऑर्डर',     order: 180 },
    'kitchen':         { icon: '👨‍🍳', label_en: 'Kitchen',        label_hi: 'किचन',             order: 190 },
    'stylists':        { icon: '✂️', label_en: 'Stylists',        label_hi: 'स्टाइलिस्ट',        order: 160 },
    'customer_history':{ icon: '📋', label_en: 'History',         label_hi: 'इतिहास',           order: 170 },
    'drug_db':         { icon: '💊', label_en: 'Drug Database',   label_hi: 'दवा डेटाबेस',       order: 160 },
    'expiry_alerts':   { icon: '⏰', label_en: 'Expiry',           label_hi: 'समाप्ति',           order: 170 },
    'prescriptions':   { icon: '📝', label_en: 'Prescriptions',   label_hi: 'पर्ची',            order: 180 },
    'imei_tracking':   { icon: '📲', label_en: 'IMEI',             label_hi: 'IMEI',             order: 160 },
    'warranty':        { icon: '🛡️', label_en: 'Warranty',        label_hi: 'वारंटी',           order: 170 },
    'repair_tickets':  { icon: '🔧', label_en: 'Repairs',          label_hi: 'मरम्मत',           order: 180 },
    'variants':        { icon: '🎨', label_en: 'Variants',        label_hi: 'वेरिएंट',          order: 160 },
    'alterations':     { icon: '📐', label_en: 'Alterations',     label_hi: 'अल्टरेशन',         order: 170 },
    'gold_rate':       { icon: '🏆', label_en: 'Gold Rate',       label_hi: 'सोने की दर',       order: 160 },
    'hallmarking':     { icon: '✨', label_en: 'Hallmarking',     label_hi: 'हॉलमार्किंग',      order: 170 },
    'vehicle_tracking':{ icon: '🚗', label_en: 'Vehicle',          label_hi: 'गाड़ी',           order: 160 },
    'service_history': { icon: '📋', label_en: 'Service History', label_hi: 'सर्विस इतिहास',    order: 170 },
    'patients':        { icon: '🏥', label_en: 'Patients',         label_hi: 'मरीज',             order: 160 },
    'batches':         { icon: '👨‍🎓', label_en: 'Batches',        label_hi: 'बैच',              order: 160 },
    'attendance':      { icon: '✅', label_en: 'Attendance',      label_hi: 'उपस्थिति',          order: 170 },
    'service_tickets': { icon: '🎫', label_en: 'Tickets',          label_hi: 'टिकट',             order: 160 },
    'salesman_app':    { icon: '🚶', label_en: 'Salesman',        label_hi: 'सेल्समैन',         order: 160 },
    'credit_limits':   { icon: '💳', label_en: 'Credit Limits',   label_hi: 'क्रेडिट लिमिट',    order: 170 },
    'wa_catalog':      { icon: '🛍️', label_en: 'WA Catalog',      label_hi: 'WA कैटलॉग',       order: 160 },
    'home_delivery':   { icon: '🛵', label_en: 'Delivery',        label_hi: 'डिलीवरी',         order: 170 },
    'loyalty':         { icon: '⭐', label_en: 'Loyalty',          label_hi: 'लॉयल्टी',         order: 180 },
    'courier':         { icon: '📮', label_en: 'Courier',         label_hi: 'कूरियर',           order: 180 },
    'members':         { icon: '🎟️', label_en: 'Members',         label_hi: 'सदस्य',           order: 160 },
    'listings':        { icon: '🏘️', label_en: 'Listings',        label_hi: 'लिस्टिंग',         order: 160 },
    'leads':           { icon: '📞', label_en: 'Leads',           label_hi: 'लीड्स',            order: 170 },
    'rooms':           { icon: '🛏️', label_en: 'Rooms',           label_hi: 'कमरे',             order: 160 },
    'bookings':        { icon: '📆', label_en: 'Bookings',        label_hi: 'बुकिंग',           order: 170 },
    'folio':           { icon: '📒', label_en: 'Folio',           label_hi: 'फोलियो',           order: 180 },
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

  // ── Build the full ordered list (universal core + vertical) ────
  function _buildItems(verticalModules, currentPage) {
    const items = [];
    UNIVERSAL_CORE.forEach(c => {
      items.push({ ...c, status: 'active', active: c.code === currentPage });
    });
    (verticalModules || []).forEach(m => {
      const cat = MODULE_CATALOG[m.module_code];
      if (!cat) return;
      items.push({
        code: m.module_code,
        href: m.status === 'active' ? (cat.href || '#') : '#',
        icon: cat.icon,
        label_en: cat.label_en,
        label_hi: cat.label_hi,
        order: cat.order || m.display_order,
        status: m.status,
        badge: m.badge || null,
        active: m.module_code === currentPage,
      });
    });
    items.sort((a, b) => (a.order || 999) - (b.order || 999));
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
    const mobLabelEn = item.mobileLabel_en || item.label_en;
    const mobLabelHi = item.mobileLabel_hi || item.label_hi || item.label_en;
    const mobIcon    = item.mobileIcon    || item.icon;
    return `<div class="${cls.join(' ')}" onclick="${onclick}" style="position:relative"><span class="ni-ic">${mobIcon}</span><span class="ni-lb"><span class="lang-en">${esc(mobLabelEn)}</span><span class="lang-hi">${esc(mobLabelHi)}</span></span>${badgeHtml}</div>`;
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
    // BATCH 1B-C: Desktop layout — full structure matching styles.css .dsb-* rules
    if (layout === 'desktop') {
      return '<div class="dsb-logo">' + _DSB_SVG + '<span class="dsb-brand">ShopBill Pro</span></div>' +
        '<div class="dsb-nav">' + items.map(i => _renderItem(i, layout)).join('') + '</div>' +
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

  // ── Public API ─────────────────────────────────────────────────
  async function render(opts) {
    opts = opts || {};
    const layout = opts.layout || 'desktop';

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
      }
    }
  }

  // BATCH 1B-C: Wire the logout button after each render (innerHTML wipes prior listeners)
  function _wireDesktopLogout(layout) {
    if (layout !== 'desktop') return;
    const btn = document.getElementById('dsb-logout');
    if (!btn) return;
    btn.onclick = function() {
      const sbClient = window._sb;
      if (sbClient && sbClient.auth && typeof sbClient.auth.signOut === 'function') {
        sbClient.auth.signOut().then(function() { window.location.href = 'index.html'; });
      } else {
        window.location.href = 'index.html';
      }
    };
  }

  return {
    render,
    _showSoon,
    UNIVERSAL_CORE,
    MODULE_CATALOG,
  };
})();
