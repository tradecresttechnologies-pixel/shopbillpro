// ════════════════════════════════════════════════════════════════════
// lib/auth-pin.js — Manager PIN modal + verification helper
// Batch 022D-A (11 May 2026)
//
// Exposes a single global: window.SBPAuth
//
// Public API:
//   const { pin, user } = await SBPAuth.requirePIN({
//     action: 'extras.remove',                       // for audit_log action_code
//     detail: 'Remove charge: Lunch ₹699',           // shown to operator
//     reason_hint: 'Why is this being removed?',     // placeholder for reason field
//     bilingual: { en: 'Remove charge', hi: '...'}   // optional override
//   });
//   // → opens modal, waits for operator to enter PIN + optional reason
//   // → calls sbp_verify_pin server-side
//   // → resolves with { pin, reason, user: {user_id, user_name, auth_role} }
//   // → rejects with 'cancelled' if operator dismisses
//   // → rejects with 'invalid_pin' if 3 wrong attempts (modal auto-closes)
//
//   const ok = await SBPAuth.verifyPIN(pin);   // direct verify, returns {ok, user|error}
//
// CALLERS pass the returned `pin` to the high-risk RPC as `p_auth_pin`.
// The server re-verifies the PIN and writes the audit log entry itself.
// (Client-side verify is for UX feedback; server is the source of truth.)
//
// Self-contained: no dependencies beyond the global Supabase client _sb
// and a shop id at window._shopId or localStorage.sbp_shop_id.
// ════════════════════════════════════════════════════════════════════

