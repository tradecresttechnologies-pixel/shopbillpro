/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Upgrade Popup System v1.0
   TradeCrest Technologies Pvt. Ltd.
   
   Triggers:
   1. After 10 bills  → soft nudge (informational)
   2. After 50 bills  → hard gate (block + upgrade)
   3. WhatsApp send   → wa_nudge (feature gate)
   4. Settings page   → trust message (passive)
   
   Usage:
     SBPUpgrade.check('bill_saved');   // after saving a bill
     SBPUpgrade.check('whatsapp');     // before WhatsApp send
     SBPUpgrade.check('settings');     // on settings page load
     SBPUpgrade.showUpgrade('manual'); // open directly
══════════════════════════════════════════════════════════════════ */

window.SBPUpgrade = (function () {

  /* ── Config ── */
  const SOFT_LIMIT = 10;
  const HARD_LIMIT = 50;
  const DISMISS_SOFT_KEY = 'sbp_upgrade_soft_dismissed';   // timestamp
  const DISMISS_SOFT_COOLDOWN = 3 * 24 * 60 * 60 * 1000;  // 3 days

  /* ── Bill Count ── */
  function getBillCount() {
    try {
      const bills = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
      return bills.length;
    } catch { return 0; }
  }

  /* ── Plan Check ── */
  function isPro() {
    try {
      // BATCH 1B-E: read from sbp_shop (canonical source) instead of broken sbp_plan key.
      // Recognize active beta and business plans as "pro" for upsell-suppression purposes.
      const s = JSON.parse(localStorage.getItem('sbp_shop') || '{}');

      // Active beta signup (within active or grace window) → full features → no upsells
      if (s.is_beta_signup === true) {
        const now = new Date();
        const expires = s.plan_expires_at ? new Date(s.plan_expires_at) : null;
        const grace   = s.beta_grace_until ? new Date(s.beta_grace_until) : null;
        if (expires && expires > now) return true;
        if (grace && grace > now) return true;
      }

      // Paid plans
      return s.plan === 'pro' || s.plan === 'enterprise' || s.plan === 'business';
    } catch { return false; }
  }

  /* ── Inject CSS once ── */
  let _cssInjected = false;
  function injectCSS() {
    if (_cssInjected) return;
    _cssInjected = true;
    const style = document.createElement('style');
    style.textContent = `
.sbp-up-overlay{position:fixed;inset:0;background:rgba(0,0,0,.72);z-index:99999;display:flex;align-items:flex-end;justify-content:center;opacity:0;transition:opacity .25s ease;pointer-events:none}
.sbp-up-overlay.open{opacity:1;pointer-events:all}
.sbp-up-sheet{background:var(--surf,#13131C);border-radius:24px 24px 0 0;padding:0 0 max(16px,env(safe-area-inset-bottom));width:100%;max-width:480px;transform:translateY(100%);transition:transform .3s cubic-bezier(.4,0,.2,1)}
.sbp-up-overlay.open .sbp-up-sheet{transform:translateY(0)}
.sbp-up-handle{width:36px;height:4px;background:var(--bord,#2A2A3A);border-radius:2px;margin:12px auto 0}
.sbp-up-body{padding:20px 20px 8px}
.sbp-up-badge{display:inline-flex;align-items:center;gap:6px;background:linear-gradient(135deg,rgba(245,166,35,.2),rgba(255,138,0,.15));border:1px solid rgba(245,166,35,.4);border-radius:100px;padding:5px 12px;font-size:11px;font-weight:700;color:#FF8A00;letter-spacing:.5px;margin-bottom:14px}
.sbp-up-emoji{font-size:40px;margin-bottom:10px;display:block}
.sbp-up-title{font-family:var(--font-h,'Outfit'),sans-serif;font-size:21px;font-weight:800;color:var(--text,#F0EFF8);line-height:1.2;margin-bottom:8px}
.sbp-up-sub{font-size:13px;color:var(--t2,#8A8AA8);line-height:1.6;margin-bottom:18px}
.sbp-up-perks{display:flex;flex-direction:column;gap:8px;margin-bottom:20px}
.sbp-up-perk{display:flex;align-items:center;gap:10px;font-size:13px;color:var(--text,#F0EFF8)}
.sbp-up-perk-dot{width:20px;height:20px;border-radius:50%;background:rgba(245,166,35,.2);display:flex;align-items:center;justify-content:center;font-size:10px;flex-shrink:0}
.sbp-up-price{background:var(--surf2,#1C1C28);border:1px solid var(--bord,#2A2A3A);border-radius:14px;padding:14px;margin-bottom:16px;display:flex;align-items:center;justify-content:space-between}
.sbp-up-price-main{font-family:var(--font-h,'Outfit'),sans-serif;font-size:28px;font-weight:900;color:var(--text,#F0EFF8)}
.sbp-up-price-per{font-size:11px;color:var(--t2,#8A8AA8);margin-top:2px}
.sbp-up-price-tag{background:rgba(16,185,129,.15);border:1px solid rgba(16,185,129,.3);border-radius:8px;padding:4px 10px;font-size:11px;font-weight:700;color:#10B981}
.sbp-up-btn-pri{width:100%;padding:15px;border-radius:14px;background:linear-gradient(135deg,#F5A623,#FF8A00);border:none;color:#0A0E1A;font-family:var(--font-h,'Outfit'),sans-serif;font-size:16px;font-weight:800;cursor:pointer;margin-bottom:8px;letter-spacing:.3px}
.sbp-up-btn-sec{width:100%;padding:12px;border-radius:12px;background:transparent;border:1px solid var(--bord,#2A2A3A);color:var(--t2,#8A8AA8);font-size:14px;cursor:pointer}
.sbp-up-trust{text-align:center;font-size:11px;color:var(--t2,#8A8AA8);padding:10px 0 0}
@media(min-width:600px){.sbp-up-sheet{border-radius:20px;margin-bottom:40px;max-width:400px}}
    `;
    document.head.appendChild(style);
  }

  /* ── Build popup HTML ── */
  function buildHTML(config) {
    const { badge, emoji, title, sub, perks, price, cta, dismissLabel, trust, blockDismiss } = config;
    return `
<div class="sbp-up-overlay" id="sbp-up-overlay" onclick="SBPUpgrade._onOverlayClick(event)">
  <div class="sbp-up-sheet">
    <div class="sbp-up-handle"></div>
    <div class="sbp-up-body">
      <div class="sbp-up-badge">⚡ ${badge}</div>
      <span class="sbp-up-emoji">${emoji}</span>
      <div class="sbp-up-title">${title}</div>
      <div class="sbp-up-sub">${sub}</div>
      <div class="sbp-up-perks">
        ${perks.map(p => `<div class="sbp-up-perk"><div class="sbp-up-perk-dot">✓</div><span>${p}</span></div>`).join('')}
      </div>
      <div class="sbp-up-price">
        <div>
          <div class="sbp-up-price-main">₹${price}/mo</div>
          <div class="sbp-up-price-per">per mahina · cancel anytime</div>
        </div>
        <div class="sbp-up-price-tag">7-day FREE trial</div>
      </div>
      <button class="sbp-up-btn-pri" onclick="SBPUpgrade._goUpgrade()">🚀 ${cta}</button>
      ${!blockDismiss ? `<button class="sbp-up-btn-sec" onclick="SBPUpgrade.close('dismissed')">${dismissLabel || 'Abhi nahi'}</button>` : `<button class="sbp-up-btn-sec" onclick="SBPUpgrade._goUpgrade()">Plans dekhein →</button>`}
      <div class="sbp-up-trust">${trust}</div>
    </div>
  </div>
</div>`;
  }

  /* ── Popup Configs (Hinglish) ── */
  const CONFIGS = {

    soft: {
      badge: 'ShopBill Pro+',
      emoji: '🎉',
      title: '10 bills ho gaye!\nAb upgrade karein?',
      sub: 'Aapne 10 bills bana liye — bahut achha! Pro plan mein unlimited bills, cloud backup, aur WhatsApp automation milega.',
      perks: [
        'Unlimited bills — koi limit nahi',
        'Cloud backup — data kabhi nahi jayega',
        'WhatsApp pe auto bill bhejo',
        'Staff login add kar sako',
      ],
      price: 99,
      cta: 'Pro Plan Try Karein — Free!',
      dismissLabel: 'Baad mein dekhenge',
      trust: '🔒 No credit card needed · Cancel kabhi bhi',
      blockDismiss: false,
    },

    hard: {
      badge: 'Free Limit Reached',
      emoji: '🚫',
      title: '50 bills ho gaye!\nFree limit khatam.',
      sub: 'Free plan mein sirf 50 bills milte hain. Aapka business badh raha hai — Pro plan mein upgrade karo aur unlimited bills banao!',
      perks: [
        'Unlimited bills — ab koi rokne wala nahi',
        'Cloud backup — data safe rahega',
        'GST reports & export',
        'Priority support',
      ],
      price: 99,
      cta: 'Abhi Upgrade Karein ₹99/mo',
      dismissLabel: '',
      trust: '✅ 7-day free trial · Pasand na aaye toh cancel karo',
      blockDismiss: true,
    },

    whatsapp: {
      badge: 'Pro Feature',
      emoji: '📲',
      title: 'WhatsApp pe seedha bhejo!',
      sub: 'Pro plan mein customer ko directly WhatsApp bill bhej sakte ho — manually copy-paste nahi karna padega.',
      perks: [
        'Auto WhatsApp bill — ek click mein',
        'Payment reminder auto-send',
        'Customer ko branded message',
        'Delivery confirmation',
      ],
      price: 99,
      cta: 'Pro Unlock Karein',
      dismissLabel: 'Manual bhejenge filhaal',
      trust: '📱 1000+ shopkeepers already use this',
      blockDismiss: false,
    },

    settings: {
      badge: 'Your Data is Safe',
      emoji: '☁️',
      title: 'Data ka full backup chahiye?',
      sub: 'Free plan mein data sirf aapke phone mein hai. Pro plan mein cloud backup milega — phone kho jaaye toh bhi data safe!',
      perks: [
        'Cloud backup automatic',
        'Kisi bhi device se login karo',
        'Data export (Excel / PDF)',
        '₹5 crore+ billing already done by Pro users',
      ],
      price: 99,
      cta: 'Cloud Backup Enable Karein',
      dismissLabel: 'Free plan theek hai abhi',
      trust: '🔐 Bank-level encryption · Made in India',
      blockDismiss: false,
    },

  };

  /* ── Show popup ── */
  let _currentTrigger = null;

  function show(trigger) {
    if (isPro()) return;
    injectCSS();

    const config = CONFIGS[trigger] || CONFIGS.soft;
    _currentTrigger = trigger;

    // Remove existing
    const existing = document.getElementById('sbp-up-overlay');
    if (existing) existing.remove();

    // Inject
    document.body.insertAdjacentHTML('beforeend', buildHTML(config));

    // Animate in
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const el = document.getElementById('sbp-up-overlay');
        if (el) el.classList.add('open');
      });
    });
  }

  /* ── Check trigger ── */
  function check(trigger) {
    if (isPro()) return false;

    if (trigger === 'bill_saved') {
      const count = getBillCount();
      if (count >= HARD_LIMIT) {
        show('hard');
        return true; // block
      }
      if (count >= SOFT_LIMIT) {
        const dismissed = parseInt(localStorage.getItem(DISMISS_SOFT_KEY) || '0');
        if (Date.now() - dismissed > DISMISS_SOFT_COOLDOWN) {
          show('soft');
        }
      }
      return false;
    }

    if (trigger === 'whatsapp') {
      // Only show once per session
      if (sessionStorage.getItem('sbp_wa_nudge_shown')) return false;
      sessionStorage.setItem('sbp_wa_nudge_shown', '1');
      show('whatsapp');
      return false; // don't block, just nudge
    }

    if (trigger === 'settings') {
      // Passive — show once per day
      const last = parseInt(localStorage.getItem('sbp_settings_nudge') || '0');
      if (Date.now() - last > 24 * 60 * 60 * 1000) {
        localStorage.setItem('sbp_settings_nudge', Date.now().toString());
        setTimeout(() => show('settings'), 1500); // delay so page loads first
      }
      return false;
    }

    return false;
  }

  /* ── Close ── */
  function close(reason) {
    const el = document.getElementById('sbp-up-overlay');
    if (!el) return;
    el.classList.remove('open');
    setTimeout(() => el.remove(), 300);

    if (reason === 'dismissed' && _currentTrigger === 'soft') {
      localStorage.setItem(DISMISS_SOFT_KEY, Date.now().toString());
    }
    _currentTrigger = null;
  }

  /* ── Overlay click (dismiss on backdrop) ── */
  function _onOverlayClick(e) {
    if (e.target.id === 'sbp-up-overlay') {
      const config = CONFIGS[_currentTrigger];
      if (config && !config.blockDismiss) close('dismissed');
    }
  }

  /* ── Go to upgrade page ── */
  function _goUpgrade() {
    close();
    window.location.href = 'subscription.html';
  }

  /* ── Public API ── */
  return { check, show, close, _goUpgrade, _onOverlayClick };

})();
