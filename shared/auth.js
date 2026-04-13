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

  /* ── Load Shop after login ──
     Resolution order:
       1. STAFF path (meta.is_staff or shop_users row exists) → load PARENT shop
       2. OWNER path → load shop where owner_id = user.id
       3. First-time owner → create default shop
     CRITICAL: never auto-create a shop for a staff user (would orphan them).
  */
  async function _loadShop() {
    try {
      const meta   = window.SBP.user?.user_metadata || {};
      const userId = window.SBP.user.id;
      let shop = null;
      let role = null;
      let isStaff = false;

      // ── 1. STAFF PATH ──────────────────────────────────────
      // Check shop_users table first (authoritative source)
      const { data: suRows } = await _sb
        .from('shop_users')
        .select('shop_id, role, is_active')
        .eq('user_id', userId)
        .eq('is_active', true)
        .limit(1);

      const suRow = suRows?.[0];
      const staffShopId = suRow?.shop_id || (meta.is_staff ? meta.shop_id : null);

      if (staffShopId) {
        isStaff = true;
        role    = suRow?.role || meta.role || 'Cashier';

        const { data: parentShop, error: psErr } = await _sb
          .from('shops').select('*').eq('id', staffShopId).single();

        if (psErr || !parentShop) {
          // Staff is registered but parent shop not readable.
          // Almost always an RLS or deleted-shop issue. DO NOT auto-create.
          throw new Error(
            'Could not load your shop. Please ask the shop owner to re-invite you, ' +
            'or check your internet connection.'
          );
        }
        shop = parentShop;
      }

      // ── 2. OWNER PATH ──────────────────────────────────────
      if (!shop) {
        const { data: ownedShops, error: osErr } = await _sb
          .from('shops').select('*').eq('owner_id', userId).limit(1);
        if (osErr) throw osErr;

        if (ownedShops?.length) {
          shop = ownedShops[0];
          role = 'Admin';
        }
      }

      // ── 3. FIRST-TIME OWNER → create default shop ──────────
      if (!shop) {
        // Safety: only create if user is clearly NOT a staff member
        if (meta.is_staff) {
          throw new Error(
            'Staff account has no linked shop. Please contact your shop owner.'
          );
        }
        const { data: newShop, error: se } = await _sb.from('shops').insert({
          owner_id:        userId,
          name:            meta.shop || (meta.name || 'My') + "'s Shop",
          owner_name:      meta.name || 'User',
          email:           window.SBP.user.email,
          invoice_prefix:  'INV',
          invoice_counter: 1
        }).select().single();
        if (se) throw se;
        shop = newShop;
        role = 'Admin';
      }

      // ── Commit to global state ─────────────────────────────
      window.SBP.shopId  = shop.id;
      window.SBP.shop    = shop;
      window.SBP.role    = role;
      window.SBP.isStaff = isStaff;
      window.SBP.ready   = true;

      // Persist for offline
      localStorage.setItem('sbp_shop',         JSON.stringify(shop));
      localStorage.setItem('sbp_role',         role);
      localStorage.setItem('sbp_shop_id',      shop.id);
      localStorage.setItem('sbp_is_staff',     isStaff ? '1' : '0');

    } catch (err) {
      console.error('Shop load error:', err);

      // Offline fallback — only if we have cached data
      const cached = localStorage.getItem('sbp_shop');
      if (cached) {
        const shop = JSON.parse(cached);
        window.SBP.shopId  = shop.id || localStorage.getItem('sbp_shop_id');
        window.SBP.shop    = shop;
        window.SBP.role    = localStorage.getItem('sbp_role') || 'Admin';
        window.SBP.isStaff = localStorage.getItem('sbp_is_staff') === '1';
        window.SBP.ready   = true;
        return;
      }

      // No cache + error → bubble up so login screen can show the message
      window.SBP.ready = false;
      if (typeof UI !== 'undefined' && UI.toast) {
        UI.toast('❌ ' + (err.message || 'Could not load shop'), 'error', 6000);
      }
      throw err;
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
