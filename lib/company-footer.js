/* ════════════════════════════════════════════════════════════════════
 * lib/company-footer.js
 * Batch 018 — CIN Switch (8 May 2026)
 *
 * Fetches TradeCrest's company details from the public RPC
 * `sbp_get_company_details_public()` and renders them into any
 * placeholder element on the page.
 *
 * Caches 24h in localStorage to avoid hammering the DB on every page
 * load. Cache busted by admin-company-details.html on save.
 *
 * Usage:
 *   1. Add <script src="lib/company-footer.js" defer></script> to <head>
 *   2. Add <div id="sbp-company-footer"></div> where the footer should render
 *
 * The lib auto-runs on DOMContentLoaded. Optional helpers:
 *   - SBPCompany.get()           → returns Promise<details>
 *   - SBPCompany.refresh()       → bypass cache, refetch
 *   - SBPCompany.fillTokens(el)  → replace {{cin}}, {{address}}, etc.
 *                                   inside the given DOM element
 *
 * Token replacement supports:
 *   {{legal_name}} {{brand_name}} {{cin}} {{gstin}}
 *   {{registered_address}} {{state}} {{pincode}}
 *   {{support_email}} {{support_phone}} {{privacy_email}}
 *   {{legal_email}} {{security_email}} {{date_of_incorp}}
 * ════════════════════════════════════════════════════════════════════ */

