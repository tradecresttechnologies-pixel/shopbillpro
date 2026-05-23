/* ════════════════════════════════════════════════════════════════════
   live-site.js  —  ShopBill Pro AI Website Runtime  (v5 / single-page polish)

   v5: + modal triggers (data-sbp-modal), motion (AOS+counters+parallax),
        progressive enhancement. All v4 behavior preserved.

   ShopBill Pro is fundamentally an admin panel; the website is a live
   window into admin data. Modals fetch from the same public RPCs as
   inline teasers, ensuring website stays in sync with admin data.

   Old v4 header below:
   ─────────────────────────────────────────────────────────────────────
   ShopBill Pro AI Website Runtime  (Batch v4 / Phase 5a v2)

   Loaded inside the iframe of an AI-generated public shop page (s.html).
   Scans for [data-sbp] placeholders the AI dropped into its HTML and
   hydrates them with live data from public Supabase RPCs.

   Components implemented:
     • services  — sbp_get_shop_services_public
     • contact   — buttons (WhatsApp / Call / Directions) from shop info
     • gallery   — image grid from shop content.gallery
     • info      — address + hours card
     • cta       — single big "open WhatsApp" button

   Globals required (injected by s.html before this script):
     window.__SBP_SLUG   — the shop slug
     window.__SBP_URL    — Supabase project URL
     window.__SBP_KEY    — Supabase anon key
   ════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  const SLUG = window.__SBP_SLUG || '';
  const URL  = window.__SBP_URL  || '';
  const KEY  = window.__SBP_KEY  || '';

  // In-memory fallback for the rate-limit token when sessionStorage is
  // blocked (sandboxed iframe, opaque origin). Persists for the page's
  // lifetime, which is enough for rate-limiting within one visit.
  let _sbpIpHashCache = null;

  if (!SLUG || !URL || !KEY || !window.supabase) {
    console.warn('[live-site] missing config or supabase SDK; skipping hydration');
    return;
  }

  // Disable Web Locks API + auth persistence. The iframe sandbox uses an
  // opaque origin (no allow-same-origin) for security, which blocks both
  // Web Locks and localStorage. Public shop pages don't need auth state, so
  // we explicitly disable both — this is the supported way per Supabase docs.
  const sb = window.supabase.createClient(URL, KEY, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
      // Provide a no-op lock so SDK skips Web Locks API
      lock: async (_name, _acquireTimeout, fn) => await fn(),
    },
  });

  /* ── helpers ──────────────────────────────────────────────────── */
  function esc(s){
    return (s == null ? '' : String(s))
      .replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }
  function fmtPrice(n){
    if (n == null || isNaN(n)) return '';
    return '₹' + Number(n).toLocaleString('en-IN');
  }
  function digits(s){ return String(s || '').replace(/\D/g,''); }
  function whatsAppLink(num, message){
    const n = digits(num);
    if (!n) return '#';
    const msg = message ? '?text=' + encodeURIComponent(message) : '';
    return 'https://wa.me/' + (n.length === 10 ? '91' + n : n) + msg;
  }
  function injectStyles(){
    if (document.getElementById('sbp-live-styles')) return;
    const css = `
      :root {
        --sbp-text:    #1A1A1A;
        --sbp-muted:   #6B7280;
        --sbp-bg-soft: #F8F9FA;
        --sbp-border:  #E5E7EB;
        --sbp-wa:      #25D366;
      }
      [data-sbp] { font-family: inherit; color: var(--sbp-text); }
      [data-sbp] .sbp-loading { padding:24px; text-align:center; color:var(--sbp-muted); font-size:14px }
      [data-sbp] .sbp-empty   { padding:24px; text-align:center; color:var(--sbp-muted); font-size:14px; background:var(--sbp-bg-soft); border-radius:12px }

      /* services */
      .sbp-svc-grid { display:grid; grid-template-columns:1fr; gap:16px; }
      @media(min-width:640px){ .sbp-svc-grid { grid-template-columns:repeat(2,1fr); } }
      @media(min-width:1024px){ .sbp-svc-grid { grid-template-columns:repeat(3,1fr); } }
      .sbp-svc-card { padding:20px; background:#fff; border:1px solid var(--sbp-border); border-radius:16px;
                      box-shadow:0 4px 16px rgba(0,0,0,.04); transition:all .2s ease; }
      .sbp-svc-card:hover { transform:translateY(-2px); box-shadow:0 8px 24px rgba(0,0,0,.08); }
      .sbp-svc-name { font-size:17px; font-weight:600; margin-bottom:6px; color:var(--sbp-text); }
      .sbp-svc-desc { font-size:13.5px; color:var(--sbp-muted); margin-bottom:14px; line-height:1.5; }
      .sbp-svc-meta { display:flex; justify-content:space-between; align-items:center; }
      .sbp-svc-price { font-size:18px; font-weight:700; color:var(--sbp-accent, #001F3F); }
      .sbp-svc-dur { font-size:12px; color:var(--sbp-muted); }

      /* contact */
      .sbp-contact-row { display:flex; flex-wrap:wrap; gap:12px; }
      .sbp-btn { display:inline-flex; align-items:center; gap:8px; padding:14px 22px; border-radius:10px;
                 font-size:15px; font-weight:600; text-decoration:none; border:none; cursor:pointer;
                 transition:all .2s ease; min-height:44px; }
      .sbp-btn-wa   { background:var(--sbp-wa); color:#fff; }
      .sbp-btn-call { background:var(--sbp-primary, #FF6B35); color:#fff; }
      .sbp-btn-dir  { background:#fff; color:var(--sbp-text); border:1.5px solid var(--sbp-border); }
      .sbp-btn:hover { transform:translateY(-1px); filter:brightness(1.05); }

      /* gallery */
      .sbp-gal-grid { display:grid; grid-template-columns:repeat(2,1fr); gap:8px; }
      @media(min-width:640px){ .sbp-gal-grid { grid-template-columns:repeat(3,1fr); gap:12px; } }
      @media(min-width:1024px){ .sbp-gal-grid { grid-template-columns:repeat(4,1fr); } }
      .sbp-gal-img { width:100%; aspect-ratio:1/1; object-fit:cover; border-radius:12px;
                     background:var(--sbp-bg-soft); transition:transform .2s ease; cursor:pointer; }
      .sbp-gal-img:hover { transform:scale(1.02); }

      /* info card */
      .sbp-info { background:#fff; border:1px solid var(--sbp-border); border-radius:16px; padding:24px;
                  box-shadow:0 4px 16px rgba(0,0,0,.04); }
      .sbp-info-row { display:flex; gap:14px; margin-bottom:14px; align-items:flex-start; font-size:14px; }
      .sbp-info-row:last-child { margin-bottom:0; }
      .sbp-info-ic { width:36px; height:36px; flex-shrink:0; border-radius:50%; background:var(--sbp-bg-soft);
                     display:flex; align-items:center; justify-content:center; font-size:16px; }
      .sbp-info-lbl { font-size:11.5px; text-transform:uppercase; letter-spacing:.5px; color:var(--sbp-muted);
                      font-weight:600; margin-bottom:2px; }
      .sbp-info-val { color:var(--sbp-text); line-height:1.45; }
      .sbp-info-val a { color:var(--sbp-accent, #001F3F); text-decoration:none; }

      /* cta */
      .sbp-cta-btn { display:inline-flex; align-items:center; justify-content:center; gap:10px;
                     padding:18px 36px; background:var(--sbp-primary, #FF6B35); color:#fff; border-radius:12px;
                     font-size:17px; font-weight:700; text-decoration:none; border:none; cursor:pointer;
                     box-shadow:0 6px 20px rgba(0,0,0,.12); transition:all .2s ease; min-height:52px; }
      .sbp-cta-btn:hover { transform:translateY(-2px); box-shadow:0 10px 28px rgba(0,0,0,.18); }

      /* error */
      .sbp-err { padding:14px; background:#FEF2F2; color:#991B1B; border-radius:10px; font-size:13px;
                 border:1px solid #FECACA; }
    `;
    const style = document.createElement('style');
    style.id = 'sbp-live-styles';
    style.textContent = css;
    document.head.appendChild(style);
  }

  /* ── data fetchers ───────────────────────────────────────────── */
  let _shopCache = null;
  let _lastShopErr = null;
  async function fetchShop(){
    if (_shopCache) return _shopCache;
    try {
      const { data, error } = await sb.rpc('sbp_resolve_shop_slug', { p_slug: SLUG });
      if (error) { _lastShopErr = error; throw error; }
      if (!data) { _lastShopErr = { message: 'RPC returned null/empty for slug=' + SLUG }; return null; }
      _shopCache = data;
      return data;
    } catch (e) {
      console.error('[live-site] fetchShop failed:', e);
      _lastShopErr = e;
      return null;
    }
  }

  async function fetchServices(){
    try {
      const { data, error } = await sb.rpc('sbp_get_shop_services_public', { p_slug: SLUG });
      if (error) throw error;
      if (data && data.ok && Array.isArray(data.services)) return data.services;
      if (Array.isArray(data)) return data;
      return [];
    } catch (e) {
      console.warn('[live-site] services unavailable:', e?.message || e);
      return [];
    }
  }

  /* ── component renderers ─────────────────────────────────────── */

  function renderServices(el, services){
    if (!services.length){
      el.innerHTML = '<div class="sbp-empty">Services coming soon.</div>';
      return;
    }
    const cards = services.map(s => {
      const name  = esc(s.name || s.service_name || 'Service');
      const desc  = s.description ? `<div class="sbp-svc-desc">${esc(s.description)}</div>` : '';
      const price = s.price != null ? `<div class="sbp-svc-price">${fmtPrice(s.price)}</div>` : '';
      const dur   = s.duration_minutes ? `<div class="sbp-svc-dur">${esc(s.duration_minutes)} min</div>` : '';
      return `<div class="sbp-svc-card">
        <div class="sbp-svc-name">${name}</div>
        ${desc}
        <div class="sbp-svc-meta">${price}${dur}</div>
      </div>`;
    }).join('');
    el.innerHTML = `<div class="sbp-svc-grid">${cards}</div>`;
  }

  function renderContact(el, shop){
    const c = (shop && shop.content) || {};
    const phone = c.phone || '';
    const wa    = c.whatsapp || phone;
    const addr  = [c.address, c.city].filter(Boolean).join(', ');
    const name  = shop?.shop_name || c.name || 'Shop';

    const parts = [];
    if (wa){
      parts.push(`<a class="sbp-btn sbp-btn-wa" href="${esc(whatsAppLink(wa, `Hi ${name}, I would like to enquire.`))}" target="_blank" rel="noopener" aria-label="Chat on WhatsApp">
        <span>💬</span><span>WhatsApp</span></a>`);
    }
    if (phone){
      parts.push(`<a class="sbp-btn sbp-btn-call" href="tel:${esc(digits(phone))}" aria-label="Call shop">
        <span>📞</span><span>Call</span></a>`);
    }
    if (addr){
      const mapUrl = 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(addr);
      parts.push(`<a class="sbp-btn sbp-btn-dir" href="${esc(mapUrl)}" target="_blank" rel="noopener" aria-label="Get directions">
        <span>📍</span><span>Directions</span></a>`);
    }

    if (!parts.length){
      el.innerHTML = '<div class="sbp-empty">Contact details coming soon.</div>';
      return;
    }
    el.innerHTML = `<div class="sbp-contact-row">${parts.join('')}</div>`;
  }

  function renderGallery(el, shop){
    const c = (shop && shop.content) || {};
    const imgs = Array.isArray(c.gallery) ? c.gallery : (Array.isArray(c.gallery_images) ? c.gallery_images : []);
    const urls = imgs
      .map(g => typeof g === 'string' ? g : (g?.url || g?.src || ''))
      .filter(u => u && (u.startsWith('http') || u.startsWith('data:')));

    if (!urls.length){
      el.style.display = 'none';
      return;
    }
    el.innerHTML = `<div class="sbp-gal-grid">${
      urls.slice(0, 12).map(u =>
        `<img class="sbp-gal-img" src="${esc(u)}" alt="" loading="lazy" onerror="this.style.display='none'">`
      ).join('')
    }</div>`;
  }

  function renderInfo(el, shop){
    const c = (shop && shop.content) || {};
    const rows = [];
    const addr = [c.address, c.city].filter(Boolean).join(', ');
    if (addr) rows.push({
      ic: '📍', lbl: 'Address',
      val: `<a href="https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(addr)}" target="_blank" rel="noopener">${esc(addr)}</a>`
    });
    if (c.hours) rows.push({ ic: '🕐', lbl: 'Hours', val: esc(c.hours) });
    if (c.phone) rows.push({ ic: '📞', lbl: 'Phone', val: `<a href="tel:${esc(digits(c.phone))}">${esc(c.phone)}</a>` });
    if (c.email) rows.push({ ic: '✉️', lbl: 'Email', val: `<a href="mailto:${esc(c.email)}">${esc(c.email)}</a>` });
    if (c.gst_number) rows.push({ ic: '🧾', lbl: 'GSTIN', val: esc(c.gst_number) });

    if (!rows.length){
      el.innerHTML = '<div class="sbp-empty">Contact details coming soon.</div>';
      return;
    }
    el.innerHTML = `<div class="sbp-info">${rows.map(r => `
      <div class="sbp-info-row">
        <div class="sbp-info-ic">${r.ic}</div>
        <div>
          <div class="sbp-info-lbl">${r.lbl}</div>
          <div class="sbp-info-val">${r.val}</div>
        </div>
      </div>
    `).join('')}</div>`;
  }

  function renderCta(el, shop){
    const c = (shop && shop.content) || {};
    const wa = c.whatsapp || c.phone || '';
    const name = shop?.shop_name || c.name || 'us';
    if (!wa){
      el.style.display = 'none';
      return;
    }
    const label = el.getAttribute('data-label') || 'Message us on WhatsApp';
    const msg = `Hi ${name}, I would like to enquire.`;
    el.innerHTML = `<a class="sbp-cta-btn" href="${esc(whatsAppLink(wa, msg))}" target="_blank" rel="noopener">
      <span>💬</span><span>${esc(label)}</span>
    </a>`;

    // Log WA click (best effort, fire & forget)
    el.querySelector('a').addEventListener('click', () => {
      try { sb.rpc('sbp_log_whatsapp_click', { p_slug: SLUG }); } catch(_){}
    });
  }

  /* ── orchestration ───────────────────────────────────────────── */
  async function hydrate(){
    injectStyles();

    const all = Array.from(document.querySelectorAll('[data-sbp]'));
    if (!all.length) return;

    // Show loading state immediately
    all.forEach(el => {
      if (!el.innerHTML.trim()){
        el.innerHTML = '<div class="sbp-loading">Loading…</div>';
      }
    });

    // Parallel fetches
    const [shop, services] = await Promise.all([
      fetchShop(),
      // only fetch services if any placeholder needs them
      all.some(el => el.getAttribute('data-sbp') === 'services')
        ? fetchServices() : Promise.resolve([])
    ]);

    if (!shop){
      const reason = _lastShopErr?.message
                  || _lastShopErr?.error
                  || _lastShopErr?.hint
                  || (typeof _lastShopErr === 'string' ? _lastShopErr : JSON.stringify(_lastShopErr));
      const diag = `slug='${SLUG}' · sdk=${!!window.supabase} · url=${(URL||'').slice(0,40)}`;
      all.forEach(el => el.innerHTML = `<div class="sbp-err"><strong>Shop data error:</strong> ${esc(reason || 'unknown')}<br><small style="opacity:.65;font-family:monospace">${esc(diag)}</small></div>`);
      return;
    }

    // Render each placeholder by type
    for (const el of all){
      const type = (el.getAttribute('data-sbp') || '').toLowerCase().trim();
      try {
        switch (type){
          case 'services':  renderServices(el, services); break;
          case 'contact':   renderContact(el, shop); break;
          case 'gallery':   renderGallery(el, shop); break;
          case 'info':      renderInfo(el, shop); break;
          case 'cta':       renderCta(el, shop); break;
          case 'services-modal':
          case 'gallery-modal':
          case 'rooms-modal':
          case 'amenities-modal':
          case 'doctors-modal':
          case 'stylists-modal':
            el.style.display = 'none';
            break;
          default:
            console.warn('[live-site] unknown data-sbp type:', type);
            el.innerHTML = '';
        }
      } catch (e) {
        console.error('[live-site] render', type, 'failed:', e);
        el.innerHTML = '<div class="sbp-err">Component failed to load.</div>';
      }
    }

    // Log page view once
    try { sb.rpc('sbp_log_shop_page_view', { p_slug: SLUG }); } catch(_){}
  }

  /* ══════════════════════════════════════════════════════════════════
     V5 — VIEW-ALL MODAL SYSTEM
     Modals fetched on-demand from public RPCs. Inline teasers + modal
     give complete coverage of long lists without bloating page weight.
     ══════════════════════════════════════════════════════════════════ */

  function injectModalStyles(){
    if (document.getElementById('sbp-view-modal-styles')) return;
    var css = '' +
      '.sbp-view-modal{position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.72);' +
      'backdrop-filter:blur(4px);-webkit-backdrop-filter:blur(4px);' +
      'display:flex;align-items:center;justify-content:center;opacity:0;' +
      'transition:opacity 0.22s ease;padding:20px}' +
      '.sbp-view-modal.open{opacity:1}' +
      '.sbp-view-modal-box{background:#fff;border-radius:20px;width:100%;max-width:880px;' +
      'max-height:90vh;overflow:hidden;display:flex;flex-direction:column;' +
      'box-shadow:0 30px 80px rgba(0,0,0,0.4);transform:translateY(20px);' +
      'transition:transform 0.28s cubic-bezier(0.4,0,0.2,1)}' +
      '.sbp-view-modal.open .sbp-view-modal-box{transform:translateY(0)}' +
      '.sbp-view-modal-head{padding:20px 24px;display:flex;align-items:center;' +
      'justify-content:space-between;border-bottom:1px solid #E5E7EB;' +
      'background:linear-gradient(180deg,#fff 0%,#FAFAFA 100%);position:sticky;top:0;z-index:1}' +
      '.sbp-view-modal-title{font-size:22px;font-weight:700;color:#1A1A1A;margin:0}' +
      '.sbp-view-modal-close{width:40px;height:40px;border-radius:50%;border:0;' +
      'background:#F3F4F6;cursor:pointer;font-size:18px;line-height:1;' +
      'display:flex;align-items:center;justify-content:center;transition:all 0.15s;color:#374151}' +
      '.sbp-view-modal-close:hover{background:#E5E7EB;transform:scale(1.06)}' +
      '.sbp-view-modal-body{padding:24px;overflow-y:auto;flex:1}' +
      '.sbp-view-modal-body::-webkit-scrollbar{width:8px}' +
      '.sbp-view-modal-body::-webkit-scrollbar-thumb{background:#D1D5DB;border-radius:4px}' +
      '@media (max-width:640px){' +
        '.sbp-view-modal{padding:0;align-items:flex-end}' +
        '.sbp-view-modal-box{max-width:100%;max-height:92vh;border-radius:20px 20px 0 0}' +
        '.sbp-view-modal-title{font-size:18px}' +
      '}';
    var style = document.createElement('style');
    style.id = 'sbp-view-modal-styles';
    style.textContent = css;
    document.head.appendChild(style);
  }

  var _viewModalEl = null;
  var _viewModalLastFocus = null;
  var _viewModalKeyHandler = null;

  function openViewModal(title, contentHtml){
    injectModalStyles();
    closeViewModal();
    _viewModalLastFocus = document.activeElement;

    var wrap = document.createElement('div');
    wrap.className = 'sbp-view-modal';
    wrap.setAttribute('role','dialog');
    wrap.setAttribute('aria-modal','true');
    wrap.setAttribute('aria-label', title);
    wrap.innerHTML =
      '<div class="sbp-view-modal-box" role="document">' +
        '<div class="sbp-view-modal-head">' +
          '<h2 class="sbp-view-modal-title">' + esc(title) + '</h2>' +
          '<button class="sbp-view-modal-close" type="button" aria-label="Close">' +
          String.fromCharCode(10006) +
          '</button>' +
        '</div>' +
        '<div class="sbp-view-modal-body">' + contentHtml + '</div>' +
      '</div>';
    document.body.appendChild(wrap);
    _viewModalEl = wrap;
    document.body.style.overflow = 'hidden';

    requestAnimationFrame(function(){ wrap.classList.add('open'); });

    wrap.addEventListener('click', function(e){
      if (e.target === wrap) closeViewModal();
    });
    wrap.querySelector('.sbp-view-modal-close').addEventListener('click', closeViewModal);
    _viewModalKeyHandler = function(e){ if (e.key === 'Escape') closeViewModal(); };
    document.addEventListener('keydown', _viewModalKeyHandler);

    setTimeout(function(){
      var btn = wrap.querySelector('.sbp-view-modal-close');
      if (btn) btn.focus();
    }, 100);
  }

  function closeViewModal(){
    if (!_viewModalEl) return;
    var el = _viewModalEl;
    el.classList.remove('open');
    document.body.style.overflow = '';
    if (_viewModalKeyHandler){
      document.removeEventListener('keydown', _viewModalKeyHandler);
      _viewModalKeyHandler = null;
    }
    setTimeout(function(){
      try { el.remove(); } catch(_){}
      _viewModalEl = null;
      if (_viewModalLastFocus && typeof _viewModalLastFocus.focus === 'function'){
        try { _viewModalLastFocus.focus(); } catch(_){}
      }
    }, 240);
  }

  function modalLoadingHtml(label){
    return '<div class="sbp-loading" style="padding:60px 20px;text-align:center;color:#6B7280">' +
           '<div style="font-size:14px">Loading ' + esc(label) + '...</div></div>';
  }

  function modalEmptyHtml(label){
    return '<div class="sbp-empty" style="padding:60px 20px;text-align:center;color:#6B7280">' +
           '<div style="font-size:14px">No ' + esc(label) + ' available yet.</div></div>';
  }

  async function openServicesModal(){
    var title = (function(){
      var t = (_shopCache && _shopCache.shop_type || '').toLowerCase();
      if (/restaurant|cafe|qsr|food|tiffin|catering|ice_cream|cloud_kitchen/.test(t)) return 'Our Menu';
      if (/salon|spa|beauty|barber/.test(t)) return 'Our Services';
      if (/clinic|hospital|pharma|dental|doctor|healthcare/.test(t)) return 'Our Treatments';
      if (/grocery|kirana|garment|retail|mart|store/.test(t)) return 'Our Products';
      return 'Full Menu';
    })();

    openViewModal(title, modalLoadingHtml(title.toLowerCase()));

    var items = [];
    try {
      var resp = await sb.rpc('sbp_get_shop_services_public', { p_slug: SLUG });
      var data = resp.data; var error = resp.error;
      if (!error){
        if (data && data.ok && Array.isArray(data.services)) items = data.services;
        else if (Array.isArray(data)) items = data;
      }
    } catch(e){
      console.warn('[view-modal] services fetch failed:', e);
    }

    var body = _viewModalEl && _viewModalEl.querySelector('.sbp-view-modal-body');
    if (!body) return;
    if (!items.length){
      body.innerHTML = modalEmptyHtml('items');
      return;
    }

    var byCat = {};
    var order = [];
    items.forEach(function(s){
      var cat = (s.category || s.section || 'Items');
      if (!byCat[cat]){ byCat[cat] = []; order.push(cat); }
      byCat[cat].push(s);
    });

    var html = order.map(function(cat){
      var cards = byCat[cat].map(function(s){
        var name  = esc(s.name || s.service_name || 'Item');
        var desc  = s.description ? '<div class="sbp-svc-desc">' + esc(s.description) + '</div>' : '';
        var price = s.price != null ? '<div class="sbp-svc-price">' + fmtPrice(s.price) + '</div>' : '';
        var dur   = s.duration_minutes ? '<div class="sbp-svc-dur">' + esc(s.duration_minutes) + ' min</div>' : '';
        return '<div class="sbp-svc-card">' +
                 '<div class="sbp-svc-name">' + name + '</div>' +
                 desc +
                 '<div class="sbp-svc-meta">' + price + dur + '</div>' +
               '</div>';
      }).join('');
      var catHead = order.length > 1
        ? '<h3 style="font-size:13px;font-weight:700;margin:24px 0 14px;padding-top:8px;' +
          'border-top:1px solid #E5E7EB;text-transform:uppercase;letter-spacing:0.5px;' +
          'color:var(--sbp-primary,#FF6B35)">' + esc(cat) + '</h3>'
        : '';
      return catHead + '<div class="sbp-svc-grid">' + cards + '</div>';
    }).join('');

    body.innerHTML = html;
  }

  async function openGalleryModal(){
    openViewModal('Gallery', modalLoadingHtml('photos'));
    var imgs = [];
    try {
      var c = (_shopCache && _shopCache.content) || {};
      var raw = Array.isArray(c.gallery) ? c.gallery
              : (Array.isArray(c.gallery_images) ? c.gallery_images : []);
      imgs = raw.map(function(g){ return typeof g === 'string' ? g : (g && (g.url || g.src) || ''); })
                .filter(function(u){ return u && (u.indexOf('http') === 0 || u.indexOf('data:') === 0); });
    } catch(_){}

    var body = _viewModalEl && _viewModalEl.querySelector('.sbp-view-modal-body');
    if (!body) return;
    if (!imgs.length){ body.innerHTML = modalEmptyHtml('photos'); return; }

    var grid = imgs.map(function(u){
      return '<img class="sbp-gal-img" src="' + esc(u) + '" alt="" loading="lazy" ' +
        'style="aspect-ratio:1/1;object-fit:cover" ' +
        "onerror=\"this.style.display='none'\">";
    }).join('');
    body.innerHTML = '<div class="sbp-gal-grid" style="grid-template-columns:repeat(auto-fill,minmax(180px,1fr))">' + grid + '</div>';
  }

  async function openRoomsModal(){
    openViewModal('Our Rooms', modalLoadingHtml('rooms'));
    var rooms = [];
    try {
      var c = (_shopCache && _shopCache.content) || {};
      rooms = Array.isArray(c.rooms) ? c.rooms : [];
    } catch(_){}
    var body = _viewModalEl && _viewModalEl.querySelector('.sbp-view-modal-body');
    if (!body) return;
    if (!rooms.length){ body.innerHTML = modalEmptyHtml('rooms'); return; }
    var cards = rooms.map(function(r){
      var name = esc(r.name || r.room_type || 'Room');
      var desc = r.description ? '<div class="sbp-svc-desc">' + esc(r.description) + '</div>' : '';
      var price = r.price != null ? '<div class="sbp-svc-price">' + fmtPrice(r.price) + ' / night</div>' : '';
      var cap  = r.capacity ? '<div class="sbp-svc-dur">Sleeps ' + esc(r.capacity) + '</div>' : '';
      return '<div class="sbp-svc-card"><div class="sbp-svc-name">' + name + '</div>' + desc +
             '<div class="sbp-svc-meta">' + price + cap + '</div></div>';
    }).join('');
    body.innerHTML = '<div class="sbp-svc-grid">' + cards + '</div>';
  }

  async function openAmenitiesModal(){
    openViewModal('Amenities', modalLoadingHtml('amenities'));
    var am = [];
    try {
      var c = (_shopCache && _shopCache.content) || {};
      am = Array.isArray(c.amenities) ? c.amenities : [];
    } catch(_){}
    var body = _viewModalEl && _viewModalEl.querySelector('.sbp-view-modal-body');
    if (!body) return;
    if (!am.length){ body.innerHTML = modalEmptyHtml('amenities'); return; }
    var tiles = am.map(function(a){
      var label = typeof a === 'string' ? a : (a && (a.label || a.name) || '');
      return '<div style="padding:14px 18px;background:#F8F9FA;border-radius:12px;' +
             'display:flex;align-items:center;gap:10px;font-size:14px">' +
             '<span style="font-size:18px">' + String.fromCharCode(10003) + '</span>' +
             '<span>' + esc(label) + '</span></div>';
    }).join('');
    body.innerHTML = '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:10px">' + tiles + '</div>';
  }

  async function openStylistsModal(){
    openViewModal('Meet Our Team', modalLoadingHtml('team'));
    var team = [];
    try {
      var c = (_shopCache && _shopCache.content) || {};
      team = Array.isArray(c.stylists) ? c.stylists : [];
    } catch(_){}
    var body = _viewModalEl && _viewModalEl.querySelector('.sbp-view-modal-body');
    if (!body) return;
    if (!team.length){ body.innerHTML = modalEmptyHtml('team members'); return; }
    var cards = team.map(function(p){
      var name = esc(p.name || 'Stylist');
      var role = p.role ? '<div style="font-size:12px;color:var(--sbp-primary,#FF6B35);' +
                         'text-transform:uppercase;letter-spacing:0.5px;font-weight:600;margin-bottom:6px">' +
                         esc(p.role) + '</div>' : '';
      var bio  = p.bio ? '<div class="sbp-svc-desc">' + esc(p.bio) + '</div>' : '';
      var img  = p.photo_url ? '<img src="' + esc(p.photo_url) + '" alt="' + esc(name) +
                 '" style="width:100%;aspect-ratio:1/1;object-fit:cover;border-radius:14px;margin-bottom:12px" ' +
                 "onerror=\"this.style.display='none'\">" : '';
      return '<div class="sbp-svc-card">' + img + role +
             '<div class="sbp-svc-name">' + name + '</div>' + bio + '</div>';
    }).join('');
    body.innerHTML = '<div class="sbp-svc-grid">' + cards + '</div>';
  }

  async function openDoctorsModal(){
    openViewModal('Our Doctors', modalLoadingHtml('doctors'));
    var docs = [];
    try {
      var c = (_shopCache && _shopCache.content) || {};
      docs = Array.isArray(c.doctors) ? c.doctors : [];
    } catch(_){}
    var body = _viewModalEl && _viewModalEl.querySelector('.sbp-view-modal-body');
    if (!body) return;
    if (!docs.length){ body.innerHTML = modalEmptyHtml('doctors'); return; }
    var cards = docs.map(function(d){
      var name = esc(d.name || 'Doctor');
      var spec = d.specialty ? '<div style="font-size:12px;color:var(--sbp-primary,#FF6B35);' +
                              'text-transform:uppercase;letter-spacing:0.5px;font-weight:600;margin-bottom:6px">' +
                              esc(d.specialty) + '</div>' : '';
      var bio  = d.bio ? '<div class="sbp-svc-desc">' + esc(d.bio) + '</div>' : '';
      var exp  = d.experience_years ? '<div class="sbp-svc-dur">' + esc(d.experience_years) + ' yrs experience</div>' : '';
      var img  = d.photo_url ? '<img src="' + esc(d.photo_url) + '" alt="' + esc(name) +
                 '" style="width:100%;aspect-ratio:1/1;object-fit:cover;border-radius:14px;margin-bottom:12px" ' +
                 "onerror=\"this.style.display='none'\">" : '';
      return '<div class="sbp-svc-card">' + img + spec +
             '<div class="sbp-svc-name">' + name + '</div>' + bio +
             '<div class="sbp-svc-meta">' + exp + '</div></div>';
    }).join('');
    body.innerHTML = '<div class="sbp-svc-grid">' + cards + '</div>';
  }

  function modalClickHandler(e){
    var btn = e.target && e.target.closest && e.target.closest('[data-sbp-modal]');
    if (!btn) return;
    e.preventDefault();
    var type = (btn.getAttribute('data-sbp-modal') || '').toLowerCase().trim();
    switch (type){
      case 'services': openServicesModal(); break;
      case 'gallery':  openGalleryModal();  break;
      case 'rooms':    openRoomsModal();    break;
      case 'amenities':openAmenitiesModal();break;
      case 'stylists': openStylistsModal(); break;
      case 'doctors':  openDoctorsModal();  break;
      default:
        console.warn('[view-modal] unknown modal type:', type);
    }
  }
  document.addEventListener('click', modalClickHandler, true);

  /* ══════════════════════════════════════════════════════════════════
     V5 — PROGRESSIVE ENHANCEMENT + MOTION
     ══════════════════════════════════════════════════════════════════ */

  function detectCapability(){
    try {
      var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      if (reduce) return 'low';
      var mem = navigator.deviceMemory;
      var cores = navigator.hardwareConcurrency;
      var conn = navigator.connection || {};
      var eff = conn.effectiveType || '';
      if (/^(2g|slow-2g|3g)$/i.test(eff)) return 'low';
      if (mem != null && mem < 2) return 'low';
      if (cores != null && cores < 2) return 'low';
      if (mem != null && mem >= 4 && cores != null && cores >= 4) return 'high';
      return 'medium';
    } catch(_){ return 'medium'; }
  }

  var CAPABILITY = detectCapability();
  console.log('[live-site v5] device capability:', CAPABILITY);

  function loadAOS(){
    if (CAPABILITY === 'low') return;
    if (document.getElementById('sbp-aos-css')) return;
    var link = document.createElement('link');
    link.rel = 'stylesheet';
    link.id = 'sbp-aos-css';
    link.href = 'https://cdn.jsdelivr.net/npm/aos@2.3.4/dist/aos.css';
    document.head.appendChild(link);
    var script = document.createElement('script');
    script.src = 'https://cdn.jsdelivr.net/npm/aos@2.3.4/dist/aos.js';
    script.async = true;
    script.onload = function(){
      try {
        window.AOS && window.AOS.init({
          duration: CAPABILITY === 'high' ? 800 : 600,
          easing: 'ease-out-cubic',
          once: true,
          offset: 80,
          disable: CAPABILITY === 'low'
        });
      } catch(e){ console.warn('[motion] AOS init failed:', e); }
    };
    script.onerror = function(){ console.warn('[motion] AOS failed to load'); };
    document.head.appendChild(script);
  }

  function initCounters(){
    if (CAPABILITY === 'low') return;
    var els = document.querySelectorAll('[data-sbp-counter]');
    if (!els.length || !window.IntersectionObserver) return;
    var observer = new IntersectionObserver(function(entries){
      entries.forEach(function(entry){
        if (!entry.isIntersecting) return;
        var el = entry.target;
        if (el.dataset.sbpCounterDone) return;
        el.dataset.sbpCounterDone = '1';
        var target = parseInt(el.getAttribute('data-sbp-counter'), 10) || 0;
        var duration = CAPABILITY === 'high' ? 1800 : 1200;
        var start = performance.now();
        function tick(now){
          var elapsed = now - start;
          var progress = Math.min(elapsed / duration, 1);
          var eased = 1 - Math.pow(1 - progress, 3);
          var value = Math.floor(target * eased);
          el.textContent = value.toLocaleString('en-IN');
          if (progress < 1) requestAnimationFrame(tick);
          else el.textContent = target.toLocaleString('en-IN');
        }
        requestAnimationFrame(tick);
        observer.unobserve(el);
      });
    }, { threshold: 0.3 });
    Array.prototype.forEach.call(els, function(el){
      el.textContent = '0';
      observer.observe(el);
    });
  }

  function initParallax(){
    if (CAPABILITY !== 'high') return;
    var els = document.querySelectorAll('[data-sbp-parallax]');
    if (!els.length || !window.IntersectionObserver) return;
    var visible = new Set();
    var obs = new IntersectionObserver(function(entries){
      entries.forEach(function(e){
        if (e.isIntersecting) visible.add(e.target);
        else visible.delete(e.target);
      });
    }, { threshold: [0, 0.1, 0.5, 1] });
    Array.prototype.forEach.call(els, function(el){ obs.observe(el); });
    var raf = null;
    function onScroll(){
      if (raf) return;
      raf = requestAnimationFrame(function(){
        raf = null;
        visible.forEach(function(el){
          var rect = el.getBoundingClientRect();
          var speed = parseFloat(el.getAttribute('data-sbp-parallax')) || 0.5;
          var offset = rect.top * (1 - speed);
          el.style.backgroundPositionY = 'calc(50% + ' + offset.toFixed(1) + 'px)';
        });
      });
    }
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  function initSmoothScroll(){
    document.addEventListener('click', function(e){
      var a = e.target && e.target.closest && e.target.closest('a[href^="#"]');
      if (!a) return;
      var href = a.getAttribute('href');
      if (!href || href === '#') return;
      var target = document.querySelector(href);
      if (!target) return;
      e.preventDefault();
      target.scrollIntoView({ behavior: CAPABILITY === 'low' ? 'auto' : 'smooth', block: 'start' });
    }, true);
  }

  function bootMotion(){
    setTimeout(function(){
      try { loadAOS(); } catch(e){ console.warn('[motion] AOS load failed:', e); }
      try { initCounters(); } catch(e){ console.warn('[motion] counters failed:', e); }
      try { initParallax(); } catch(e){ console.warn('[motion] parallax failed:', e); }
      try { initSmoothScroll(); } catch(e){ console.warn('[motion] smoothscroll failed:', e); }
    }, 250);
  }

  if (document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', bootMotion);
  } else {
    bootMotion();
  }

  /* ══════════════════════════════════════════════════════════════════
     BOOKING FORM (v4.7) — intercepts "Book Now" clicks, shows modal,
     submits via sbp_create_booking_public RPC. Works for any vertical;
     form fields adapt to form_mode (hospitality / service / generic).
  ══════════════════════════════════════════════════════════════════ */

  let _bookingConfig = null;   // cached config from sbp_get_public_booking_form_config

  async function fetchBookingConfig(){
    if (_bookingConfig) return _bookingConfig;
    try {
      const { data, error } = await sb.rpc('sbp_get_public_booking_form_config', { p_slug: SLUG });
      if (error){ console.warn('[booking] config error:', error); return null; }
      if (!data?.ok){ console.warn('[booking] config not ok:', data); return null; }
      _bookingConfig = data;
      return data;
    } catch(e){ console.warn('[booking] config fetch failed:', e); return null; }
  }

  function injectBookingStyles(){
    if (document.getElementById('sbp-booking-styles')) return;
    const css = `
      .sbp-modal-overlay {
        position: fixed; inset: 0; background: rgba(0,0,0,.65);
        display: flex; align-items: center; justify-content: center;
        z-index: 999999; padding: 20px; opacity: 0;
        animation: sbpFadeIn .2s ease forwards;
      }
      @keyframes sbpFadeIn { to { opacity: 1; } }
      .sbp-modal {
        background: #fff; color: #1A1A1A; border-radius: 16px;
        max-width: 480px; width: 100%; max-height: 90vh; overflow-y: auto;
        font-family: inherit; box-shadow: 0 20px 60px rgba(0,0,0,.3);
      }
      .sbp-modal-hd {
        padding: 20px 24px; border-bottom: 1px solid #E5E7EB;
        display: flex; align-items: center; justify-content: space-between;
        position: sticky; top: 0; background: #fff; z-index: 1;
      }
      .sbp-modal-hd h3 { font-size: 18px; font-weight: 700; margin: 0; }
      .sbp-modal-x {
        background: transparent; border: 0; font-size: 24px; line-height: 1;
        cursor: pointer; color: #6B7280; padding: 4px 8px; border-radius: 6px;
      }
      .sbp-modal-x:hover { background: #F3F4F6; }
      .sbp-modal-bd { padding: 20px 24px; }
      .sbp-form-row { display: flex; flex-direction: column; gap: 6px; margin-bottom: 14px; }
      .sbp-form-row.two { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
      .sbp-form-row.two > div { display: flex; flex-direction: column; gap: 6px; }
      .sbp-lbl {
        font-size: 13px; font-weight: 600; color: #1A1A1A;
      }
      .sbp-lbl .sbp-req { color: #EF4444; margin-left: 2px; }
      .sbp-input {
        padding: 11px 13px; border: 1px solid #E5E7EB; border-radius: 9px;
        font-size: 14px; font-family: inherit; color: #1A1A1A; background: #fff;
        width: 100%; box-sizing: border-box; -webkit-appearance: none;
      }
      .sbp-input:focus {
        outline: none; border-color: var(--sbp-primary, #FF6B35);
        box-shadow: 0 0 0 3px rgba(255,107,53,.1);
      }
      textarea.sbp-input { resize: vertical; min-height: 60px; }
      .sbp-helper { font-size: 11.5px; color: #6B7280; }
      .sbp-modal-foot {
        padding: 16px 24px; border-top: 1px solid #E5E7EB; display: flex;
        gap: 10px; justify-content: flex-end; position: sticky; bottom: 0;
        background: #fff;
      }
      .sbp-bk-btn {
        padding: 12px 22px; border-radius: 10px; font-size: 14.5px;
        font-weight: 600; cursor: pointer; border: 0; font-family: inherit;
        transition: all .15s ease;
      }
      .sbp-bk-cancel { background: #F3F4F6; color: #1A1A1A; }
      .sbp-bk-cancel:hover { background: #E5E7EB; }
      .sbp-bk-submit {
        background: var(--sbp-primary, #FF6B35); color: #fff;
        min-width: 130px;
      }
      .sbp-bk-submit:hover:not(:disabled) {
        transform: translateY(-1px); filter: brightness(1.05);
      }
      .sbp-bk-submit:disabled { opacity: .6; cursor: not-allowed; }
      .sbp-bk-err {
        background: #FEF2F2; color: #991B1B; border: 1px solid #FECACA;
        padding: 10px 13px; border-radius: 8px; font-size: 13px;
        margin-bottom: 14px;
      }
      .sbp-bk-success {
        text-align: center; padding: 20px 0;
      }
      .sbp-bk-success-ic {
        font-size: 56px; margin-bottom: 14px;
      }
      .sbp-bk-success h4 {
        font-size: 22px; font-weight: 700; margin: 0 0 10px;
        color: #1A1A1A;
      }
      .sbp-bk-success p {
        color: #6B7280; font-size: 14px; margin: 0 0 14px; line-height: 1.55;
      }
      .sbp-bk-code {
        display: inline-block; padding: 8px 16px; background: #F3F4F6;
        border-radius: 8px; font-family: monospace; font-size: 16px;
        font-weight: 700; letter-spacing: 1.5px; color: #1A1A1A;
        margin: 0 0 16px;
      }
      .sbp-bk-summary {
        background: #F8F9FA; border-radius: 10px; padding: 14px;
        font-size: 13px; color: #1A1A1A; text-align: left; line-height: 1.7;
        margin: 0 0 16px;
      }
      .sbp-bk-summary b { color: #6B7280; font-weight: 600; }
      .sbp-bk-wa {
        display: inline-flex; align-items: center; gap: 8px;
        padding: 12px 20px; background: #25D366; color: #fff;
        text-decoration: none; border-radius: 9px; font-weight: 600;
        font-size: 14px;
      }
      .sbp-modal-bd[data-state="loading"] { text-align: center; padding: 40px 24px; }
      .sbp-spinner {
        width: 32px; height: 32px; border: 3px solid #E5E7EB;
        border-top-color: var(--sbp-primary, #FF6B35); border-radius: 50%;
        animation: sbpSpin .8s linear infinite; margin: 0 auto 12px;
      }
      @keyframes sbpSpin { to { transform: rotate(360deg); } }
      @media (max-width: 480px) {
        .sbp-form-row.two { grid-template-columns: 1fr; }
        .sbp-modal-bd { padding: 16px 18px; }
        .sbp-modal-hd { padding: 16px 18px; }
        .sbp-modal-foot { padding: 14px 18px; }
      }
    `;
    const style = document.createElement('style');
    style.id = 'sbp-booking-styles';
    style.textContent = css;
    document.head.appendChild(style);
  }

  function closeBookingModal(){
    const m = document.getElementById('sbp-booking-modal');
    if (m) m.remove();
  }

  async function openBookingModal(prefillRoomName){
    injectBookingStyles();

    // Close any existing modal first
    closeBookingModal();

    const cfg = await fetchBookingConfig();
    if (!cfg){
      alert('Booking is not available right now. Please try contacting the shop directly.');
      return;
    }

    const mode = cfg.form_mode || 'generic';
    const shopName = cfg.shop_name || 'this business';

    // Today + 1 day for default check-in
    const today = new Date();
    const tmrw = new Date(today.getTime() + 24*60*60*1000);
    const dayAfter = new Date(today.getTime() + 2*24*60*60*1000);
    const fmtDate = d => d.toISOString().slice(0,10);
    const minDate = fmtDate(today);
    const defaultIn  = fmtDate(tmrw);
    const defaultOut = fmtDate(dayAfter);

    // Build form fields based on mode
    let dateBlock, roomBlock;

    if (mode === 'hospitality'){
      dateBlock = `
        <div class="sbp-form-row two">
          <div>
            <label class="sbp-lbl">Check-in <span class="sbp-req">*</span></label>
            <input type="date" class="sbp-input" id="sbp-bk-checkin" min="${minDate}" value="${defaultIn}" required>
          </div>
          <div>
            <label class="sbp-lbl">Check-out <span class="sbp-req">*</span></label>
            <input type="date" class="sbp-input" id="sbp-bk-checkout" min="${defaultIn}" value="${defaultOut}" required>
          </div>
        </div>
        <div class="sbp-form-row two">
          <div>
            <label class="sbp-lbl">Adults <span class="sbp-req">*</span></label>
            <input type="number" class="sbp-input" id="sbp-bk-adults" min="1" max="20" value="2" required>
          </div>
          <div>
            <label class="sbp-lbl">Children</label>
            <input type="number" class="sbp-input" id="sbp-bk-children" min="0" max="10" value="0">
          </div>
        </div>`;
      roomBlock = `
        <div class="sbp-form-row">
          <label class="sbp-lbl">Room type</label>
          <input type="text" class="sbp-input" id="sbp-bk-room" value="${esc(prefillRoomName || '')}" placeholder="Any preference?">
        </div>`;
    } else if (mode === 'service'){
      dateBlock = `
        <div class="sbp-form-row two">
          <div>
            <label class="sbp-lbl">Preferred date <span class="sbp-req">*</span></label>
            <input type="date" class="sbp-input" id="sbp-bk-checkin" min="${minDate}" value="${defaultIn}" required>
          </div>
          <div>
            <label class="sbp-lbl">Time (optional)</label>
            <input type="time" class="sbp-input" id="sbp-bk-time">
          </div>
        </div>`;
      roomBlock = `
        <div class="sbp-form-row">
          <label class="sbp-lbl">Service interested in</label>
          <input type="text" class="sbp-input" id="sbp-bk-room" value="${esc(prefillRoomName || '')}" placeholder="Which service?">
        </div>`;
    } else if (mode === 'table_reservation'){
      dateBlock = `
        <div class="sbp-form-row two">
          <div>
            <label class="sbp-lbl">Date <span class="sbp-req">*</span></label>
            <input type="date" class="sbp-input" id="sbp-bk-checkin" min="${minDate}" value="${defaultIn}" required>
          </div>
          <div>
            <label class="sbp-lbl">Time <span class="sbp-req">*</span></label>
            <input type="time" class="sbp-input" id="sbp-bk-time" required>
          </div>
        </div>
        <div class="sbp-form-row two">
          <div>
            <label class="sbp-lbl">Party size <span class="sbp-req">*</span></label>
            <input type="number" class="sbp-input" id="sbp-bk-adults" min="1" max="50" value="2" required>
          </div>
          <div>
            <label class="sbp-lbl">Occasion</label>
            <input type="text" class="sbp-input" id="sbp-bk-room" value="${esc(prefillRoomName || '')}" placeholder="Birthday, anniversary…">
          </div>
        </div>`;
      roomBlock = '';
    } else {
      dateBlock = `
        <div class="sbp-form-row">
          <label class="sbp-lbl">Preferred date <span class="sbp-req">*</span></label>
          <input type="date" class="sbp-input" id="sbp-bk-checkin" min="${minDate}" value="${defaultIn}" required>
        </div>`;
      roomBlock = `
        <div class="sbp-form-row">
          <label class="sbp-lbl">What are you interested in?</label>
          <input type="text" class="sbp-input" id="sbp-bk-room" value="${esc(prefillRoomName || '')}" placeholder="Tell us what you need">
        </div>`;
    }

    const title = mode === 'table_reservation' ? 'Reserve a Table' : mode === 'hospitality' ? 'Book a Room'
                : mode === 'service'     ? 'Book Appointment'
                : 'Send Enquiry';

    const modalHtml = `
      <div class="sbp-modal-overlay" id="sbp-booking-modal">
        <div class="sbp-modal" role="dialog" aria-modal="true">
          <div class="sbp-modal-hd">
            <h3>${esc(title)}</h3>
            <button type="button" class="sbp-modal-x" id="sbp-bk-close" aria-label="Close">×</button>
          </div>
          <div class="sbp-modal-bd" id="sbp-bk-body">
            <form id="sbp-bk-form" autocomplete="on">
              <div id="sbp-bk-err-slot"></div>
              <div class="sbp-form-row">
                <label class="sbp-lbl">Your name <span class="sbp-req">*</span></label>
                <input type="text" class="sbp-input" id="sbp-bk-name" autocomplete="name" required maxlength="100">
              </div>
              <div class="sbp-form-row two">
                <div>
                  <label class="sbp-lbl">Phone <span class="sbp-req">*</span></label>
                  <input type="tel" class="sbp-input" id="sbp-bk-phone" autocomplete="tel" required maxlength="15" placeholder="9876543210">
                </div>
                <div>
                  <label class="sbp-lbl">Email</label>
                  <input type="email" class="sbp-input" id="sbp-bk-email" autocomplete="email" maxlength="100">
                </div>
              </div>
              ${dateBlock}
              ${roomBlock}
              <div class="sbp-form-row">
                <label class="sbp-lbl">Notes / special requests</label>
                <textarea class="sbp-input" id="sbp-bk-notes" rows="2" maxlength="500" placeholder="Anything we should know?"></textarea>
              </div>
            </form>
          </div>
          <div class="sbp-modal-foot">
            <button type="button" class="sbp-bk-btn sbp-bk-cancel" id="sbp-bk-cancel-btn">Cancel</button>
            <button type="button" class="sbp-bk-btn sbp-bk-submit" id="sbp-bk-submit-btn">Send request</button>
          </div>
        </div>
      </div>`;

    const wrap = document.createElement('div');
    wrap.innerHTML = modalHtml;
    document.body.appendChild(wrap.firstElementChild);

    // Wire events
    document.getElementById('sbp-bk-close').addEventListener('click', closeBookingModal);
    document.getElementById('sbp-bk-cancel-btn').addEventListener('click', closeBookingModal);
    document.getElementById('sbp-booking-modal').addEventListener('click', e => {
      if (e.target.id === 'sbp-booking-modal') closeBookingModal();
    });
    document.getElementById('sbp-bk-submit-btn').addEventListener('click', () => submitBookingForm(mode, cfg));

    // Keep check-out >= check-in + 1 (hospitality only)
    if (mode === 'hospitality'){
      const cin  = document.getElementById('sbp-bk-checkin');
      const cout = document.getElementById('sbp-bk-checkout');
      cin?.addEventListener('change', () => {
        const inDate = new Date(cin.value);
        if (!isNaN(inDate)){
          const minOut = new Date(inDate.getTime() + 24*60*60*1000);
          cout.min = fmtDate(minOut);
          if (new Date(cout.value) <= inDate){
            cout.value = fmtDate(minOut);
          }
        }
      });
    }

    // Focus name field
    setTimeout(() => document.getElementById('sbp-bk-name')?.focus(), 100);
  }

  async function submitBookingForm(mode, cfg){
    const errSlot = document.getElementById('sbp-bk-err-slot');
    const submitBtn = document.getElementById('sbp-bk-submit-btn');
    errSlot.innerHTML = '';
    submitBtn.disabled = true;
    submitBtn.textContent = 'Sending…';

    const name    = document.getElementById('sbp-bk-name').value.trim();
    const phone   = document.getElementById('sbp-bk-phone').value.trim();
    const email   = document.getElementById('sbp-bk-email').value.trim();
    const checkin = document.getElementById('sbp-bk-checkin').value;
    const notes   = document.getElementById('sbp-bk-notes').value.trim();
    const room    = document.getElementById('sbp-bk-room')?.value.trim() || '';

    if (!name || !phone || !checkin){
      errSlot.innerHTML = `<div class="sbp-bk-err">Please fill name, phone, and date.</div>`;
      submitBtn.disabled = false;
      submitBtn.textContent = 'Send request';
      return;
    }

    let checkoutVal, numAdults = 1, numChildren = 0;
    if (mode === 'hospitality'){
      checkoutVal = document.getElementById('sbp-bk-checkout').value;
      numAdults   = parseInt(document.getElementById('sbp-bk-adults').value, 10) || 1;
      numChildren = parseInt(document.getElementById('sbp-bk-children').value, 10) || 0;
      if (!checkoutVal){
        errSlot.innerHTML = `<div class="sbp-bk-err">Please pick a check-out date.</div>`;
        submitBtn.disabled = false;
        submitBtn.textContent = 'Send request';
        return;
      }
    } else {
      // For service/generic: book for one "night" so the table accepts it
      const cin = new Date(checkin);
      const cout = new Date(cin.getTime() + 24*60*60*1000);
      checkoutVal = cout.toISOString().slice(0,10);
    }

    // IP hash for rate limiting — use a simple per-session token.
    // NOTE: the iframe sandbox has an opaque origin (no allow-same-origin),
    // which makes sessionStorage throw a SecurityError on access. We wrap
    // every storage call in try/catch and fall back to an in-memory token
    // so the booking submit never crashes here. (Same class of bug as the
    // Web Locks API issue — sandboxed iframes block storage APIs.)
    let ipHash = null;
    try {
      ipHash = sessionStorage.getItem('sbp_ip_hash');
    } catch (_e) {
      // sessionStorage blocked in sandboxed iframe — use module-level cache
      ipHash = _sbpIpHashCache;
    }
    if (!ipHash){
      ipHash = 'sess-' + Math.random().toString(36).slice(2) + '-' + Date.now().toString(36);
      _sbpIpHashCache = ipHash;
      try { sessionStorage.setItem('sbp_ip_hash', ipHash); } catch (_e) { /* sandboxed — in-memory only */ }
    }

    const payload = {
      customer_name:  name,
      customer_phone: phone,
      customer_email: email,
      check_in_date:  checkin,
      check_out_date: checkoutVal,
      num_adults:     numAdults,
      num_children:   numChildren,
      room_type_name: room,
      notes:          notes
    };

    try {
      const _isTableRes = (mode === 'table_reservation');
      const _resRpc = _isTableRes ? 'sbp_create_table_reservation_public'
                                  : 'sbp_create_booking_public';
      const _resPayload = _isTableRes ? {
        name:       name,
        phone:      phone,
        email:      email,
        date:       checkin,
        time:       (document.getElementById('sbp-bk-time') || {}).value || '',
        party_size: numAdults,
        occasion:   (document.getElementById('sbp-bk-room') || {}).value || '',
        notes:      notes
      } : payload;
      const { data, error } = await sb.rpc(_resRpc, {
        p_slug:    SLUG,
        p_payload: _resPayload,
        p_ip_hash: ipHash
      });

      if (error){
        errSlot.innerHTML = `<div class="sbp-bk-err">Something went wrong: ${esc(error.message || 'unknown error')}</div>`;
        submitBtn.disabled = false;
        submitBtn.textContent = 'Send request';
        return;
      }
      if (!data?.ok){
        const msg = data?.message || errorMessageForCode(data?.error) || 'Could not submit booking.';
        errSlot.innerHTML = `<div class="sbp-bk-err">${esc(msg)}</div>`;
        submitBtn.disabled = false;
        submitBtn.textContent = 'Send request';
        return;
      }

      // ── Success! ──
      renderBookingSuccess(data, mode, cfg);
    } catch(e){
      console.error('[booking] submit failed:', e);
      errSlot.innerHTML = `<div class="sbp-bk-err">Connection error. Please try again.</div>`;
      submitBtn.disabled = false;
      submitBtn.textContent = 'Send request';
    }
  }

  function errorMessageForCode(code){
    const map = {
      shop_not_found:           'This shop is no longer accepting bookings.',
      rate_limited:             'Too many attempts. Please try again in an hour.',
      name_required:            'Please provide your name.',
      phone_required:           'Please provide a phone number.',
      invalid_phone:            'Phone number must be 10–15 digits.',
      invalid_email:            'Email format is invalid.',
      dates_required:           'Please pick the dates.',
      invalid_date:             'Date format is invalid.',
      check_in_past:            'Check-in cannot be in the past.',
      check_out_before_check_in:'Check-out must be after check-in.',
      stay_too_long:            'Stay cannot exceed 90 days.',
      invalid_room_type:        'Selected room is no longer available.'
    };
    return map[code] || null;
  }

  function renderBookingSuccess(data, mode, cfg){
    const body = document.getElementById('sbp-bk-body');
    const foot = document.querySelector('#sbp-booking-modal .sbp-modal-foot');

    const shopName = cfg.shop_name || 'the business';
    const shopPhone = data.shop_whatsapp || data.shop_phone || cfg.shop_phone;
    const code = data.confirmation_code;
    const cin = data.check_in;
    const cout = data.check_out;
    const nights = data.num_nights;

    // Build WhatsApp follow-up link
    let waLink = null;
    if (shopPhone){
      const cleanPhone = String(shopPhone).replace(/[^0-9]/g, '');
      const fullPhone = cleanPhone.length === 10 ? '91' + cleanPhone : cleanPhone;
      const msg = `Hi ${shopName}! I just submitted a booking request (code: ${code}). Please confirm availability.`;
      waLink = `https://wa.me/${fullPhone}?text=${encodeURIComponent(msg)}`;
    }

    const dateLabel = mode === 'hospitality'
      ? `<div><b>Check-in:</b> ${esc(cin)}<br><b>Check-out:</b> ${esc(cout)} (${nights} night${nights>1?'s':''})</div>`
      : `<div><b>Date:</b> ${esc(cin)}</div>`;

    body.innerHTML = `
      <div class="sbp-bk-success">
        <div class="sbp-bk-success-ic">✅</div>
        <h4>Request Sent!</h4>
        <p>Your booking request has been received. ${esc(shopName)} will contact you shortly to confirm.</p>
        <div class="sbp-bk-code">${esc(code)}</div>
        <div class="sbp-bk-summary">
          ${dateLabel}
        </div>
        ${waLink ? `<a class="sbp-bk-wa" href="${waLink}" target="_blank" rel="noopener">💬 Follow up on WhatsApp</a>` : ''}
      </div>`;

    foot.innerHTML = `
      <button type="button" class="sbp-bk-btn sbp-bk-submit" id="sbp-bk-done">Done</button>`;
    document.getElementById('sbp-bk-done').addEventListener('click', closeBookingModal);
  }

  /* ── Click interceptor: convert "Book Now" buttons → booking modal ── */
  function isBookingButton(el){
    if (!el) return false;
    const cls = (el.className || '').toString().toLowerCase();
    const txt = (el.textContent || '').toLowerCase().trim();

    // Match by text content first (most reliable)
    if (/\b(book|reserve|enquire|enquiry|inquire|inquiry|order|schedule|appointment|contact us)\b/i.test(txt)){
      return true;
    }
    // Or by explicit booking class
    if (/(?:^|\s)(btn-primary|btn-secondary|sbp-book|book-btn|book-now)(?:\s|$)/.test(cls)){
      // Only if it's actually inside a card/CTA context (not nav)
      const parent = el.closest('header, nav, .nav, .header');
      if (parent) return false;
      return true;
    }
    return false;
  }

  function findContextLabel(el){
    // Walk up to find a card/section title near the clicked button
    const card = el.closest('.room-card, .card, .service-card, .product-card, .feature-card, article, [class*="card"]');
    if (card){
      const heading = card.querySelector('h1, h2, h3, h4');
      if (heading) return heading.textContent.trim();
    }
    return null;
  }

  document.addEventListener('click', function(e){
    const a = e.target.closest('a, button');
    if (!a) return;
    if (!isBookingButton(a)) return;

    // Don't hijack outbound links (wa.me, tel:, mailto:)
    const href = a.getAttribute('href') || '';
    if (/^(tel:|mailto:|https?:\/\/wa\.me|whatsapp:)/.test(href)) return;

    // Don't hijack the existing CTA component (already a WhatsApp link)
    if (a.closest('[data-sbp="cta"]')) return;

    e.preventDefault();
    const ctx = findContextLabel(a);
    openBookingModal(ctx);
  }, true);

  if (document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', hydrate);
  } else {
    hydrate();
  }
})();
