/* ════════════════════════════════════════════════════════════════
   ShopBill Pro Admin — Data Layer (Real Supabase RPCs)

   Updated for Batch 1A (May 2026):
   - Added SEO Manager methods (global, pages, blog, redirects)
   - Added business categories methods
   - Added beta stats method
   - All existing methods preserved unchanged
══════════════════════════════════════════════════════════════════ */

class AdminDB {
  constructor() {
    if (AdminDB.instance) return AdminDB.instance;
    const SB_URL = 'https://jfqeirfrkjdkqqixivru.supabase.co';
    const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpmcWVpcmZya2pka3FxaXhpdnJ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzQ4MzgsImV4cCI6MjA4OTk1MDgzOH0.akd4E0nil8ypLR4WOykkeYIL8g4uuNU6XdSVh_Y1utk';
    this.sb = (typeof supabase !== 'undefined') ? supabase.createClient(SB_URL, SB_KEY) : null;
    AdminDB.instance = this;
  }
  static getInstance() { return AdminDB.instance || new AdminDB(); }

  _token() { return sessionStorage.getItem('sbp_admin_token') || ''; }

  // ─────────────────────────────────────────────────────────
  // EXISTING METHODS (unchanged from previous build)
  // ─────────────────────────────────────────────────────────

  async getMetrics() {
    if (!this.sb) return this._mock();
    try {
      const { data, error } = await this.sb.rpc('admin_metrics', { p_admin_token: this._token() });
      if (error) { console.warn('Metrics RPC error:', error); return this._mock(); }
      return data;
    } catch (e) { console.warn(e); return this._mock(); }
  }

  async listShops({ search='', plan='all', limit=100, offset=0 } = {}) {
    if (!this.sb) return [];
    try {
      const { data, error } = await this.sb.rpc('admin_list_shops', {
        p_admin_token: this._token(), p_search: search, p_plan_filter: plan, p_limit: limit, p_offset: offset
      });
      if (error) { console.warn('Shops list error:', error); return []; }
      return data || [];
    } catch (e) { console.warn(e); return []; }
  }

  async listSubscriptions({ status='all', limit=200 } = {}) {
    if (!this.sb) return [];
    try {
      const { data, error } = await this.sb.rpc('admin_list_subscriptions', {
        p_admin_token: this._token(), p_status_filter: status, p_limit: limit
      });
      if (error) { console.warn('Subs list error:', error); return []; }
      return data || [];
    } catch (e) { console.warn(e); return []; }
  }

