/* ════════════════════════════════════════════════════════════════════
   live-site.js  —  ShopBill Pro AI Website Runtime  (Batch v4 / Phase 5a v2)

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
        --sbp-primary: var(--sbp-primary, #FF6B35);
        --sbp-accent:  var(--sbp-accent,  #001F3F);
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
      .sbp-svc-price { font-size:18px; font-weight:700; color:var(--sbp-accent); }
      .sbp-svc-dur { font-size:12px; color:var(--sbp-muted); }

      /* contact */
      .sbp-contact-row { display:flex; flex-wrap:wrap; gap:12px; }
      .sbp-btn { display:inline-flex; align-items:center; gap:8px; padding:14px 22px; border-radius:10px;
                 font-size:15px; font-weight:600; text-decoration:none; border:none; cursor:pointer;
                 transition:all .2s ease; min-height:44px; }
      .sbp-btn-wa   { background:var(--sbp-wa); color:#fff; }
      .sbp-btn-call { background:var(--sbp-primary); color:#fff; }
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
      .sbp-info-val a { color:var(--sbp-accent); text-decoration:none; }

      /* cta */
      .sbp-cta-btn { display:inline-flex; align-items:center; justify-content:center; gap:10px;
                     padding:18px 36px; background:var(--sbp-primary); color:#fff; border-radius:12px;
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

  if (document.readyState === 'loading'){
    document.addEventListener('DOMContentLoaded', hydrate);
  } else {
    hydrate();
  }
})();