(function(window){
  'use strict';

  // ── Idempotent loading ────────────────────────────────────────────
  // If the script is loaded multiple times (dev cache-bust, accidental
  // double <script src> includes, etc.), tear down any previous DOM +
  // styles so we don't end up with stacked overlapping modals all
  // animating simultaneously.
  document.querySelectorAll('.sbp-auth-overlay').forEach(e => e.remove());
  document.querySelectorAll('style[data-sbp-auth-pin]').forEach(e => e.remove());

  // ── Resolve dependencies ───────────────────────────────────────────
  function getSb(){ return window._sb || null; }
  function getShopId(){
    return window._shopId || localStorage.getItem('sbp_shop_id') || null;
  }

  // ── Modal DOM (created lazily on first call) ──────────────────────
  let _modalEl = null;
  let _resolve = null;
  let _reject  = null;
  let _attempts = 0;
  const MAX_ATTEMPTS = 3;

  function ensureModal(){
    // Already created in this load
    if(_modalEl && document.body.contains(_modalEl)) return _modalEl;

    // Defensive: if any overlay from a previous load survived cleanup,
    // reuse the first one and wipe any duplicates.
    const existing = document.querySelectorAll('.sbp-auth-overlay');
    if(existing.length > 0){
      // Wipe duplicates beyond the first
      for(let i = 1; i < existing.length; i++) existing[i].remove();
      _modalEl = existing[0];
      return _modalEl;
    }

    const css = `
      .sbp-auth-overlay{position:fixed;inset:0;background:rgba(8,10,18,.72);z-index:99999;display:none;align-items:center;justify-content:center;padding:16px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
      .sbp-auth-overlay.open{display:flex}
      .sbp-auth-sheet{background:var(--surf,#fff);color:var(--text,#0a0e1a);border-radius:18px;width:100%;max-width:380px;box-shadow:0 12px 36px rgba(0,0,0,.35);overflow:hidden}
      .sbp-auth-hd{padding:18px 20px 12px;border-bottom:1px solid var(--bord,#e5e7eb)}
      .sbp-auth-hd .sbp-auth-icon{font-size:24px;line-height:1}
      .sbp-auth-hd .sbp-auth-title{font-size:16px;font-weight:800;margin:6px 0 2px;letter-spacing:-.2px}
      .sbp-auth-hd .sbp-auth-detail{font-size:13px;color:var(--t2,#6b7280);line-height:1.4;font-weight:500}
      .sbp-auth-bd{padding:16px 20px}
      .sbp-auth-pin{width:100%;padding:14px 14px;font-size:22px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:8px;text-align:center;border:2px solid var(--bord,#e5e7eb);border-radius:12px;background:var(--surf2,#f9fafb);color:var(--text,#0a0e1a);font-weight:800;outline:none;caret-color:transparent}
      .sbp-auth-pin:focus{border-color:var(--acc,#f5a623)}
      .sbp-auth-pin::placeholder{letter-spacing:3px;color:var(--t3,#9ca3af);font-weight:600}
      .sbp-auth-reason{width:100%;margin-top:10px;padding:10px 12px;font-size:13px;border:1.5px solid var(--bord,#e5e7eb);border-radius:10px;background:var(--surf2,#f9fafb);color:var(--text,#0a0e1a);font-family:inherit;resize:none;outline:none}
      .sbp-auth-reason:focus{border-color:var(--acc,#f5a623)}
      .sbp-auth-err{color:#dc2626;font-size:12px;font-weight:700;margin-top:8px;min-height:16px;text-align:center}
      .sbp-auth-pad{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:14px}
      .sbp-auth-pad button{padding:14px 0;font-size:18px;font-weight:700;border:1.5px solid var(--bord,#e5e7eb);background:var(--surf2,#f9fafb);color:var(--text,#0a0e1a);border-radius:10px;cursor:pointer;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;transition:all .1s}
      .sbp-auth-pad button:hover{background:var(--surf3,#f3f4f6);border-color:var(--acc,#f5a623)}
      .sbp-auth-pad button:active{transform:scale(.96)}
      .sbp-auth-pad .sbp-auth-back{color:#dc2626;font-size:14px}
      .sbp-auth-ft{padding:12px 20px 18px;display:flex;gap:8px;border-top:1px solid var(--bord,#e5e7eb);background:var(--surf2,#f9fafb)}
      .sbp-auth-ft button{flex:1;padding:12px;font-size:14px;font-weight:700;border-radius:10px;cursor:pointer;border:1.5px solid transparent;transition:all .15s;font-family:inherit}
      .sbp-auth-cancel{background:transparent;color:var(--t2,#6b7280);border-color:var(--bord,#e5e7eb)}
      .sbp-auth-cancel:hover{background:var(--surf3,#f3f4f6);color:var(--text,#0a0e1a)}
      .sbp-auth-submit{background:linear-gradient(135deg,#10b981,#059669);color:#fff}
      .sbp-auth-submit:hover{transform:translateY(-1px);box-shadow:0 4px 12px rgba(16,185,129,.35)}
      .sbp-auth-submit:disabled{opacity:.5;cursor:not-allowed;transform:none;box-shadow:none}
      [data-theme="dark"] .sbp-auth-sheet{background:#0f1419;color:#f3f4f6}
      [data-theme="dark"] .sbp-auth-pin,[data-theme="dark"] .sbp-auth-reason,[data-theme="dark"] .sbp-auth-pad button{background:#1a1f2e;border-color:#2a3142;color:#f3f4f6}
      [data-theme="dark"] .sbp-auth-ft{background:#0a0e1a;border-color:#2a3142}
      [data-theme="dark"] .sbp-auth-cancel{border-color:#2a3142;color:#9ca3af}
    `;
    const style = document.createElement('style');
    style.setAttribute('data-sbp-auth-pin', '1');
    style.textContent = css;
    document.head.appendChild(style);

    const overlay = document.createElement('div');
    overlay.className = 'sbp-auth-overlay';
    overlay.innerHTML = `
      <div class="sbp-auth-sheet" role="dialog" aria-labelledby="sbp-auth-title">
        <div class="sbp-auth-hd">
          <span class="sbp-auth-icon">🔒</span>
          <div class="sbp-auth-title" id="sbp-auth-title">Manager authorization needed</div>
          <div class="sbp-auth-detail" id="sbp-auth-detail">—</div>
        </div>
        <div class="sbp-auth-bd">
          <input class="sbp-auth-pin" id="sbp-auth-pin" type="password" inputmode="numeric" pattern="[0-9]*" maxlength="12" placeholder="Enter PIN" autocomplete="off">
          <textarea class="sbp-auth-reason" id="sbp-auth-reason" rows="2" placeholder="Reason (optional)"></textarea>
          <div class="sbp-auth-err" id="sbp-auth-err"></div>
          <div class="sbp-auth-pad" id="sbp-auth-pad">
            <button type="button" data-d="1">1</button>
            <button type="button" data-d="2">2</button>
            <button type="button" data-d="3">3</button>
            <button type="button" data-d="4">4</button>
            <button type="button" data-d="5">5</button>
            <button type="button" data-d="6">6</button>
            <button type="button" data-d="7">7</button>
            <button type="button" data-d="8">8</button>
            <button type="button" data-d="9">9</button>
            <button type="button" data-d="clear" class="sbp-auth-back">⌫</button>
            <button type="button" data-d="0">0</button>
            <button type="button" data-d="bs" class="sbp-auth-back">←</button>
          </div>
        </div>
        <div class="sbp-auth-ft">
          <button type="button" class="sbp-auth-cancel" id="sbp-auth-cancel">Cancel</button>
          <button type="button" class="sbp-auth-submit" id="sbp-auth-submit">Authorize →</button>
        </div>
      </div>
    `;
    document.body.appendChild(overlay);

    // Wire events
    const pinInput  = overlay.querySelector('#sbp-auth-pin');
    const submitBtn = overlay.querySelector('#sbp-auth-submit');
    const cancelBtn = overlay.querySelector('#sbp-auth-cancel');
    const pad       = overlay.querySelector('#sbp-auth-pad');

    pad.addEventListener('click', (e)=>{
      const btn = e.target.closest('button'); if(!btn) return;
      const d = btn.dataset.d;
      if(d === 'clear'){ pinInput.value = ''; }
      else if(d === 'bs'){ pinInput.value = pinInput.value.slice(0, -1); }
      else { if(pinInput.value.length < 12) pinInput.value += d; }
      pinInput.focus();
    });
    // Prevent keypad button clicks from stealing focus from the PIN
    // input (avoids border-color transition flicker on every press).
    pad.addEventListener('mousedown', (e) => {
      if(e.target.closest('button')) e.preventDefault();
    });

    pinInput.addEventListener('keydown', (e)=>{
      if(e.key === 'Enter'){ e.preventDefault(); submitBtn.click(); }
    });

    submitBtn.addEventListener('click', _submit);
    cancelBtn.addEventListener('click', ()=> _cancel('cancelled'));

    // Click on overlay (not sheet) cancels
    overlay.addEventListener('click', (e)=>{
      if(e.target === overlay) _cancel('cancelled');
    });

    // ESC cancels
    document.addEventListener('keydown', (e)=>{
      if(e.key === 'Escape' && overlay.classList.contains('open')){ _cancel('cancelled'); }
    });

    _modalEl = overlay;
    return overlay;
  }

  function _openModal(opts){
    const overlay = ensureModal();
    const titleEl  = overlay.querySelector('#sbp-auth-title');
    const detailEl = overlay.querySelector('#sbp-auth-detail');
    const pinInput = overlay.querySelector('#sbp-auth-pin');
    const reasonEl = overlay.querySelector('#sbp-auth-reason');
    const errEl    = overlay.querySelector('#sbp-auth-err');

    titleEl.textContent = opts.title || 'Manager authorization needed';
    detailEl.textContent = opts.detail || '—';
    reasonEl.placeholder = opts.reason_hint || 'Reason (optional)';
    pinInput.value = '';
    reasonEl.value = '';
    errEl.textContent = '';
    _attempts = 0;

    overlay.classList.add('open');
    setTimeout(()=> pinInput.focus(), 100);
  }

  function _closeModal(){
    if(_modalEl) _modalEl.classList.remove('open');
  }

  function _cancel(why){
    _closeModal();
    if(_reject){ const r = _reject; _resolve = null; _reject = null; r(new Error(why || 'cancelled')); }
  }

  async function _submit(){
    const overlay = _modalEl; if(!overlay) return;
    const pinInput  = overlay.querySelector('#sbp-auth-pin');
    const reasonEl  = overlay.querySelector('#sbp-auth-reason');
    const errEl     = overlay.querySelector('#sbp-auth-err');
    const submitBtn = overlay.querySelector('#sbp-auth-submit');

    const pin = String(pinInput.value || '').trim();
    if(pin.length < 4){
      errEl.textContent = 'PIN must be at least 4 digits';
      return;
    }

    submitBtn.disabled = true;
    submitBtn.textContent = 'Verifying…';
    errEl.textContent = '';

    try {
      const res = await SBPAuth.verifyPIN(pin);
      if(res && res.ok){
        const reason = String(reasonEl.value || '').trim() || null;
        _closeModal();
        if(_resolve){
          const r = _resolve; _resolve = null; _reject = null;
          r({ pin, reason, user: {
            user_id:       res.user_id,
            user_name:     res.user_name,
            auth_role:     res.auth_role,
            can_authorize: res.can_authorize
          }});
        }
      } else {
        _attempts += 1;
        if(_attempts >= MAX_ATTEMPTS){
          errEl.textContent = `Too many wrong attempts. Closing.`;
          setTimeout(()=> _cancel('too_many_attempts'), 1200);
        } else {
          errEl.textContent = `Invalid PIN (${_attempts}/${MAX_ATTEMPTS})`;
          pinInput.value = '';
          pinInput.focus();
        }
      }
    } catch(e){
      errEl.textContent = 'Network error — try again';
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = 'Authorize →';
    }
  }

  // ── Public API ─────────────────────────────────────────────────────

  const SBPAuth = {
    /**
     * Open the PIN modal and resolve when authorized.
     * @param {Object} opts
     * @param {string} opts.action       — action_code for audit log (e.g. 'extras.remove')
     * @param {string} opts.detail       — short description shown to operator
     * @param {string} [opts.title]      — modal title (default: 'Manager authorization needed')
     * @param {string} [opts.reason_hint]— placeholder for reason field
     * @returns {Promise<{pin:string, reason:string|null, user:Object}>}
     */
    requirePIN(opts){
      return new Promise((resolve, reject)=>{
        _resolve = resolve;
        _reject  = reject;
        _openModal(opts || {});
      });
    },

    /**
     * Direct PIN verification (used by requirePIN internally, but
     * exposed for callers that want to verify without opening a modal).
     * @param {string} pin
     * @returns {Promise<{ok:boolean, user_id?, user_name?, auth_role?, can_authorize?, error?}>}
     */
    async verifyPIN(pin){
      const sb = getSb();
      const shopId = getShopId();
      if(!sb)     return { ok: false, error: 'no_supabase_client' };
      if(!shopId) return { ok: false, error: 'no_shop_id' };
      try {
        const { data, error } = await sb.rpc('sbp_verify_pin', {
          p_shop_id: shopId,
          p_pin:     String(pin || '')
        });
        if(error) return { ok: false, error: error.message || 'rpc_error' };
        return data || { ok: false, error: 'no_data' };
      } catch(e){
        return { ok: false, error: e.message || 'exception' };
      }
    },

    /** Programmatically dismiss any open PIN modal. */
    dismiss(){ _cancel('dismissed_programmatically'); }
  };

  window.SBPAuth = SBPAuth;

})(window);
