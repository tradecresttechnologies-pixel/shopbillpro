/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Auth Module
   Handles: login, signup, logout, session timeout, auto-login
══════════════════════════════════════════════════════════════════ */

const Auth = (() => {

  /* ── Session Timeout ── */
  let _sessionTimeout  = parseInt(localStorage.getItem('sbp_session_timeout') || '30');
  let _sessionTimer    = null;
  let _warnTimer       = null;
  let _lastActivity    = Date.now();

  function _resetTimer() {
    _lastActivity = Date.now();
    localStorage.setItem('sbp_last_activity', _lastActivity.toString());
    clearTimeout(_sessionTimer);
    clearTimeout(_warnTimer);
    if (!document.body.classList.contains('logged-in')) return;

    const ms     = _sessionTimeout * 60 * 1000;
    const warnMs = Math.max(0, ms - 60000);

    if (warnMs > 0) {
      _warnTimer = setTimeout(_showWarning, warnMs);
    }
    _sessionTimer = setTimeout(_autoLogout, ms);
  }

  function _showWarning() {
    let w = document.getElementById('session-warning-toast');
    if (w) w.remove();
    w = document.createElement('div');
    w.id = 'session-warning-toast';
    w.style.cssText = `
      position:fixed;bottom:90px;left:50%;transform:translateX(-50%);
      background:rgba(239,68,68,.95);color:#fff;padding:12px 20px;
      border-radius:12px;font-size:13px;font-weight:700;z-index:9999;
      text-align:center;box-shadow:0 4px 20px rgba(0,0,0,.4);
      max-width:300px;border:1px solid rgba(255,255,255,.2);
    `;
    w.innerHTML = `
      ⚠️ You'll be logged out in 60s<br>
      <button onclick="Auth.keepAlive()" style="
        margin-top:8px;background:rgba(255,255,255,.2);border:1px solid rgba(255,255,255,.3);
        color:#fff;padding:5px 14px;border-radius:8px;font-weight:700;cursor:pointer;font-size:12px;
      ">Stay Logged In</button>
    `;
    document.body.appendChild(w);
    setTimeout(() => w?.remove(), 58000);
  }

  async function _autoLogout() {
    if (!document.body.classList.contains('logged-in')) return;
    UI.toast('🔒 Auto logged out due to inactivity', 'info');
    await logout();
  }

  function _startActivityTracking() {
    ['click','touchstart','keypress','scroll','mousemove'].forEach(e => {
      document.addEventListener(e, _resetTimer, { passive: true });
    });

    // Check on page focus (returning from background)
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden && document.body.classList.contains('logged-in')) {
        const last    = parseInt(localStorage.getItem('sbp_last_activity') || Date.now().toString());
        const elapsed = (Date.now() - last) / 1000 / 60;
        if (elapsed > _sessionTimeout) {
          _autoLogout();
        } else {
          _resetTimer();
        }
      }
    });
  }

  /* ── Login ── */
  async function login(email, password) {
    if (!email || !password) { UI.toast('Enter email and password', 'error'); return false; }

    // Normalize — allow phone-style login
    const emailFmt = email.includes('@') ? email : email + '@shopbillpro.app';

    try {
      const { data, error } = await _sb.auth.signInWithPassword({
        email: emailFmt,
        password
      });

      if (error) {
        const msg = error.message === 'Invalid login credentials'
          ? 'Wrong email or password'
          : error.message;
        UI.toast('❌ ' + msg, 'error');
        return false;
      }

      window.SBP.user = data.user;
      await _loadShop();
      _resetTimer();
      _startActivityTracking();
      return true;

    } catch (err) {
      UI.toast('❌ Login failed: ' + err.message, 'error');
      return false;
    }
  }

  /* ── Signup ── */
  async function signup({ name, email, phone, shop, password, role = 'Admin' }) {
    if (!name || !email || !shop || !password) {
      UI.toast('Please fill all required fields', 'error');
      return false;
    }
    if (password.length < 6) {
      UI.toast('Password must be at least 6 characters', 'error');
      return false;
    }

    const emailFmt = email.includes('@') ? email : email + '@shopbillpro.app';

    try {
      const { data, error } = await _sb.auth.signUp({
        email: emailFmt,
        password,
        options: {
          data: { name, shop, role, phone }
        }
      });

      if (error) { UI.toast('❌ ' + error.message, 'error'); return false; }

      window.SBP.user = data.user;

      // Create shop record
      const { data: shopRow, error: shopErr } = await _sb.from('shops').insert({
        owner_id:        data.user.id,
        name:            shop,
        owner_name:      name,
        phone:           phone || '',
        email:           emailFmt,
        invoice_prefix:  'INV',
        invoice_counter: 1
      }).select().single();

      if (shopErr) {
        UI.toast('❌ Account created but shop setup failed. Please login again.', 'error');
        return false;
      }

      window.SBP.shopId = shopRow.id;
      window.SBP.shop   = shopRow;
      window.SBP.role   = role;
      window.SBP.ready  = true;

      // Save shop settings to localStorage for offline
      localStorage.setItem('sbp_shop', JSON.stringify(shopRow));

      _resetTimer();
      _startActivityTracking();
      UI.toast('✅ Welcome to ShopBill Pro, ' + name + '!', 'success');
      return true;

    } catch (err) {
      UI.toast('❌ ' + err.message, 'error');
      return false;
    }
  }

  /* ── Load Shop after login ── */
  async function _loadShop() {
    try {
      const meta = window.SBP.user?.user_metadata || {};

      let { data: shops, error } = await _sb
        .from('shops')
        .select('*')
        .eq('owner_id', window.SBP.user.id)
        .limit(1);

      if (error) throw error;

      // If no owned shop, check if user is staff member
      if (!shops || !shops.length) {
        if (meta.is_staff && meta.shop_id) {
          const { data: staffShop } = await _sb
            .from('shops').select('*').eq('id', meta.shop_id).limit(1);
          if (staffShop?.length) {
            shops = staffShop;
            window.SBP.role = meta.role || 'cashier';
          }
        }
        // Also check shop_users table
        if (!shops || !shops.length) {
          const { data: suData } = await _sb
            .from('shop_users').select('shop_id,role')
            .eq('user_id', window.SBP.user.id).eq('is_active', true).limit(1);
          if (suData?.length) {
            const { data: staffShop2 } = await _sb
              .from('shops').select('*').eq('id', suData[0].shop_id).limit(1);
            if (staffShop2?.length) {
              shops = staffShop2;
              window.SBP.role = suData[0].role || meta.role || 'cashier';
            }
          }
        }
      }

      if (!shops || !shops.length) {
        // First login — create default shop
        const { data: newShop, error: se } = await _sb.from('shops').insert({
          owner_id:       window.SBP.user.id,
          name:           meta.shop || meta.name + "'s Shop",
          owner_name:     meta.name || 'User',
          email:          window.SBP.user.email,
          invoice_prefix: 'INV',
          invoice_counter: 1
        }).select().single();

        if (se) throw se;
        shops = [newShop];
      }

      const shop = shops[0];
      window.SBP.shopId = shop.id;
      window.SBP.shop   = shop;
      window.SBP.role   = window.SBP.role || meta.role || 'Admin';
      window.SBP.ready  = true;
      window.SBP.isStaff = !!meta.is_staff;

      // Persist for offline
      localStorage.setItem('sbp_shop',    JSON.stringify(shop));
      localStorage.setItem('sbp_role',    window.SBP.role);
      localStorage.setItem('sbp_shop_id', shop.id);

    } catch (err) {
      console.error('Shop load error:', err);
      // Try offline fallback
      const cached = localStorage.getItem('sbp_shop');
      if (cached) {
        const shop        = JSON.parse(cached);
        window.SBP.shopId = shop.id || localStorage.getItem('sbp_shop_id');
        window.SBP.shop   = shop;
        window.SBP.role   = localStorage.getItem('sbp_role') || 'Admin';
        window.SBP.ready  = true;
      }
    }
  }

  /* ── Logout ── */
  async function logout() {
    clearTimeout(_sessionTimer);
    clearTimeout(_warnTimer);
    document.getElementById('session-warning-toast')?.remove();

    await _sb.auth.signOut();

    window.SBP.user   = null;
    window.SBP.shopId = null;
    window.SBP.shop   = null;
    window.SBP.ready  = false;

    document.body.classList.remove('logged-in');
    localStorage.removeItem('sbp_last_activity');

    // Redirect to login
    window.location.href = '/index.html';
  }

  /* ── Auto-login on page load ── */
  async function checkSession() {
    // Try from Supabase session
    const { data: { session } } = await _sb.auth.getSession();

    if (session) {
      window.SBP.user = session.user;
      await _loadShop();
      _resetTimer();
      _startActivityTracking();
      return true;
    }

    // Check if session expired by inactivity
    const last    = parseInt(localStorage.getItem('sbp_last_activity') || '0');
    const elapsed = (Date.now() - last) / 1000 / 60;
    if (last && elapsed > _sessionTimeout) {
      UI.toast('🔒 Session expired. Please login again.', 'info');
    }

    return false;
  }

  /* ── Forgot Password ── */
  async function forgotPassword(email) {
    if (!email) { UI.toast('Enter your email address', 'error'); return; }
    const { error } = await _sb.auth.resetPasswordForEmail(email, {
      redirectTo: window.location.origin + '/index.html'
    });
    if (error) { UI.toast('❌ ' + error.message, 'error'); return; }
    UI.toast('✅ Password reset link sent to ' + email, 'success');
  }

  /* ── Set session timeout ── */
  function setSessionTimeout(mins) {
    _sessionTimeout = mins;
    localStorage.setItem('sbp_session_timeout', mins.toString());
    _resetTimer();
    UI.toast('✅ Session timeout set to ' + (mins >= 60 ? (mins/60)+'hr' : mins+'min'), 'success');
  }

  function keepAlive() {
    _resetTimer();
    document.getElementById('session-warning-toast')?.remove();
    UI.toast('✅ Session extended', 'success');
  }

  /* ── Public API ── */
  return { login, signup, logout, checkSession, forgotPassword, setSessionTimeout, keepAlive };

})();

window.Auth = Auth;
