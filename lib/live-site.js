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

    const title = mode === 'hospitality' ? 'Book a Room'
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
      const { data, error } = await sb.rpc('sbp_create_booking_public', {
        p_slug:    SLUG,
        p_payload: payload,
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
