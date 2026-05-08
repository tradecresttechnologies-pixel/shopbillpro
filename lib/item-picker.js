/* ════════════════════════════════════════════════════════════════════
 * lib/item-picker.js
 * Batch 019 — Universal Item Picker (8 May 2026)
 *
 * One picker for products + services + rooms, automatically scoped to
 * what the current shop_type allows (per server-side mapping in
 * sbp_picker_kinds_for_shop_type).
 *
 * Public API:
 *   SBPItemPicker.open({
 *     shopId:     string,                 // required
 *     shopType:   string,                 // optional — server auto-detects if omitted
 *     allowKinds: ['product','service','room'],   // optional override
 *     query:      'initial search text',  // optional
 *     onSelect:   function(item) { ... }, // required — called with selected item
 *     onClose:    function() { ... }      // optional — called on dismiss
 *   })
 *
 *   The selected item passed to onSelect has shape:
 *     {
 *       kind:        'product' | 'service' | 'room',
 *       id:          uuid,
 *       name:        string,
 *       code:        string | null,
 *       category:    string | null,
 *       rate:        number,
 *       gst_rate:    number,
 *       unit:        'piece' | 'kg' | 'session' | 'night' | ...
 *       stock_qty:   number | null,    // products only
 *       emoji:       string,
 *       image_url:   string | null,
 *       // raw fields available on the item too
 *     }
 *
 * Caches results in sessionStorage for 60 seconds so re-opens are fast.
 * ════════════════════════════════════════════════════════════════════ */

