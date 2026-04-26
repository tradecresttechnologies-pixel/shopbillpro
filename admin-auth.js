/* ══════════════════════════════════════════════════════════
   ShopBill Pro Admin Control Panel — Authentication
   Secure admin access with master password + role-based checks
══════════════════════════════════════════════════════════ */

/* ══════════════════════════════════════════════════════════
   ShopBill Pro Admin Control Panel — Authentication
   Secure admin access with master password + role-based checks
══════════════════════════════════════════════════════════ */

// Master password is stored as SHA-256 hash, not plaintext.
// To regenerate: open DevTools console, run:
//   const enc = new TextEncoder().encode('YOUR_NEW_PASSWORD');
//   crypto.subtle.digest('SHA-256', enc).then(b =>
//     console.log(Array.from(new Uint8Array(b)).map(x=>x.toString(16).padStart(2,'0')).join(''))
//   );
const ADMIN_CONFIG = {
  // SHA-256 of 'SBP_ADMIN_2024_SECURE' — change in production!
  MASTER_PASSWORD_HASH: '68b9de762bdc872d5a7e8cd2b9d0f497aec0f53cefcb4caa8c1a8a6f63c7d8fc',
  SESSION_TIMEOUT: 60 * 60 * 1000,
  MAX_LOGIN_ATTEMPTS: 5,
  LOCKOUT_TIME: 15 * 60 * 1000,
};

async function _sha256Hex(text){
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map(b=>b.toString(16).padStart(2,'0')).join('');
}

class AdminAuth {
  constructor() {
    this.isAuthenticated = false;
    this.sessionExpiry = null;
    this.adminEmail = null;
    this.adminRole = 'viewer'; // 'viewer', 'editor', 'admin'
    this.initSession();
  }

  initSession() {
    const session = sessionStorage.getItem('sbp_admin_session');
    if (session) {
      try {
        const data = JSON.parse(session);
        if (data.expiry > Date.now()) {
          this.isAuthenticated = true;
          this.sessionExpiry = data.expiry;
          this.adminEmail = data.email;
          this.adminRole = data.role || 'viewer';
          this.startSessionTimer();
          return true;
        } else {
          this.logout();
        }
      } catch (e) {
        sessionStorage.removeItem('sbp_admin_session');
      }
    }
    return false;
  }

  async login(password, email = 'admin@shopbillpro.in') {
    // Check for lockout
    const lockout = localStorage.getItem('sbp_admin_lockout');
    if (lockout && Date.now() < parseInt(lockout)) {
      throw new Error('Too many login attempts. Try again later.');
    }

    // Verify password (constant-time compare against stored hash)
    let entered;
    try { entered = await _sha256Hex(password || ''); }
    catch(e) { throw new Error('Crypto API unavailable — use a modern browser'); }
    let mismatch = entered.length !== ADMIN_CONFIG.MASTER_PASSWORD_HASH.length ? 1 : 0;
    for (let i = 0; i < entered.length; i++) {
      mismatch |= entered.charCodeAt(i) ^ ADMIN_CONFIG.MASTER_PASSWORD_HASH.charCodeAt(i);
    }
    if (mismatch !== 0) {
      this.recordFailedAttempt();
      throw new Error('Invalid password');
    }

    // Clear failed attempts
    localStorage.removeItem('sbp_admin_failed_attempts');
    localStorage.removeItem('sbp_admin_lockout');

    // Create session
    this.sessionExpiry = Date.now() + ADMIN_CONFIG.SESSION_TIMEOUT;
    this.isAuthenticated = true;
    this.adminEmail = email;
    this.adminRole = 'admin';

    sessionStorage.setItem('sbp_admin_session', JSON.stringify({
      email: this.adminEmail,
      role: this.adminRole,
      expiry: this.sessionExpiry,
      loginTime: Date.now(),
    }));

    this.logAction('admin_login', { email });
    this.startSessionTimer();
    return true;
  }

  recordFailedAttempt() {
    let attempts = parseInt(localStorage.getItem('sbp_admin_failed_attempts') || '0') + 1;
    localStorage.setItem('sbp_admin_failed_attempts', String(attempts));

    if (attempts >= ADMIN_CONFIG.MAX_LOGIN_ATTEMPTS) {
      localStorage.setItem('sbp_admin_lockout', String(Date.now() + ADMIN_CONFIG.LOCKOUT_TIME));
      throw new Error('Too many failed attempts. Locked for 15 minutes.');
    }

    throw new Error(`Invalid password. ${ADMIN_CONFIG.MAX_LOGIN_ATTEMPTS - attempts} attempts remaining.`);
  }

  startSessionTimer() {
    if (this.sessionTimer) clearTimeout(this.sessionTimer);
    
    const timeLeft = this.sessionExpiry - Date.now();
    this.sessionTimer = setTimeout(() => {
      this.logout();
      window.location.href = '/admin-login.html?expired=true';
    }, timeLeft);

    // 5-minute warning before expiry
    if (timeLeft > 5 * 60 * 1000) {
      setTimeout(() => {
        const event = new CustomEvent('sbp_admin_warning', {
          detail: { message: 'Your session expires in 5 minutes' }
        });
        window.dispatchEvent(event);
      }, timeLeft - 5 * 60 * 1000);
    }
  }

  logout() {
    this.isAuthenticated = false;
    this.sessionExpiry = null;
    this.adminEmail = null;
    sessionStorage.removeItem('sbp_admin_session');
    if (this.sessionTimer) clearTimeout(this.sessionTimer);
    this.logAction('admin_logout', {});
  }

  hasPermission(action) {
    const permissions = {
      'viewer': ['view_dashboard', 'view_analytics', 'view_users', 'view_revenue', 'view_health'],
      'editor': ['view_dashboard', 'view_analytics', 'view_users', 'view_revenue', 'view_health',
                 'edit_features', 'manage_flags', 'send_notifications'],
      'admin': ['*'], // All permissions
    };

    const allowed = permissions[this.adminRole] || [];
    return allowed.includes('*') || allowed.includes(action);
  }

  logAction(action, details) {
    const log = {
      timestamp: new Date().toISOString(),
      action,
      email: this.adminEmail,
      details,
    };

    const logs = JSON.parse(localStorage.getItem('sbp_admin_logs') || '[]');
    logs.push(log);
    
    // Keep only last 1000 logs
    if (logs.length > 1000) logs.shift();
    localStorage.setItem('sbp_admin_logs', JSON.stringify(logs));
  }

  getAuditLogs(limit = 50) {
    const logs = JSON.parse(localStorage.getItem('sbp_admin_logs') || '[]');
    return logs.slice(-limit).reverse();
  }

  static getInstance() {
    if (!window._adminAuth) {
      window._adminAuth = new AdminAuth();
    }
    return window._adminAuth;
  }
}

// Protect admin pages
function requireAdminAuth() {
  const auth = AdminAuth.getInstance();
  if (!auth.isAuthenticated) {
    window.location.href = '/admin-login.html?redirect=' + encodeURIComponent(window.location.pathname);
    return false;
  }
  return true;
}

// Make globally available
window.AdminAuth = AdminAuth;
window.requireAdminAuth = requireAdminAuth;