  async approveSubscription(subscriptionId, notes='') {
    const { data, error } = await this.sb.rpc('admin_approve_subscription', {
      p_admin_token: this._token(), p_subscription_id: subscriptionId, p_notes: notes
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async rejectSubscription(subscriptionId, notes='') {
    const { data, error } = await this.sb.rpc('admin_reject_subscription', {
      p_admin_token: this._token(), p_subscription_id: subscriptionId, p_notes: notes
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async changePlan(shopId, newPlan, expiresAt=null, notes='') {
    const { data, error } = await this.sb.rpc('admin_change_plan', {
      p_admin_token: this._token(), p_shop_id: shopId, p_new_plan: newPlan,
      p_expires_at: expiresAt, p_notes: notes
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async suspendShop(shopId, suspend, reason='') {
    const { data, error } = await this.sb.rpc('admin_suspend_shop', {
      p_admin_token: this._token(), p_shop_id: shopId, p_suspend: suspend, p_reason: reason
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async getSettings() {
    if (!this.sb) return [];
    try {
      const { data, error } = await this.sb.rpc('admin_get_all_settings', { p_admin_token: this._token() });
      if (error) throw new Error(error.message);
      return data || [];
    } catch (e) { console.warn('getSettings:', e); throw e; }
  }

  async setSetting(key, value, isSecret=false) {
    const { data, error } = await this.sb.rpc('admin_set_setting', {
      p_admin_token: this._token(), p_key: key, p_value: value, p_is_secret: isSecret
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async getWebhookEvents(limit=50) {
    if (!this.sb) return [];
    const { data } = await this.sb.from('webhook_events')
      .select('*').order('created_at', {ascending:false}).limit(limit);
    return data || [];
  }

  async getAuditLog(limit=100) {
    if (!this.sb) return [];
    const { data } = await this.sb.from('admin_audit_log')
      .select('*').order('created_at', {ascending:false}).limit(limit);
    return data || [];
  }

  async getRevenueChart(days=30) {
    if (!this.sb) return [];
    const since = new Date(Date.now() - days*86400000).toISOString();
    const { data } = await this.sb.from('subscriptions')
      .select('amount, created_at, plan, billing_cycle')
      .eq('status', 'active')
      .gte('created_at', since)
      .order('created_at');
    if (!data) return [];
    const buckets = {};
    data.forEach(r => {
      const d = (r.created_at||'').slice(0,10);
      if(!buckets[d]) buckets[d] = { date:d, total:0, pro:0, business:0 };
      buckets[d].total += parseFloat(r.amount||0);
      if(r.plan === 'pro') buckets[d].pro += parseFloat(r.amount||0);
      else if(r.plan === 'business' || r.plan === 'enterprise') buckets[d].business += parseFloat(r.amount||0);
    });
    return Object.values(buckets).sort((a,b)=>a.date.localeCompare(b.date));
  }

  _mock() {
    return {
      total_shops: 0, pro_shops: 0, business_shops: 0, free_shops: 0,
      active_paid: 0, today_revenue: 0, week_revenue: 0, month_revenue: 0,
      mrr: 0, arr: 0, pending_subscriptions: 0, total_bills: 0,
      today_signups: 0, week_signups: 0, conversion_rate: 0
    };
  }

  // ═════════════════════════════════════════════════════════
  // NEW METHODS — Batch 1A additions (May 2026)
  // ═════════════════════════════════════════════════════════

  // ─────────────────────────────────────────────────────────
  // SEO Global (singleton)
  // ─────────────────────────────────────────────────────────
  async getSEOGlobal() {
    if (!this.sb) return null;
    const { data, error } = await this.sb.rpc('admin_get_seo_global', { p_token: this._token() });
    if (error) throw new Error(error.message);
    return data;
  }

  async updateSEOGlobal(patch) {
    if (!this.sb) throw new Error('Supabase not initialized');
    const { data, error } = await this.sb.rpc('admin_update_seo_global', {
      p_token: this._token(), p_patch: patch
    });
    if (error) throw new Error(error.message);
    return data;
  }

  // ─────────────────────────────────────────────────────────
  // SEO Pages (per-page settings)
  // ─────────────────────────────────────────────────────────
  async listSEOPages() {
    if (!this.sb) return [];
    const { data, error } = await this.sb.rpc('admin_list_seo_pages', { p_token: this._token() });
    if (error) throw new Error(error.message);
    return data || [];
  }

  async upsertSEOPage(pageData) {
    if (!this.sb) throw new Error('Supabase not initialized');
    const { data, error } = await this.sb.rpc('admin_upsert_seo_page', {
      p_token: this._token(), p_data: pageData
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async deleteSEOPage(path) {
    if (!this.sb) throw new Error('Supabase not initialized');
    const { data, error } = await this.sb.rpc('admin_delete_seo_page', {
      p_token: this._token(), p_path: path
    });
    if (error) throw new Error(error.message);
    return data;
  }

  // ─────────────────────────────────────────────────────────
  // Blog Posts CMS
  // ─────────────────────────────────────────────────────────
  async listBlogPosts(status=null) {
    if (!this.sb) return [];
    const { data, error } = await this.sb.rpc('admin_list_blog_posts', {
      p_token: this._token(), p_status: status
    });
    if (error) throw new Error(error.message);
    return data || [];
  }

  async upsertBlogPost(postData) {
    if (!this.sb) throw new Error('Supabase not initialized');
    const { data, error } = await this.sb.rpc('admin_upsert_blog_post', {
      p_token: this._token(), p_data: postData
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async deleteBlogPost(slug) {
    if (!this.sb) throw new Error('Supabase not initialized');
    const { data, error } = await this.sb.rpc('admin_delete_blog_post', {
      p_token: this._token(), p_slug: slug
    });
    if (error) throw new Error(error.message);
    return data;
  }

  // ─────────────────────────────────────────────────────────
  // SEO Redirects
  // ─────────────────────────────────────────────────────────
  async listRedirects() {
    if (!this.sb) return [];
    const { data, error } = await this.sb.rpc('admin_list_redirects', { p_token: this._token() });
    if (error) throw new Error(error.message);
    return data || [];
  }

  async upsertRedirect(redirectData) {
    if (!this.sb) throw new Error('Supabase not initialized');
    const { data, error } = await this.sb.rpc('admin_upsert_redirect', {
      p_token: this._token(), p_data: redirectData
    });
    if (error) throw new Error(error.message);
    return data;
  }

  async deleteRedirect(fromPath) {
    if (!this.sb) throw new Error('Supabase not initialized');
    const { data, error } = await this.sb.rpc('admin_delete_redirect', {
      p_token: this._token(), p_from_path: fromPath
    });
    if (error) throw new Error(error.message);
    return data;
  }

  // ─────────────────────────────────────────────────────────
  // Business Categories (read-only — admins edit via SQL/seed)
  // ─────────────────────────────────────────────────────────
  async listMacroCategories() {
    if (!this.sb) return [];
    const { data, error } = await this.sb.rpc('get_macro_categories');
    if (error) { console.warn('macro cats:', error); return []; }
    return data || [];
  }

  async listBusinessCategories(macroCode=null) {
    if (!this.sb) return [];
    if (macroCode) {
      const { data, error } = await this.sb.rpc('get_business_categories', { p_macro: macroCode });
      if (error) { console.warn('biz cats:', error); return []; }
      return data || [];
    } else {
      // No macro filter — fetch all directly from table for admin page
      const { data, error } = await this.sb.from('sbp_business_categories')
        .select('*').order('macro_code').order('display_order');
      if (error) { console.warn('all biz cats:', error); return []; }
      return data || [];
    }
  }

  // ─────────────────────────────────────────────────────────
  // Beta Stats
  // ─────────────────────────────────────────────────────────
  async getBetaStats() {
    if (!this.sb) return null;
    try {
      const { data, error } = await this.sb.rpc('admin_get_beta_stats', { p_token: this._token() });
      if (error) { console.warn('beta stats:', error); return null; }
      // RPC returns table — Supabase returns array of one row
      return Array.isArray(data) ? data[0] : data;
    } catch (e) { console.warn(e); return null; }
  }

  async getBetaConfig() {
    if (!this.sb) return null;
    const { data, error } = await this.sb.rpc('get_beta_config');
    if (error) { console.warn('beta config:', error); return null; }
    return Array.isArray(data) ? data[0] : data;
  }
}

window.AdminDB = AdminDB;
