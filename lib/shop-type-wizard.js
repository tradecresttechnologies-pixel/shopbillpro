/* ════════════════════════════════════════════════════════════════
   ShopBill Pro — Shop Type Signup Wizard
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Renders a 2-step wizard the new shopkeeper completes during signup:
     Step 1: 12 macro categories (cards with emoji + name)
     Step 2: 8-12 specific business types under chosen macro
              (plus "Other" free-text fallback)

   USAGE (will be wired into index.html in Batch 1B):
     <script src="lib/shop-type-wizard.js"></script>

     SBPWizard.open({
       onSelect: (categoryCode, macroCode, extras) => {
         // extras may include { otherText: "..." } if user filled the "Other" field
         document.getElementById('shop_type').value = categoryCode;
       },
       onSkip: () => { // user skipped — defaults to general_retail
       }
     });

   Reads window.SBP_SUPABASE_URL + window.SBP_SUPABASE_KEY for direct
   Supabase calls. Falls back to a built-in slim catalog if RPC fails so
   the user can still complete signup.
══════════════════════════════════════════════════════════════════ */

(function(global){
  'use strict';

  const STYLE_ID = '_sbp_wizard_style';

  function injectStyles(){
    if(document.getElementById(STYLE_ID)) return;
    const css = `
      .sbpw-bg{position:fixed;inset:0;background:rgba(8,8,16,.85);backdrop-filter:blur(8px);z-index:9000;display:none;align-items:center;justify-content:center;padding:20px}
      .sbpw-bg.show{display:flex}
      .sbpw-modal{background:#13121C;border:1px solid rgba(124,58,237,.3);border-radius:18px;width:100%;max-width:720px;max-height:90vh;overflow:hidden;display:flex;flex-direction:column;color:#F0EFF8;font-family:'Outfit',sans-serif}
      .sbpw-hd{padding:22px 24px 14px;border-bottom:1px solid rgba(124,58,237,.15);position:relative}
      .sbpw-step-pip{display:flex;gap:6px;margin-bottom:10px}
      .sbpw-pip{width:34px;height:4px;border-radius:2px;background:rgba(124,58,237,.2)}
      .sbpw-pip.active{background:linear-gradient(90deg,#F5A623,#FF8A00)}
      .sbpw-pip.done{background:#10B981}
      .sbpw-title{font-size:22px;font-weight:800;background:linear-gradient(135deg,#F5A623,#FF8A00);-webkit-background-clip:text;-webkit-text-fill-color:transparent;margin-bottom:4px}
      .sbpw-sub{font-size:13px;color:#8A8AA8}
      .sbpw-skip{position:absolute;top:18px;right:20px;background:rgba(124,58,237,.1);border:1px solid rgba(124,58,237,.3);color:#8A8AA8;font-size:12px;font-weight:600;padding:6px 12px;border-radius:18px;cursor:pointer}
      .sbpw-back{position:absolute;top:18px;left:20px;background:rgba(124,58,237,.1);border:1px solid rgba(124,58,237,.3);color:#F0EFF8;font-size:12px;font-weight:600;padding:6px 12px;border-radius:18px;cursor:pointer;display:none}
      .sbpw-back.show{display:inline-block}
      .sbpw-body{padding:18px 24px 24px;overflow-y:auto;flex:1}
      .sbpw-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px}
      .sbpw-card{background:rgba(20,18,32,.8);border:1.5px solid rgba(124,58,237,.2);border-radius:12px;padding:16px 14px;cursor:pointer;transition:all .15s;display:flex;flex-direction:column;align-items:flex-start;gap:6px}
      .sbpw-card:hover{border-color:#F5A623;background:rgba(245,166,35,.08);transform:translateY(-2px)}
      .sbpw-card-emoji{font-size:30px;line-height:1}
      .sbpw-card-name{font-size:14px;font-weight:700;color:#F0EFF8;line-height:1.3}
      .sbpw-card-name-hi{font-size:11px;color:#8A8AA8;font-weight:500}
      .sbpw-other{margin-top:14px;padding:14px;background:rgba(99,102,241,.06);border:1px dashed rgba(99,102,241,.3);border-radius:10px}
      .sbpw-other-input{width:100%;padding:10px 12px;background:rgba(10,14,20,.6);border:1px solid rgba(124,58,237,.3);border-radius:8px;color:#F0EFF8;font-family:inherit;font-size:14px;margin-top:8px}
      .sbpw-empty{padding:50px;text-align:center;color:#8A8AA8}
      .sbpw-loading{padding:60px;text-align:center;color:#8A8AA8}
      .sbpw-loading-spinner{display:inline-block;width:36px;height:36px;border:3px solid rgba(245,166,35,.2);border-top-color:#F5A623;border-radius:50%;animation:sbpwSpin .8s linear infinite;margin-bottom:12px}
      @keyframes sbpwSpin{to{transform:rotate(360deg)}}
      @media(max-width:600px){.sbpw-modal{max-height:96vh;border-radius:16px}.sbpw-grid{grid-template-columns:repeat(2,1fr)}.sbpw-card{padding:12px 10px}.sbpw-card-emoji{font-size:24px}.sbpw-card-name{font-size:12px}}
    `;
    const s = document.createElement('style');
    s.id = STYLE_ID;
    s.textContent = css;
    document.head.appendChild(s);
  }

  // ─────────────────────────────────────────────────────────
  // Built-in slim catalog (used if Supabase unreachable)
  // Mirrors the macro list from migration 003 — kept in sync manually
  // ─────────────────────────────────────────────────────────
  const FALLBACK_MACROS = [
    { code: 'retail',       name_en: 'Retail (Goods)',       name_hi: 'खुदरा',         emoji: '🛒' },
    { code: 'food',         name_en: 'Food Service',         name_hi: 'खाद्य सेवा',     emoji: '🍽️' },
    { code: 'beauty',       name_en: 'Beauty & Wellness',    name_hi: 'सौंदर्य',        emoji: '✂️' },
    { code: 'healthcare',   name_en: 'Healthcare',           name_hi: 'स्वास्थ्य सेवा', emoji: '🏥' },
    { code: 'education',    name_en: 'Education & Coaching', name_hi: 'शिक्षा',         emoji: '🎓' },
    { code: 'services',     name_en: 'Services',             name_hi: 'सेवाएं',         emoji: '🔧' },
    { code: 'wholesale',    name_en: 'Wholesale / B2B',      name_hi: 'थोक',            emoji: '📦' },
    { code: 'online',       name_en: 'Online / D2C',         name_hi: 'ऑनलाइन',         emoji: '🌐' },
    { code: 'subscription', name_en: 'Subscription',         name_hi: 'सब्सक्रिप्शन',   emoji: '🔁' },
    { code: 'property',     name_en: 'Real Estate / Property',name_hi:'रियल एस्टेट',   emoji: '🏠' },
    { code: 'hospitality',  name_en: 'Hospitality',          name_hi: 'आतिथ्य',         emoji: '🏨' },
    { code: 'specialized',  name_en: 'Specialized',          name_hi: 'विशेष',          emoji: '⭐' }
  ];

  // Slim fallback for step 2 — one default category per macro
  const FALLBACK_BIZ_BY_MACRO = {
    retail:       [{ code: 'general_retail', name_en: 'General Retail', name_hi: 'सामान्य दुकान', emoji: '🏪', module_profile: 'standard' }],
    food:         [{ code: 'food_other',     name_en: 'Food Business',  name_hi: 'खाद्य',          emoji: '🍽️', module_profile: 'food'     }],
    beauty:       [{ code: 'salon',          name_en: 'Salon / Beauty', name_hi: 'सैलून',          emoji: '✂️', module_profile: 'salon'    }],
    healthcare:   [{ code: 'clinic',         name_en: 'Clinic',         name_hi: 'क्लिनिक',        emoji: '🏥', module_profile: 'healthcare' }],
    education:    [{ code: 'coaching',       name_en: 'Coaching',       name_hi: 'कोचिंग',         emoji: '🎓', module_profile: 'education' }],
    services:     [{ code: 'handyman',       name_en: 'Service Business',name_hi:'सर्विस',         emoji: '🔧', module_profile: 'services' }],
    wholesale:    [{ code: 'distributor',    name_en: 'Wholesale',      name_hi: 'थोक',           emoji: '📦', module_profile: 'wholesale' }],
    online:       [{ code: 'd2c_brand',      name_en: 'Online Seller',  name_hi: 'ऑनलाइन',        emoji: '🌐', module_profile: 'online' }],
    subscription: [{ code: 'fee_recurring',  name_en: 'Subscription',   name_hi: 'सब्सक्रिप्शन',  emoji: '🔁', module_profile: 'subscription' }],
    property:     [{ code: 'real_estate',    name_en: 'Real Estate',    name_hi: 'रियल एस्टेट',   emoji: '🏠', module_profile: 'property' }],
    hospitality:  [{ code: 'hotel',          name_en: 'Hotel/Lodge',    name_hi: 'होटल',          emoji: '🏨', module_profile: 'hospitality' }],
    specialized:  [{ code: 'wedding_planner',name_en: 'Specialized',    name_hi: 'विशेष',         emoji: '⭐', module_profile: 'services' }]
  };

  // ─────────────────────────────────────────────────────────
  // State
  // ─────────────────────────────────────────────────────────
  let _state = {
    step: 1,
    macroCode: null,
    onSelect: null,
    onSkip: null,
    macros: null,
    bizCache: {}
  };

  // ─────────────────────────────────────────────────────────
  // Data layer
  // ─────────────────────────────────────────────────────────
  async function fetchMacros(){
    if(_state.macros) return _state.macros;
    try {
      if(typeof supabase !== 'undefined' && window.SBP_SUPABASE_URL){
        const sb = supabase.createClient(window.SBP_SUPABASE_URL, window.SBP_SUPABASE_KEY);
        const { data, error } = await sb.rpc('get_macro_categories');
        if(!error && Array.isArray(data) && data.length > 0){
          _state.macros = data;
          return data;
        }
      }
    } catch(e){
      console.warn('[wizard] fetchMacros failed:', e);
    }
    _state.macros = FALLBACK_MACROS;
    return FALLBACK_MACROS;
  }

  async function fetchBizCategories(macroCode){
    if(_state.bizCache[macroCode]) return _state.bizCache[macroCode];
    try {
      if(typeof supabase !== 'undefined' && window.SBP_SUPABASE_URL){
        const sb = supabase.createClient(window.SBP_SUPABASE_URL, window.SBP_SUPABASE_KEY);
        const { data, error } = await sb.rpc('get_business_categories', { p_macro: macroCode });
        if(!error && Array.isArray(data) && data.length > 0){
          _state.bizCache[macroCode] = data;
          return data;
        }
      }
    } catch(e){
      console.warn('[wizard] fetchBizCategories failed:', e);
    }
    const fb = FALLBACK_BIZ_BY_MACRO[macroCode] || [];
    _state.bizCache[macroCode] = fb;
    return fb;
  }

  // ─────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────
  async function open(opts){
    opts = opts || {};
    _state.step = 1;
    _state.macroCode = null;
    _state.onSelect = opts.onSelect || null;
    _state.onSkip = opts.onSkip || null;

    injectStyles();
    _ensureContainer();
    document.getElementById('_sbpw_bg').classList.add('show');
    await renderStep1();
  }

  function close(){
    const el = document.getElementById('_sbpw_bg');
    if(el) el.classList.remove('show');
  }

  function _ensureContainer(){
    if(document.getElementById('_sbpw_bg')) return;
    const wrap = document.createElement('div');
    wrap.id = '_sbpw_bg';
    wrap.className = 'sbpw-bg';
    wrap.innerHTML = `
      <div class="sbpw-modal" id="_sbpw_modal">
        <div class="sbpw-hd">
          <button class="sbpw-back" id="_sbpw_back" onclick="SBPWizard._goBack()">← Back</button>
          <button class="sbpw-skip" id="_sbpw_skip" onclick="SBPWizard._handleSkip()">Skip for now</button>
          <div class="sbpw-step-pip" id="_sbpw_pips">
            <div class="sbpw-pip active"></div>
            <div class="sbpw-pip"></div>
          </div>
          <div class="sbpw-title" id="_sbpw_title">What kind of business?</div>
          <div class="sbpw-sub" id="_sbpw_sub">We'll customize ShopBill Pro for your shop type.</div>
        </div>
        <div class="sbpw-body" id="_sbpw_body">
          <div class="sbpw-loading"><div class="sbpw-loading-spinner"></div><div>Loading…</div></div>
        </div>
      </div>`;
    document.body.appendChild(wrap);
    wrap.addEventListener('click', e => { if(e.target === wrap) close(); });
  }

  // ─────────────────────────────────────────────────────────
  // Step 1 — pick macro category
  // ─────────────────────────────────────────────────────────
  async function renderStep1(){
    _state.step = 1;
    document.getElementById('_sbpw_title').textContent = 'What kind of business?';
    document.getElementById('_sbpw_sub').textContent = "We'll customize ShopBill Pro for your shop type.";
    _setPips(1);
    document.getElementById('_sbpw_back').classList.remove('show');

    const body = document.getElementById('_sbpw_body');
    body.innerHTML = '<div class="sbpw-loading"><div class="sbpw-loading-spinner"></div><div>Loading…</div></div>';

    const macros = await fetchMacros();

    body.innerHTML = `
      <div class="sbpw-grid">
        ${macros.map(m => `
          <div class="sbpw-card" onclick="SBPWizard._pickMacro('${esc(m.code)}')">
            <div class="sbpw-card-emoji">${esc(m.emoji || '⭐')}</div>
            <div class="sbpw-card-name">${esc(m.name_en)}</div>
            ${m.name_hi ? '<div class="sbpw-card-name-hi">'+esc(m.name_hi)+'</div>' : ''}
          </div>
        `).join('')}
      </div>`;
  }

  // ─────────────────────────────────────────────────────────
  // Step 2 — pick specific business type
  // ─────────────────────────────────────────────────────────
  async function renderStep2(macroCode){
    _state.step = 2;
    _state.macroCode = macroCode;

    document.getElementById('_sbpw_title').textContent = 'Which best describes your business?';
    document.getElementById('_sbpw_sub').textContent = 'Pick the closest match — you can change this later in Settings.';
    _setPips(2);
    document.getElementById('_sbpw_back').classList.add('show');

    const body = document.getElementById('_sbpw_body');
    body.innerHTML = '<div class="sbpw-loading"><div class="sbpw-loading-spinner"></div><div>Loading…</div></div>';

    const cats = await fetchBizCategories(macroCode);

    if(!cats || cats.length === 0){
      body.innerHTML = '<div class="sbpw-empty">No types found for this category. Click Skip to continue.</div>';
      return;
    }

    body.innerHTML = `
      <div class="sbpw-grid">
        ${cats.map(c => `
          <div class="sbpw-card" onclick="SBPWizard._pickBiz('${esc(c.code)}')">
            <div class="sbpw-card-emoji">${esc(c.emoji || '🏪')}</div>
            <div class="sbpw-card-name">${esc(c.name_en)}</div>
            ${c.name_hi ? '<div class="sbpw-card-name-hi">'+esc(c.name_hi)+'</div>' : ''}
          </div>
        `).join('')}
      </div>
      <div class="sbpw-other">
        <div style="font-size:13px;font-weight:600;color:#F0EFF8">None of these fit?</div>
        <div style="font-size:11px;color:#8A8AA8;margin-top:4px">Type a short description of your business — we'll save it and follow up.</div>
        <input class="sbpw-other-input" id="_sbpw_other_input" placeholder="e.g. Mobile catering for office events" onkeydown="if(event.key==='Enter') SBPWizard._submitOther()">
        <div style="text-align:right;margin-top:8px"><button onclick="SBPWizard._submitOther()" style="background:rgba(245,166,35,.15);color:#F5A623;border:1px solid rgba(245,166,35,.3);padding:7px 14px;border-radius:8px;font-weight:700;cursor:pointer;font-size:12px">Use this →</button></div>
      </div>`;
  }

  // ─────────────────────────────────────────────────────────
  // Internal handlers
  // ─────────────────────────────────────────────────────────
  function _pickMacro(macroCode){ renderStep2(macroCode); }

  function _pickBiz(catCode){
    if(typeof _state.onSelect === 'function'){
      _state.onSelect(catCode, _state.macroCode);
    }
    close();
  }

  function _submitOther(){
    const inp = document.getElementById('_sbpw_other_input');
    const text = (inp && inp.value || '').trim();
    if(!text){ if(inp) inp.focus(); return; }

    // Stash in localStorage for later follow-up
    try {
      const log = JSON.parse(localStorage.getItem('sbp_other_business_requests') || '[]');
      log.push({ macro: _state.macroCode, text, ts: Date.now() });
      localStorage.setItem('sbp_other_business_requests', JSON.stringify(log));
    } catch(e){}

    const fb = FALLBACK_BIZ_BY_MACRO[_state.macroCode];
    const fallbackCode = (fb && fb[0] && fb[0].code) || 'general_retail';

    if(typeof _state.onSelect === 'function'){
      _state.onSelect(fallbackCode, _state.macroCode, { otherText: text });
    }
    close();
  }

  function _goBack(){
    if(_state.step === 2) renderStep1();
    else close();
  }

  function _handleSkip(){
    if(typeof _state.onSkip === 'function') _state.onSkip();
    close();
  }

  function _setPips(activeIdx){
    const pips = document.getElementById('_sbpw_pips');
    if(!pips) return;
    pips.innerHTML = `
      <div class="sbpw-pip ${activeIdx >= 1 ? (activeIdx > 1 ? 'done' : 'active') : ''}"></div>
      <div class="sbpw-pip ${activeIdx >= 2 ? 'active' : ''}"></div>`;
  }

  function esc(s){
    return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  }

  global.SBPWizard = {
    open, close,
    _pickMacro, _pickBiz, _submitOther, _goBack, _handleSkip
  };

})(window);
