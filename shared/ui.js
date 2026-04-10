/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — UI Utilities
   Handles: toast, modal, navigation, theme, language, helpers
══════════════════════════════════════════════════════════════════ */

const UI = (() => {

  /* ── Toast Notifications ── */
  function toast(msg, type = 'default', duration = 3000) {
    let container = document.getElementById('toast-container');
    if (!container) {
      container = document.createElement('div');
      container.id = 'toast-container';
      document.body.appendChild(container);
    }
    const t = document.createElement('div');
    t.className = 'toast' + (type !== 'default' ? ' ' + type : '');
    t.textContent = msg;
    container.appendChild(t);
    setTimeout(() => {
      t.style.opacity = '0';
      t.style.transform = 'translateY(10px) scale(.95)';
      t.style.transition = '.2s ease';
      setTimeout(() => t.remove(), 220);
    }, duration);
  }

  /* ── Modals ── */
  function openModal(id) {
    const el = document.getElementById(id);
    if (!el) return;
    el.classList.add('open');
    el.style.display = 'flex';
    document.body.style.overflow = 'hidden';

    // Close on backdrop click
    el.addEventListener('click', (e) => {
      if (e.target === el) closeModal(id);
    }, { once: true });
  }

  function closeModal(id) {
    const el = document.getElementById(id);
    if (!el) return;
    el.classList.remove('open');
    el.style.display = 'none';
    document.body.style.overflow = '';
  }

  function closeAllModals() {
    document.querySelectorAll('.overlay.open').forEach(el => {
      el.classList.remove('open');
      el.style.display = 'none';
    });
    document.body.style.overflow = '';
  }

  // Close on Escape key
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeAllModals();
  });

  /* ── Theme ── */
  let _theme = localStorage.getItem('sbp_theme') || 'dark';

  function applyTheme(theme) {
    _theme = theme;
    document.documentElement.setAttribute('data-theme', theme === 'light' ? 'light' : '');
    localStorage.setItem('sbp_theme', theme);
    const btn = document.getElementById('theme-toggle-btn');
    if (btn) btn.textContent = theme === 'light' ? '🌙' : '☀️';
  }

  function toggleTheme() {
    applyTheme(_theme === 'dark' ? 'light' : 'dark');
    toast(_theme === 'light' ? '☀️ Light Mode' : '🌙 Dark Mode');
  }

  function initTheme() { applyTheme(_theme); }

  /* ── Language ── */
  const LANGS = {
    en: {
      'app_name': 'ShopBill Pro',
      'tagline': 'Smart Billing for Every Shop',
      'login': 'Login',
      'signup': 'Create Account',
      'email': 'Email Address',
      'password': 'Password',
      'name': 'Full Name',
      'shop_name': 'Shop Name',
      'new_bill': 'New Bill',
      'pos_mode': 'POS Mode',
      'customers': 'Customers',
      'bills': 'Bills',
      'home': 'Home',
      'more': 'More',
      'save': 'Save',
      'cancel': 'Cancel',
      'delete': 'Delete',
      'edit': 'Edit',
      'search': 'Search',
      'add': 'Add',
      'loading': 'Loading...',
      'no_data': 'No data yet',
      'grand_total': 'Grand Total',
      'subtotal': 'Subtotal',
      'discount': 'Discount',
      'gst': 'GST',
      'paid': 'Paid',
      'pending': 'Pending',
      'overdue': 'Overdue',
      'cash': 'Cash',
      'upi': 'UPI / QR',
      'credit': 'Credit',
      'todays_sales': "Today's Sales",
      'outstanding': 'Outstanding',
      'total_bills': 'Total Bills',
      'gst_payable': 'GST Payable',
      'logout': 'Logout',
      'settings': 'Settings',
      'reports': 'Reports',
      'ledger': 'Ledger',
      'inventory': 'Inventory',
      'supplier': 'Suppliers',
      'stock_in': 'Stock IN',
      'stock_out': 'Stock OUT',
      'pos_admin': 'POS Admin',
      'wa_center': 'WhatsApp',
      'cash_register': 'Cash Register',
      'recurring': 'Recurring Bills',
      'bill_templates': 'Bill Templates',
      'in_stock': 'In Stock',
      'low_stock': 'Low Stock',
      'out_of_stock': 'Out of Stock',
      'free_plan': 'Free Plan',
      'pro_plan': 'Pro Plan',
      'upgrade': 'Upgrade to Pro',
      'scan_barcode': 'Scan Barcode',
      'add_photo': 'Add Photo',
    },
    hi: {
      'app_name': 'ShopBill Pro',
      'tagline': 'हर दुकान के लिए स्मार्ट बिलिंग',
      'login': 'लॉगिन',
      'signup': 'खाता बनाएं',
      'email': 'ईमेल पता',
      'password': 'पासवर्ड',
      'name': 'पूरा नाम',
      'shop_name': 'दुकान का नाम',
      'new_bill': 'नया बिल',
      'pos_mode': 'POS मोड',
      'customers': 'ग्राहक',
      'bills': 'बिल',
      'home': 'होम',
      'more': 'और',
      'save': 'सेव',
      'cancel': 'रद्द',
      'delete': 'हटाएं',
      'edit': 'बदलें',
      'search': 'खोजें',
      'add': 'जोड़ें',
      'loading': 'लोड हो रहा है...',
      'no_data': 'अभी कोई डेटा नहीं',
      'grand_total': 'कुल रकम',
      'subtotal': 'उप-कुल',
      'discount': 'छूट',
      'gst': 'GST',
      'paid': 'भुगतान',
      'pending': 'बाकी',
      'overdue': 'समय सीमा पार',
      'cash': 'नकद',
      'upi': 'UPI / QR',
      'credit': 'उधार',
      'todays_sales': 'आज की बिक्री',
      'outstanding': 'बकाया',
      'total_bills': 'कुल बिल',
      'gst_payable': 'GST देय',
      'logout': 'लॉग आउट',
      'settings': 'सेटिंग',
      'reports': 'रिपोर्ट',
      'ledger': 'खाता',
      'inventory': 'इन्वेंटरी',
      'supplier': 'आपूर्तिकर्ता',
      'stock_in': 'स्टॉक IN',
      'stock_out': 'स्टॉक OUT',
      'pos_admin': 'POS प्रशासन',
      'wa_center': 'व्हाट्सएप',
      'cash_register': 'कैश रजिस्टर',
      'recurring': 'नियमित बिल',
      'bill_templates': 'बिल टेम्पलेट',
      'in_stock': 'स्टॉक उपलब्ध',
      'low_stock': 'कम स्टॉक',
      'out_of_stock': 'स्टॉक खत्म',
      'free_plan': 'मुफ्त प्लान',
      'pro_plan': 'प्रो प्लान',
      'upgrade': 'प्रो में अपग्रेड करें',
      'scan_barcode': 'बारकोड स्कैन करें',
      'add_photo': 'फोटो जोड़ें',
    }
  };

  let _lang = localStorage.getItem('sbp_lang') || 'en';

  function t(key) { return LANGS[_lang]?.[key] || LANGS['en'][key] || key; }

  function setLang(lang) {
    _lang = lang;
    localStorage.setItem('sbp_lang', lang);
    // Update all data-i18n elements
    document.querySelectorAll('[data-i18n]').forEach(el => {
      const key = el.getAttribute('data-i18n');
      if (LANGS[lang]?.[key]) el.textContent = LANGS[lang][key];
    });
    // Update placeholders
    document.querySelectorAll('[data-i18n-ph]').forEach(el => {
      const key = el.getAttribute('data-i18n-ph');
      if (LANGS[lang]?.[key]) el.placeholder = LANGS[lang][key];
    });
    toast(lang === 'hi' ? '🇮🇳 हिंदी चुनी गई' : '🇬🇧 English selected');
  }

  function applyLang() { setLang(_lang); }
  function getLang()   { return _lang; }

  /* ── Formatting Helpers ── */
  function formatINR(amount) {
    const n = parseFloat(amount) || 0;
    return '₹' + n.toLocaleString('en-IN', { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  }

  function formatDate(dateStr) {
    if (!dateStr) return '—';
    try {
      return new Date(dateStr).toLocaleDateString('en-IN', {
        day: '2-digit', month: 'short', year: 'numeric'
      });
    } catch { return dateStr; }
  }

  function formatDateShort(dateStr) {
    if (!dateStr) return '—';
    try {
      return new Date(dateStr).toLocaleDateString('en-IN', {
        day: '2-digit', month: 'short'
      });
    } catch { return dateStr; }
  }

  function todayISO() { return new Date().toISOString().split('T')[0]; }

  function todayDisplay() {
    return new Date().toLocaleDateString('en-IN', {
      weekday: 'long', day: 'numeric', month: 'short', year: 'numeric'
    });
  }

  function futureDateISO(days = 15) {
    const d = new Date();
    d.setDate(d.getDate() + days);
    return d.toISOString().split('T')[0];
  }

  function timeGreeting() {
    const h = new Date().getHours();
    if (h < 12) return 'Good Morning';
    if (h < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  function initials(name = '') {
    return name.split(' ').map(w => w[0] || '').join('').substring(0, 2).toUpperCase() || '??';
  }

  function avatarColor(id) {
    const colors = ['#F5A623','#2563EB','#059669','#D97706','#DC2626','#F5A623','#0891B2','#65A30D'];
    const idx = typeof id === 'string' ? id.charCodeAt(0) % colors.length : (id || 0) % colors.length;
    return colors[idx];
  }

  /* ── Loading States ── */
  function showLoader(el, msg = 'Loading...') {
    if (typeof el === 'string') el = document.getElementById(el);
    if (!el) return;
    el.innerHTML = `<div class="loader"><div class="spinner"></div><div style="font-size:13px;color:var(--t2)">${msg}</div></div>`;
  }

  function showEmpty(el, icon = '📭', title = 'Nothing here yet', subtitle = '') {
    if (typeof el === 'string') el = document.getElementById(el);
    if (!el) return;
    el.innerHTML = `
      <div class="empty-state">
        <div class="es-ic">${icon}</div>
        <div class="es-t">${title}</div>
        ${subtitle ? `<div class="es-s">${subtitle}</div>` : ''}
      </div>`;
  }

  /* ── Confirm Dialog ── */
  function confirm(msg, onYes, onNo) {
    let modal = document.getElementById('confirm-modal');
    if (!modal) {
      modal = document.createElement('div');
      modal.id = 'confirm-modal';
      modal.className = 'overlay';
      modal.innerHTML = `
        <div class="sheet sheet-center" style="max-width:320px;margin:auto auto">
          <div class="sheet-title" id="confirm-title">Confirm</div>
          <p id="confirm-msg" style="font-size:14px;color:var(--t2);margin-bottom:18px;line-height:1.6"></p>
          <div class="btn-row col2">
            <button class="btn-sec" id="confirm-no">Cancel</button>
            <button class="btn-danger" id="confirm-yes">Confirm</button>
          </div>
        </div>`;
      document.body.appendChild(modal);
    }
    document.getElementById('confirm-msg').textContent = msg;
    document.getElementById('confirm-yes').onclick = () => { closeModal('confirm-modal'); onYes && onYes(); };
    document.getElementById('confirm-no').onclick  = () => { closeModal('confirm-modal'); onNo && onNo(); };
    openModal('confirm-modal');
  }

  /* ── Navigation (cross-page) ── */
  function navigateTo(page) {
    // Update active nav item
    document.querySelectorAll('.ni').forEach(n => n.classList.remove('on'));
    const active = document.querySelector(`.ni[data-page="${page}"]`);
    if (active) active.classList.add('on');
    // Navigate
    window.location.href = '/' + page + '.html';
  }

  /* ── Copy to clipboard ── */
  async function copyText(text, msg = 'Copied!') {
    try {
      await navigator.clipboard.writeText(text);
      toast('✅ ' + msg, 'success');
    } catch {
      toast('Could not copy', 'error');
    }
  }

  /* ── WhatsApp ── */
  function openWhatsApp(phone, message) {
    const num = (phone || '').replace(/\D/g, '');
    if (!num || num.length < 10) { toast('Invalid WhatsApp number', 'error'); return; }
    const prefix = num.startsWith('91') ? '' : '91';
    window.open('https://wa.me/' + prefix + num + (message ? '?text=' + encodeURIComponent(message) : ''), '_blank');
  }

  /* ── Init ── */
  function init() {
    initTheme();
    applyLang();

    // Offline bar
    if (!navigator.onLine) {
      const bar = document.getElementById('offline-bar');
      if (bar) { bar.textContent = '📶 Offline mode — data saved locally'; bar.className = 'offline'; }
    }
  }

  /* ── Public API ── */
  return {
    toast, openModal, closeModal, closeAllModals,
    toggleTheme, initTheme, applyTheme,
    t, setLang, applyLang, getLang,
    formatINR, formatDate, formatDateShort,
    todayISO, todayDisplay, futureDateISO, timeGreeting,
    initials, avatarColor,
    showLoader, showEmpty, confirm,
    navigateTo, copyText, openWhatsApp, init
  };

})();

window.UI = UI;
