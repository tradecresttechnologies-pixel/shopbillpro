/* ════════════════════════════════════════════════════════════════
   ShopBill Pro Admin — Data Layer (Real Supabase RPCs)
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
    // Pull daily revenue series for the last N days
    const since = new Date(Date.now() - days*86400000).toISOString();
    const { data } = await this.sb.from('subscriptions')
      .select('amount, created_at, plan, billing_cycle')
      .eq('status', 'active')
      .gte('created_at', since)
      .order('created_at');
    if (!data) return [];
    // Bucket by day
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
}

window.AdminDB = AdminDB;
