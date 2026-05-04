/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Beta Countdown Banner v1.0
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Renders a top-of-app banner showing beta status:
     - 8+ days left:  calm gold tone, "Free Beta — all features till {date}"
     - 4–7 days left: warm orange, "Beta ending in X days. Choose your plan."
     - 1–3 days left: red urgency, "Only X days left. Don't lose your website!"
     - In grace (Day 61–67): purple, "Beta ended. Read-only mode for X more days."
     - Fully expired: handled by main app (downgrade trigger).

   Auto-runs on DOMContentLoaded. Pages just include the script — no
   wiring needed in Batch 1A. Batch 1B will fold the banner into pages.

   Reads beta status from:
     1. localStorage.sbp_shop (instant — for first paint)
     2. RPC get_shop_beta_status(shop.id) — authoritative, async refresh

   Banner is dismissable per-day (stored in localStorage).
══════════════════════════════════════════════════════════════════ */

(function(global) {
  'use strict';

  const DISMISS_KEY = 'sbp_beta_banner_dismissed';

  // ── Helpers ────────────────────────────────────────────────────
  function _shop() {
    try { return JSON.parse(localStorage.getItem('sbp_shop') || '{}'); }
    catch (_) { return {}; }
  }

  function _hi() { return (localStorage.getItem('sbp_lang') || 'en') === 'hi'; }

  function _todayKey() {
    const d = new Date();
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  function _isDismissed() {
    return localStorage.getItem(DISMISS_KEY) === _todayKey();
  }

  function _dismiss() {
    localStorage.setItem(DISMISS_KEY, _todayKey());
    const el = document.getElementById('sbp-beta-banner');
    if (el) el.style.display = 'none';
  }

  function _fmtDate(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
  }

  // ── Compute beta status from a shop record (offline-friendly) ──
  function _statusFromShop(shop) {
    if (!shop || !shop.is_beta_signup) return { is_beta_signup: false, status_label: 'not_beta' };
    const now = Date.now();
    const expires = shop.plan_expires_at ? new Date(shop.plan_expires_at).getTime() : null;
    const grace = shop.beta_grace_until ? new Date(shop.beta_grace_until).getTime() : null;

    if (!expires) return { is_beta_signup: true, status_label: 'active' };

    const daysLeft = Math.max(0, Math.ceil((expires - now) / 86400000));
    const isInGrace = expires < now && grace && now <= grace;
    const isFullyExpired = grace && now > grace;

    let status_label = 'active';
    if (isFullyExpired)         status_label = 'expired';
    else if (isInGrace)         status_label = 'grace';
    else if (daysLeft <= 1)     status_label = 'urgent';
    else if (daysLeft <= 3)     status_label = 'ending_soon';
    else if (daysLeft <= 7)     status_label = 'ending_week';
    return {
      is_beta_signup: true,
      plan: shop.plan,
      plan_expires_at: shop.plan_expires_at,
      beta_grace_until: shop.beta_grace_until,
      days_left: daysLeft,
      is_in_grace: isInGrace,
      is_fully_expired: isFullyExpired,
      status_label,
    };
  }

  // ── Async refresh from RPC ─────────────────────────────────────
  async function _refreshFromRPC(sbClient, shopId) {
    if (!sbClient || !shopId) return null;
    try {
      const { data, error } = await sbClient.rpc('get_shop_beta_status', { p_shop_id: shopId });
      if (error) { console.warn('[BetaBanner] RPC error:', error); return null; }
      return Array.isArray(data) ? data[0] : data;
    } catch (e) { console.warn('[BetaBanner] Fetch failed:', e); return null; }
  }

  // ── Render ─────────────────────────────────────────────────────
  function _bannerHTML(status) {
    const days = status.days_left;
    const dateStr = _fmtDate(status.plan_expires_at);
    const hi = _hi();
    let bg, border, color, icon, msg, cta;

    switch (status.status_label) {
      case 'grace':
        bg = 'linear-gradient(135deg, rgba(168,85,247,.15), rgba(124,58,237,.15))';
        border = 'rgba(168,85,247,.4)';
        color = '#A78BFA';
        icon = '⏳';
        msg = hi
          ? `बीटा खत्म हो गया है। आपका डेटा अभी भी सुरक्षित है — पढ़ने के लिए ${days || 0} दिन और।`
          : `Beta ended. Your data is safe — read-only for ${days || 0} more day(s). Choose a plan to continue editing.`;
        cta = hi ? '🚀 प्लान चुनें' : '🚀 Choose Plan';
        break;
      case 'urgent':
        bg = 'linear-gradient(135deg, rgba(239,68,68,.18), rgba(220,38,38,.15))';
        border = 'rgba(239,68,68,.4)';
        color = '#FCA5A5';
        icon = '⚠️';
        msg = hi
          ? `सिर्फ ${days || 0} दिन बाकी! अपनी वेबसाइट और सभी फीचर्स बचाने के लिए प्लान चुनें।`
          : `Only ${days || 0} day(s) left! Don't lose your website & features — pick a plan now.`;
        cta = hi ? '🚀 अभी अपग्रेड करें' : '🚀 Upgrade Now';
        break;
      case 'ending_soon':
        bg = 'linear-gradient(135deg, rgba(249,115,22,.15), rgba(234,88,12,.12))';
        border = 'rgba(249,115,22,.4)';
        color = '#FDBA74';
        icon = '⏰';
        msg = hi
          ? `आपका बीटा ${days} दिन में खत्म होगा (${dateStr})। अपना प्लान चुनें ताकि कुछ छूटे नहीं।`
          : `Your beta ends in ${days} days (${dateStr}). Choose your plan to stay continuous.`;
        cta = hi ? '🚀 प्लान चुनें' : '🚀 Choose Plan';
        break;
      case 'ending_week':
        bg = 'linear-gradient(135deg, rgba(245,166,35,.13), rgba(245,158,11,.1))';
        border = 'rgba(245,166,35,.35)';
        color = '#FCD34D';
        icon = '📅';
        msg = hi
          ? `आपका फ्री बीटा ${days} दिन में खत्म होगा (${dateStr})। प्लान देखें।`
          : `Your free beta ends in ${days} days (${dateStr}). Plan ahead.`;
        cta = hi ? '💎 प्लान देखें' : '💎 See Plans';
        break;
      case 'active':
      default:
        bg = 'linear-gradient(135deg, rgba(16,185,129,.1), rgba(5,150,105,.08))';
        border = 'rgba(16,185,129,.3)';
        color = '#6EE7B7';
        icon = '🎁';
        msg = hi
          ? `फ्री बीटा — ${dateStr} तक सभी फीचर्स। कोई कार्ड की ज़रूरत नहीं।`
          : `Free Beta — all features unlocked till ${dateStr}. No card needed.`;
        cta = '';
        break;
    }

    return `
      <div id="sbp-beta-banner" style="position:relative;background:${bg};border-bottom:1px solid ${border};color:${color};padding:10px 16px;font-family:Outfit,'Noto Sans',sans-serif;font-size:13px;font-weight:600;display:flex;align-items:center;gap:12px;flex-wrap:wrap;justify-content:center;min-height:42px;z-index:99">
        <span style="font-size:18px">${icon}</span>
        <span style="text-align:center">${msg}</span>
        ${cta ? `<button onclick="window.location.href='subscription.html'" style="background:rgba(245,166,35,.25);border:1px solid #F5A623;color:#F5A623;padding:5px 14px;border-radius:14px;font-size:12px;font-weight:700;cursor:pointer;font-family:inherit">${cta}</button>` : ''}
        <button onclick="SBPBetaBanner.dismiss()" aria-label="Dismiss" style="background:transparent;border:0;color:${color};opacity:.5;cursor:pointer;font-size:18px;padding:0 4px;line-height:1;font-family:inherit">×</button>
      </div>`;
  }

  function _ensureContainer() {
    let host = document.getElementById('sbpBetaBannerHost');
    if (host) return host;
    host = document.createElement('div');
    host.id = 'sbpBetaBannerHost';
    host.style.cssText = 'position:sticky;top:0;left:0;right:0;z-index:99';
    if (document.body.firstChild) {
      document.body.insertBefore(host, document.body.firstChild);
    } else {
      document.body.appendChild(host);
    }
    return host;
  }

  function _render(status) {
    if (!status || !status.is_beta_signup) return;
    if (status.status_label === 'expired') return;       // no banner once fully expired (downgrade UI handles it)
    if (_isDismissed() && status.status_label === 'active') return;  // calm-state banner is dismissable; urgent ones aren't

    const host = _ensureContainer();
    host.innerHTML = _bannerHTML(status);
  }

  // ── Public API & init ──────────────────────────────────────────
  global.SBPBetaBanner = {
    dismiss: _dismiss,
    refresh: render,        // alias
    render: render,
  };

  async function render() {
    const shop = _shop();
    if (!shop || !shop.is_beta_signup) return;

    // 1. Instant render from localStorage
    const local = _statusFromShop(shop);
    _render(local);

    // 2. Async refresh from RPC (authoritative)
    let sbClient = window._sb || window.SBP_SUPABASE;
    if (!sbClient && typeof window.supabase !== 'undefined' && window.supabase.createClient) {
      try {
        const SB_URL = window.SB_URL || (window.SBP_CONFIG && window.SBP_CONFIG.SB_URL);
        const SB_KEY = window.SB_KEY || (window.SBP_CONFIG && window.SBP_CONFIG.SB_KEY);
        if (SB_URL && SB_KEY) sbClient = window.supabase.createClient(SB_URL, SB_KEY);
      } catch (_) {}
    }

    if (sbClient && shop.id) {
      const remote = await _refreshFromRPC(sbClient, shop.id);
      if (remote) _render(remote);
    }
  }

  // Auto-run on load
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }
})(window);
