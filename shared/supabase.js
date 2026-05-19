/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Supabase Client
   TradeCrest Technologies Pvt. Ltd.
   Project: jfqeirfrkjdkqqixivru | Region: ap-southeast-1 (Singapore)
══════════════════════════════════════════════════════════════════ */

const SB_URL = 'https://jfqeirfrkjdkqqixivru.supabase.co';
const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpmcWVpcmZya2pka3FxaXhpdnJ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzQ4MzgsImV4cCI6MjA4OTk1MDgzOH0.akd4E0nil8ypLR4WOykkeYIL8g4uuNU6XdSVh_Y1utk';

// Initialize Supabase client
const _sb = supabase.createClient(SB_URL, SB_KEY, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false
  },
  realtime: { params: { eventsPerSecond: 10 } }
});

/* ── Global State ── */
window.SBP = window.SBP || {};
window.SBP.user     = null;   // Supabase auth user
window.SBP.shopId   = null;   // Shop UUID
window.SBP.shop     = null;   // Shop settings object
window.SBP.role     = 'Admin';
window.SBP.ready    = false;
window.SBP.online   = navigator.onLine;

/* ── Online / Offline Detection ── */
window.addEventListener('online',  () => {
  window.SBP.online = true;
  _updateOfflineBar();
  // Process any queued offline changes
  if (window.SyncEngine) SyncEngine.processQueue();
});

window.addEventListener('offline', () => {
  window.SBP.online = false;
  _updateOfflineBar();
});

function _updateOfflineBar() {
  const bar = document.getElementById('offline-bar');
  if (!bar) return;
  if (!window.SBP.online) {
    bar.textContent = '📶 Offline — bills save locally, will sync when connected';
    bar.className = 'offline';
  } else {
    bar.className = '';
  }
}

/* ── Auth State Listener ── */
_sb.auth.onAuthStateChange((event, session) => {
  if (session) {
    window.SBP.user = session.user;
  } else {
    window.SBP.user   = null;
    window.SBP.shopId = null;
    window.SBP.shop   = null;
    window.SBP.ready  = false;
  }
  // Notify any listeners
  if (window._authStateCallbacks) {
    window._authStateCallbacks.forEach(fn => fn(event, session));
  }
});

window._authStateCallbacks = [];
function onAuthChange(fn) {
  window._authStateCallbacks.push(fn);
}

/* ── Exported helper ── */
window._sb = _sb;

/* ── Plan Helper ── */
function isPro() {
  const shop = JSON.parse(localStorage.getItem('sbp_shop') || '{}');
  const plan = shop.plan || 'free';
  return plan === 'pro' || plan === 'enterprise';
}
window.isPro = isPro;

/* ── Language Helper ── */
function currentLang() { return localStorage.getItem('sbp_lang') || 'en'; }
window.currentLang = currentLang;

/* ── Shop Helper ── */
function currentShopId() { return localStorage.getItem('sbp_shop_id') || window.SBP?.shopId; }
window.currentShopId = currentShopId;