(function() {
  'use strict';

  const CACHE_KEY = 'sbp_company_cache';
  const CACHE_MS  = 24 * 60 * 60 * 1000;          // 24h

  // Fallback values (used if RPC fails before seed lands or offline)
  const FALLBACK = {
    legal_name:         'TradeCrest Technologies Private Limited',
    brand_name:         'ShopBill Pro',
    cin:                'U62099UP2026PTC247501',
    gstin:              null,
    date_of_incorp:     '2026-05-06',
    legal_form:         'Private Limited Company',
    registered_address: '529, Harsewakpur No 2, Harsewakpur, Jangle Dhushar, Sadar, Gorakhpur',
    state:              'Uttar Pradesh',
    country:            'India',
    pincode:            '273014',
    support_email:      'support@shopbillpro.in',
    support_phone:      '+91-7800766561',
    legal_email:        'legal@shopbillpro.in',
    privacy_email:      'privacy@shopbillpro.in',
    security_email:     'security@shopbillpro.in',
    general_email:      'hello@shopbillpro.in',
    primary_domain:     'shopbillpro.in',
    app_url:            'https://app.shopbillpro.in',
    marketing_url:      'https://shopbillpro.in'
  };

  // Use the global Supabase client if one is already on the page.
  // Otherwise, lazily create a minimal one (anon key — public RPC).
  function getSb() {
    if (window._sb) return window._sb;
    if (window.sb)  return window.sb;
    if (window.supabase && window.supabase.createClient) {
      const SB_URL = 'https://jfqeirfrkjdkqqixivru.supabase.co';
      const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpmcWVpcmZya2pka3FxaXhpdnJ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzQ4MzgsImV4cCI6MjA4OTk1MDgzOH0.akd4E0nil8ypLR4WOykkeYIL8g4uuNU6XdSVh_Y1utk';
      window._sbCompanyClient = window._sbCompanyClient ||
        window.supabase.createClient(SB_URL, SB_KEY);
      return window._sbCompanyClient;
    }
    return null;
  }

  function readCache() {
    try {
      const raw = localStorage.getItem(CACHE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (!parsed.t || (Date.now() - parsed.t) > CACHE_MS) return null;
      return parsed.data;
    } catch(e) { return null; }
  }

  function writeCache(data) {
    try {
      localStorage.setItem(CACHE_KEY, JSON.stringify({ t: Date.now(), data: data }));
    } catch(e) {}
  }

  async function fetchFresh() {
    const sb = getSb();
    if (!sb) return null;
    try {
      const { data, error } = await sb.rpc('sbp_get_company_details_public');
      if (error) return null;
      if (!data) return null;
      // Public RPC returns { ok, data: {...} } envelope
      if (data.ok && data.data) return data.data;
      // Even on `ok:false` we return the fallback data block if present
      if (data.data) return data.data;
      return null;
    } catch(e) { return null; }
  }

  /**
   * Returns the company details object, using the cache when fresh.
   * On any failure, returns FALLBACK so callers always get something safe.
   */
  async function get(forceRefresh) {
    if (!forceRefresh) {
      const cached = readCache();
      if (cached) return cached;
    }
    const fresh = await fetchFresh();
    if (fresh) {
      writeCache(fresh);
      return fresh;
    }
    // Last resort: known-good fallback
    return FALLBACK;
  }

  function escHtml(s) {
    if (s == null) return '';
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /**
   * Replace {{token}} placeholders inside the given element's HTML
   * with current company details. Safe-escapes values.
   */
  async function fillTokens(el) {
    if (!el) return;
    const data = await get();
    let html = el.innerHTML;
    Object.keys(data).forEach(function(k) {
      const re = new RegExp('\\{\\{\\s*' + k + '\\s*\\}\\}', 'g');
      html = html.replace(re, escHtml(data[k]));
    });
    el.innerHTML = html;
  }

  /**
   * Render the default ShopBill Pro footer (legal attribution strip)
   * into <div id="sbp-company-footer"></div>.
   */
  async function renderDefaultFooter() {
    const slot = document.getElementById('sbp-company-footer');
    if (!slot) return;
    const d = await get();
    const cinLine     = d.cin ? ('CIN: ' + escHtml(d.cin)) : '';
    const gstinLine   = d.gstin ? (' · GSTIN: ' + escHtml(d.gstin)) : '';
    const addressLine = d.registered_address
      ? escHtml(d.registered_address) + (d.pincode ? ' – ' + escHtml(d.pincode) : '') + (d.state ? ', ' + escHtml(d.state) : '')
      : '';

    slot.innerHTML = `
      <div style="text-align:center;font-size:11px;color:rgba(255,255,255,.45);padding:14px 12px 18px;line-height:1.7">
        <div style="font-weight:600">${escHtml(d.brand_name || 'ShopBill Pro')} · A product of ${escHtml(d.legal_name || 'TradeCrest Technologies Pvt. Ltd.')}</div>
        ${cinLine || gstinLine ? `<div style="opacity:.85">${cinLine}${gstinLine}</div>` : ''}
        ${addressLine ? `<div style="opacity:.7">Registered Office: ${addressLine}</div>` : ''}
        <div style="margin-top:6px;opacity:.7">
          <a href="https://shopbillpro.in/terms" style="color:inherit;text-decoration:none;margin:0 6px">Terms</a>·
          <a href="https://shopbillpro.in/privacy" style="color:inherit;text-decoration:none;margin:0 6px">Privacy</a>·
          <a href="https://shopbillpro.in/refund" style="color:inherit;text-decoration:none;margin:0 6px">Refund</a>·
          <a href="mailto:${escHtml(d.support_email || 'support@shopbillpro.in')}" style="color:inherit;text-decoration:none;margin:0 6px">Support</a>
        </div>
      </div>
    `;
  }

  // Public API
  window.SBPCompany = {
    get:           get,
    refresh:       function() { return get(true); },
    fillTokens:    fillTokens,
    renderFooter:  renderDefaultFooter,
    bustCache:     function() { try { localStorage.removeItem(CACHE_KEY); } catch(e){} },
    FALLBACK:      FALLBACK
  };

  // Auto-render footer + replace tokens in any element with [data-sbp-tokens]
  function autorun() {
    renderDefaultFooter();
    document.querySelectorAll('[data-sbp-tokens]').forEach(fillTokens);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', autorun);
  } else {
    autorun();
  }
})();