(function () {
  'use strict';

  const CACHE_PREFIX = 'sbp_picker_cache_';
  const CACHE_MS     = 60 * 1000;          // 60 seconds

  // Get / lazy-create Supabase client
  function getSb() {
    if (window._sb)          return window._sb;
    if (window.sb)           return window.sb;
    if (window.supabase && window.supabase.createClient) {
      const SB_URL = 'https://jfqeirfrkjdkqqixivru.supabase.co';
      const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpmcWVpcmZya2pka3FxaXhpdnJ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzQ4MzgsImV4cCI6MjA4OTk1MDgzOH0.akd4E0nil8ypLR4WOykkeYIL8g4uuNU6XdSVh_Y1utk';
      window._sbPickerClient = window._sbPickerClient ||
        window.supabase.createClient(SB_URL, SB_KEY);
      return window._sbPickerClient;
    }
    return null;
  }

  function escHtml(s) {
    if (s == null) return '';
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function cacheKey(shopId, query, kinds) {
    return CACHE_PREFIX + shopId + ':' + (query || '') + ':' + (kinds || []).join(',');
  }
  function readCache(key) {
    try {
      const raw = sessionStorage.getItem(key);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (!parsed.t || (Date.now() - parsed.t) > CACHE_MS) return null;
      return parsed.data;
    } catch (e) { return null; }
  }
  function writeCache(key, data) {
    try { sessionStorage.setItem(key, JSON.stringify({ t: Date.now(), data: data })); } catch (e) {}
  }

  // ──────────────────────────────────────────────
  // Search call
  // ──────────────────────────────────────────────
  async function searchItems(shopId, query, kinds) {
    const k = cacheKey(shopId, query, kinds);
    const cached = readCache(k);
    if (cached) return cached;

    const sb = getSb();
    if (!sb) throw new Error('Supabase client not available');

    const { data, error } = await sb.rpc('sbp_picker_search', {
      p_shop_id: shopId,
      p_query:   query || null,
      p_kinds:   kinds && kinds.length ? kinds : null,
      p_limit:   100
    });
    if (error) throw new Error(error.message);
    if (!data || !data.ok) throw new Error((data && data.error) || 'search_failed');

    writeCache(k, data);
    return data;
  }

  // ──────────────────────────────────────────────
  // Modal HTML
  // ──────────────────────────────────────────────
  const STYLE_ID = 'sbp-item-picker-styles';
  function ensureStyles() {
    if (document.getElementById(STYLE_ID)) return;
    const s = document.createElement('style');
    s.id = STYLE_ID;
    s.textContent = `
      .sbp-pkr-overlay{position:fixed;inset:0;background:rgba(0,0,0,.65);backdrop-filter:blur(4px);z-index:99999;display:flex;align-items:flex-end;justify-content:center;animation:sbpPkrFadeIn .15s ease-out}
      @media(min-width:720px){.sbp-pkr-overlay{align-items:center}}
      @keyframes sbpPkrFadeIn{from{opacity:0}to{opacity:1}}
      .sbp-pkr-sheet{background:var(--surf,#181828);color:var(--text,#F0EFF8);width:100%;max-width:680px;max-height:88vh;border-radius:18px 18px 0 0;display:flex;flex-direction:column;box-shadow:0 -8px 40px rgba(0,0,0,.4);overflow:hidden;font-family:'Outfit',sans-serif}
      @media(min-width:720px){.sbp-pkr-sheet{border-radius:18px;max-height:80vh}}
      .sbp-pkr-head{padding:18px 18px 0;border-bottom:1px solid rgba(124,58,237,.18)}
      .sbp-pkr-head-row{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}
      .sbp-pkr-title{font-size:18px;font-weight:800;margin:0}
      .sbp-pkr-close{background:rgba(124,58,237,.12);border:none;color:var(--text,#F0EFF8);width:32px;height:32px;border-radius:50%;font-size:18px;cursor:pointer}
      .sbp-pkr-close:hover{background:rgba(124,58,237,.25)}
      .sbp-pkr-search{position:relative;margin-bottom:12px}
      .sbp-pkr-search input{width:100%;padding:11px 14px 11px 38px;background:var(--surf2,#0e0e1a);border:1.5px solid rgba(124,58,237,.3);border-radius:10px;color:var(--text,#F0EFF8);font-family:inherit;font-size:14px;outline:none}
      .sbp-pkr-search input:focus{border-color:#F5A623}
      .sbp-pkr-search .sbp-pkr-icn{position:absolute;left:12px;top:50%;transform:translateY(-50%);font-size:14px;opacity:.6}
      .sbp-pkr-tabs{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:14px}
      .sbp-pkr-tab{padding:7px 14px;border-radius:18px;background:rgba(124,58,237,.1);border:1px solid rgba(124,58,237,.2);color:var(--text,#F0EFF8);font-size:13px;font-weight:600;cursor:pointer;font-family:inherit}
      .sbp-pkr-tab:hover{background:rgba(124,58,237,.18)}
      .sbp-pkr-tab.active{background:linear-gradient(135deg,#F5A623,#FF8A00);color:#0A0E1A;border-color:transparent}
      .sbp-pkr-body{flex:1;overflow-y:auto;padding:14px 18px 18px}
      .sbp-pkr-empty{text-align:center;padding:48px 18px;color:rgba(255,255,255,.5);font-size:13px}
      .sbp-pkr-loading{text-align:center;padding:32px;color:rgba(255,255,255,.5);font-size:13px}
      .sbp-pkr-err{background:rgba(239,68,68,.08);border:1px solid rgba(239,68,68,.3);color:#FCA5A5;padding:14px;border-radius:8px;font-size:13px;margin-bottom:14px}
      .sbp-pkr-grid{display:grid;grid-template-columns:1fr;gap:8px}
      @media(min-width:520px){.sbp-pkr-grid{grid-template-columns:1fr 1fr}}
      .sbp-pkr-card{background:var(--surf2,#0e0e1a);border:1.5px solid rgba(124,58,237,.18);border-radius:12px;padding:12px 14px;cursor:pointer;display:flex;align-items:flex-start;gap:12px;transition:all .15s;text-align:left;font-family:inherit}
      .sbp-pkr-card:hover{border-color:#F5A623;background:rgba(245,166,35,.04);transform:translateY(-1px)}
      .sbp-pkr-card-emoji{font-size:28px;line-height:1;flex-shrink:0;width:38px;text-align:center}
      .sbp-pkr-card-body{flex:1;min-width:0}
      .sbp-pkr-card-name{font-weight:700;font-size:14px;margin-bottom:3px;line-height:1.25;color:var(--text,#F0EFF8);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .sbp-pkr-card-meta{font-size:11px;color:rgba(255,255,255,.55);margin-bottom:6px;display:flex;gap:8px;flex-wrap:wrap}
      .sbp-pkr-card-tag{display:inline-block;padding:1px 7px;background:rgba(124,58,237,.15);border-radius:8px;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.5px}
      .sbp-pkr-card-tag.kind-product{background:rgba(99,102,241,.18);color:#A5B4FC}
      .sbp-pkr-card-tag.kind-service{background:rgba(236,72,153,.18);color:#F9A8D4}
      .sbp-pkr-card-tag.kind-room{background:rgba(16,185,129,.18);color:#6EE7B7}
      .sbp-pkr-card-tag.stock-low{background:rgba(245,158,11,.18);color:#FBBF24}
      .sbp-pkr-card-tag.stock-out{background:rgba(239,68,68,.18);color:#FCA5A5}
      .sbp-pkr-card-rate{font-weight:800;font-size:15px;color:#F5A623;flex-shrink:0;text-align:right;align-self:center;font-family:inherit}
      .sbp-pkr-card-unit{font-size:10px;color:rgba(255,255,255,.5);font-weight:500}
      .sbp-pkr-foot{padding:10px 18px;border-top:1px solid rgba(124,58,237,.18);font-size:11px;color:rgba(255,255,255,.45);text-align:center}
    `;
    document.head.appendChild(s);
  }

  // ──────────────────────────────────────────────
  // Main entry
  // ──────────────────────────────────────────────
  let _activeOverlay = null;

  function close() {
    if (_activeOverlay) {
      _activeOverlay.remove();
      _activeOverlay = null;
    }
  }

  function open(opts) {
    opts = opts || {};
    if (!opts.shopId) {
      console.error('[SBPItemPicker] shopId is required');
      return;
    }
    if (typeof opts.onSelect !== 'function') {
      console.error('[SBPItemPicker] onSelect callback is required');
      return;
    }

    ensureStyles();
    close();        // remove any previous instance

    const overlay = document.createElement('div');
    overlay.className = 'sbp-pkr-overlay';
    overlay.innerHTML = `
      <div class="sbp-pkr-sheet">
        <div class="sbp-pkr-head">
          <div class="sbp-pkr-head-row">
            <h3 class="sbp-pkr-title">📚 Browse Catalogue</h3>
            <button class="sbp-pkr-close" aria-label="Close">×</button>
          </div>
          <div class="sbp-pkr-search">
            <span class="sbp-pkr-icn">🔍</span>
            <input type="text" placeholder="Search items, codes, categories…" />
          </div>
          <div class="sbp-pkr-tabs"></div>
        </div>
        <div class="sbp-pkr-body">
          <div class="sbp-pkr-loading">Loading…</div>
        </div>
        <div class="sbp-pkr-foot">Tap an item to add it to the bill</div>
      </div>
    `;
    document.body.appendChild(overlay);
    _activeOverlay = overlay;

    const sheet     = overlay.querySelector('.sbp-pkr-sheet');
    const closeBtn  = overlay.querySelector('.sbp-pkr-close');
    const inputEl   = overlay.querySelector('.sbp-pkr-search input');
    const tabsWrap  = overlay.querySelector('.sbp-pkr-tabs');
    const bodyEl    = overlay.querySelector('.sbp-pkr-body');

    // State
    let allItems   = [];
    let kinds      = [];      // allowed kinds
    let activeKind = 'all';   // active filter tab

    // Events
    closeBtn.addEventListener('click', () => {
      close();
      if (typeof opts.onClose === 'function') opts.onClose();
    });
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) {
        close();
        if (typeof opts.onClose === 'function') opts.onClose();
      }
    });
    sheet.addEventListener('click', (e) => e.stopPropagation());

    let _searchTimer = null;
    inputEl.addEventListener('input', () => {
      clearTimeout(_searchTimer);
      _searchTimer = setTimeout(load, 250);
    });

    if (opts.query) inputEl.value = opts.query;

    // Initial load
    function renderTabs() {
      const labels = { all: '✨ All', product: '📦 Products', service: '✂️ Services', room: '🛏️ Rooms' };
      let html = '';
      // Show "All" only when more than 1 kind allowed
      if (kinds.length > 1) {
        html += `<button class="sbp-pkr-tab ${activeKind === 'all' ? 'active' : ''}" data-kind="all">${labels.all}</button>`;
      }
      kinds.forEach(k => {
        html += `<button class="sbp-pkr-tab ${activeKind === k ? 'active' : ''}" data-kind="${k}">${labels[k] || k}</button>`;
      });
      tabsWrap.innerHTML = html;
      tabsWrap.querySelectorAll('.sbp-pkr-tab').forEach(btn => {
        btn.addEventListener('click', () => {
          activeKind = btn.dataset.kind;
          renderTabs();
          renderItems();
        });
      });
    }

    function renderItems() {
      const filtered = activeKind === 'all'
        ? allItems
        : allItems.filter(it => it.kind === activeKind);

      if (!filtered.length) {
        bodyEl.innerHTML = `<div class="sbp-pkr-empty">No items found.<br><br>Try a different search or add items in the relevant admin page.</div>`;
        return;
      }

      bodyEl.innerHTML = '<div class="sbp-pkr-grid">' + filtered.map((it, idx) => {
        const stockTag = it.kind === 'product'
          ? (it.stock_qty != null && it.stock_qty <= 0
              ? '<span class="sbp-pkr-card-tag stock-out">Out of stock</span>'
              : it.stock_qty != null && it.stock_qty <= 5
                ? `<span class="sbp-pkr-card-tag stock-low">Low: ${it.stock_qty}</span>`
                : it.stock_qty != null
                  ? `<span class="sbp-pkr-card-tag">Stock ${it.stock_qty}</span>`
                  : '')
          : '';
        const kindTag = `<span class="sbp-pkr-card-tag kind-${escHtml(it.kind)}">${escHtml(it.kind)}</span>`;
        const catTag  = it.category ? `<span class="sbp-pkr-card-tag" style="background:rgba(255,255,255,.05);color:rgba(255,255,255,.55)">${escHtml(it.category)}</span>` : '';
        const meta    = [kindTag, catTag, stockTag].filter(Boolean).join(' ');
        const rateStr = '₹' + (parseFloat(it.rate || 0)).toLocaleString('en-IN', { maximumFractionDigits: 2 });
        const unitStr = it.unit ? `<div class="sbp-pkr-card-unit">per ${escHtml(it.unit)}</div>` : '';

        return `
          <button class="sbp-pkr-card" data-idx="${idx}">
            <div class="sbp-pkr-card-emoji">${escHtml(it.emoji || '📦')}</div>
            <div class="sbp-pkr-card-body">
              <div class="sbp-pkr-card-name">${escHtml(it.name || 'Untitled')}</div>
              <div class="sbp-pkr-card-meta">${meta}</div>
            </div>
            <div>
              <div class="sbp-pkr-card-rate">${rateStr}</div>
              ${unitStr}
            </div>
          </button>
        `;
      }).join('') + '</div>';

      bodyEl.querySelectorAll('.sbp-pkr-card').forEach(btn => {
        btn.addEventListener('click', () => {
          const it = filtered[parseInt(btn.dataset.idx, 10)];
          if (it) {
            try { opts.onSelect(it); } catch (e) { console.error('onSelect error:', e); }
            close();
          }
        });
      });
    }

    async function load() {
      bodyEl.innerHTML = '<div class="sbp-pkr-loading">Loading…</div>';
      try {
        const data = await searchItems(opts.shopId, inputEl.value.trim(), opts.allowKinds);
        kinds    = data.kinds || ['product'];
        allItems = data.items || [];
        if (activeKind !== 'all' && !kinds.includes(activeKind)) {
          activeKind = kinds.length > 1 ? 'all' : kinds[0];
        }
        renderTabs();
        renderItems();
      } catch (e) {
        bodyEl.innerHTML = `<div class="sbp-pkr-err">⚠ Failed to load: ${escHtml(e.message)}</div>`;
        console.error('[SBPItemPicker] load failed:', e);
      }
    }

    setTimeout(() => { try { inputEl.focus(); } catch(e){} }, 100);
    load();
  }

  // Expose
  window.SBPItemPicker = {
    open:        open,
    close:       close,
    searchItems: searchItems,
    bustCache:   function(shopId) {
      try {
        for (let i = sessionStorage.length - 1; i >= 0; i--) {
          const k = sessionStorage.key(i);
          if (k && k.indexOf(CACHE_PREFIX + (shopId || '')) === 0) {
            sessionStorage.removeItem(k);
          }
        }
      } catch (e) {}
    }
  };
})();
