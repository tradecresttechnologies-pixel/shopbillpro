/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Customer Loyalty / Rewards v1.0
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Provides a clean client API around the 009_loyalty.sql RPCs:
     - SBPLoyalty.getConfig(shopId)          → read shop's loyalty config
     - SBPLoyalty.saveConfig(shopId, patch)   → upsert shop's loyalty config
     - SBPLoyalty.balance(shopId, custId)     → current points balance
     - SBPLoyalty.recentTxns(shopId, custId)  → transaction history
     - SBPLoyalty.earnOnBill(billId)          → after bill save, awards points
     - SBPLoyalty.redeem(shopId, custId, billId, points) → returns ₹ discount
     - SBPLoyalty.reverseBill(billId)         → on void, reverses earn+redeem
     - SBPLoyalty.adjust(shopId, custId, pts, reason) → manual adjustment
     - SBPLoyalty.previewEarn(amount, config) → client-side preview (no DB)
     - SBPLoyalty.maxRedeemable(balance, config, billSubtotal) → cap calc

   Plan gating handled both client-side (UI) and server-side (RPC).
   Free plan: all calls return {ok: false, error: 'free_plan_no_loyalty'}.

   Requires: window._sb (Supabase client). Same pattern as customers.html.
══════════════════════════════════════════════════════════════════ */

(function (global) {
  'use strict';

  const _ = {
    // ── Lazy supabase access ────────────────────────────────────
    _sb: function () {
      if (!global._sb) {
        console.warn('[SBPLoyalty] _sb (Supabase client) not initialized yet');
        return null;
      }
      return global._sb;
    },

    // ── Plan gating helper (matches customers.html pattern) ──────
    _isPro: function () {
      if (typeof global.isPro === 'function') return global.isPro();
      try {
        const shop = JSON.parse(localStorage.getItem('sbp_shop') || '{}');
        return shop.plan === 'pro' || shop.plan === 'business';
      } catch (_) { return false; }
    },

    _isBiz: function () {
      if (typeof global.isBiz === 'function') return global.isBiz();
      try {
        const shop = JSON.parse(localStorage.getItem('sbp_shop') || '{}');
        return shop.plan === 'business';
      } catch (_) { return false; }
    }
  };

  // ── Default config for previews ────────────────────────────────
  const DEFAULT_CONFIG = {
    enabled: false,
    earn_rate_amount: 100,
    earn_rate_points: 1,
    redeem_rate_points: 100,
    redeem_rate_amount: 10,
    min_redeem_points: 100,
    expiry_months: 12,
    earn_on_field: 'taxable_total',
    birthday_bonus_points: 0,
    welcome_bonus_points: 0,
    display_message: 'You earned {points} points! Total balance: {balance}'
  };

  // ── Cache (per-session) ────────────────────────────────────────
  let _configCache = {};      // shop_id -> config
  let _balanceCache = {};     // `${shop_id}:${cust_id}` -> {balance, ts}
  const BALANCE_TTL_MS = 60_000; // 60 seconds

  // ════════════════════════════════════════════════════════════════
  // CONFIG
  // ════════════════════════════════════════════════════════════════

  async function getConfig(shopId) {
    if (!shopId) return { ok: false, error: 'no_shop_id', config: DEFAULT_CONFIG };
    if (_configCache[shopId]) return { ok: true, config: _configCache[shopId] };

    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb', config: DEFAULT_CONFIG };

    try {
      const { data, error } = await sb
        .from('sbp_loyalty_config')
        .select('*')
        .eq('shop_id', shopId)
        .maybeSingle();

      if (error) return { ok: false, error: error.message, config: DEFAULT_CONFIG };

      const config = data || { ...DEFAULT_CONFIG, shop_id: shopId };
      _configCache[shopId] = config;
      return { ok: true, config };
    } catch (e) {
      return { ok: false, error: String(e), config: DEFAULT_CONFIG };
    }
  }

  async function saveConfig(shopId, patch) {
    if (!shopId) return { ok: false, error: 'no_shop_id' };
    if (!_._isPro()) return { ok: false, error: 'free_plan_no_loyalty' };

    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    const payload = { shop_id: shopId, ...patch };
    try {
      const { data, error } = await sb
        .from('sbp_loyalty_config')
        .upsert(payload, { onConflict: 'shop_id' })
        .select()
        .single();

      if (error) return { ok: false, error: error.message };

      _configCache[shopId] = data;
      return { ok: true, config: data };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  // ════════════════════════════════════════════════════════════════
  // BALANCE & TRANSACTIONS
  // ════════════════════════════════════════════════════════════════

  async function balance(shopId, customerId, opts) {
    opts = opts || {};
    if (!shopId || !customerId) return { ok: false, error: 'missing_ids', balance: 0 };

    const cacheKey = shopId + ':' + customerId;
    if (!opts.skipCache && _balanceCache[cacheKey]) {
      const c = _balanceCache[cacheKey];
      if (Date.now() - c.ts < BALANCE_TTL_MS) return { ok: true, ...c.data };
    }

    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb', balance: 0 };

    try {
      const { data, error } = await sb.rpc('sbp_loyalty_balance', {
        p_shop_id: shopId,
        p_customer_id: customerId
      });

      if (error) return { ok: false, error: error.message, balance: 0 };
      if (!data || !data.ok) return { ok: false, error: data && data.error, balance: 0 };

      _balanceCache[cacheKey] = { ts: Date.now(), data };
      return data;
    } catch (e) {
      return { ok: false, error: String(e), balance: 0 };
    }
  }

  function clearBalanceCache(shopId, customerId) {
    if (shopId && customerId) {
      delete _balanceCache[shopId + ':' + customerId];
    } else {
      _balanceCache = {};
    }
  }

  async function recentTxns(shopId, customerId, limit) {
    if (!shopId || !customerId) return { ok: false, error: 'missing_ids', txns: [] };
    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb', txns: [] };

    try {
      const { data, error } = await sb.rpc('sbp_loyalty_recent_txns', {
        p_shop_id: shopId,
        p_customer_id: customerId,
        p_limit: limit || 20
      });

      if (error) return { ok: false, error: error.message, txns: [] };
      if (!data || !data.ok) return { ok: false, error: data && data.error, txns: [] };

      return { ok: true, txns: data.txns || [] };
    } catch (e) {
      return { ok: false, error: String(e), txns: [] };
    }
  }

  // ════════════════════════════════════════════════════════════════
  // EARN / REDEEM / VOID / ADJUST
  // ════════════════════════════════════════════════════════════════

  async function earnOnBill(billId) {
    if (!billId) return { ok: false, error: 'no_bill_id', points: 0 };
    if (!_._isPro()) return { ok: false, error: 'free_plan_no_loyalty', points: 0 };

    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb', points: 0 };

    try {
      const { data, error } = await sb.rpc('sbp_loyalty_earn_on_bill', {
        p_bill_id: billId
      });

      if (error) return { ok: false, error: error.message, points: 0 };
      // Bust the balance cache for this customer so next read is fresh
      clearBalanceCache();
      return data || { ok: false, error: 'no_response', points: 0 };
    } catch (e) {
      return { ok: false, error: String(e), points: 0 };
    }
  }

  async function redeem(shopId, customerId, billId, points) {
    if (!shopId || !customerId) return { ok: false, error: 'missing_ids' };
    if (!_._isPro()) return { ok: false, error: 'free_plan_no_loyalty' };
    if (!points || points <= 0) return { ok: false, error: 'invalid_points' };

    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_loyalty_redeem', {
        p_shop_id: shopId,
        p_customer_id: customerId,
        p_bill_id: billId || null,
        p_points: points
      });

      if (error) return { ok: false, error: error.message };
      clearBalanceCache(shopId, customerId);
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  async function reverseBill(billId) {
    if (!billId) return { ok: false, error: 'no_bill_id' };

    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_loyalty_reverse_bill', {
        p_bill_id: billId
      });

      if (error) return { ok: false, error: error.message };
      clearBalanceCache();
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  async function adjust(shopId, customerId, points, reason) {
    if (!shopId || !customerId) return { ok: false, error: 'missing_ids' };
    if (!_._isPro()) return { ok: false, error: 'free_plan_no_loyalty' };
    if (!points || points === 0) return { ok: false, error: 'invalid_points' };

    const sb = _._sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_loyalty_adjust', {
        p_shop_id: shopId,
        p_customer_id: customerId,
        p_points: points,
        p_reason: reason || null
      });

      if (error) return { ok: false, error: error.message };
      clearBalanceCache(shopId, customerId);
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  // ════════════════════════════════════════════════════════════════
  // CLIENT-SIDE HELPERS (no DB calls)
  // ════════════════════════════════════════════════════════════════

  /**
   * Preview how many points a bill will earn (for billing UI)
   * @param {number} subtotal - bill subtotal (taxable amount)
   * @param {number} discount - bill discount
   * @param {number} grandTotal - bill grand total (incl GST)
   * @param {object} config - loyalty config object
   * @returns {number} points
   */
  function previewEarn(subtotal, discount, grandTotal, config) {
    if (!config || !config.enabled) return 0;
    const base = config.earn_on_field === 'grand_total'
      ? Number(grandTotal) || 0
      : (Number(subtotal) || 0) - (Number(discount) || 0);
    if (base <= 0) return 0;
    return Math.floor(base / config.earn_rate_amount) * config.earn_rate_points;
  }

  /**
   * Calculate max redeemable points given balance + config + bill amount
   * Caps redemption to bill subtotal (can't redeem more than the bill)
   * Also rounds to nearest multiple of redeem_rate_points
   * @returns {{maxPoints, maxAmount}}
   */
  function maxRedeemable(balance, config, billGrandTotal) {
    if (!balance || balance < (config.min_redeem_points || 0)) {
      return { maxPoints: 0, maxAmount: 0 };
    }
    if (!billGrandTotal || billGrandTotal <= 0) {
      return { maxPoints: 0, maxAmount: 0 };
    }

    // ₹ value per point
    const valuePerPoint = config.redeem_rate_amount / config.redeem_rate_points;
    // How many points worth the bill amount
    const pointsForBill = Math.floor(billGrandTotal / valuePerPoint);
    // Cap at balance
    const capped = Math.min(balance, pointsForBill);
    // Round down to multiple of redeem_rate_points
    const maxPoints = Math.floor(capped / config.redeem_rate_points) * config.redeem_rate_points;
    const maxAmount = (maxPoints / config.redeem_rate_points) * config.redeem_rate_amount;

    return { maxPoints, maxAmount };
  }

  /**
   * Format the earn message with placeholders
   */
  function formatMessage(template, points, balance) {
    return (template || DEFAULT_CONFIG.display_message)
      .replace(/\{points\}/g, points)
      .replace(/\{balance\}/g, balance);
  }

  // ════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ════════════════════════════════════════════════════════════════

  global.SBPLoyalty = {
    DEFAULT_CONFIG: DEFAULT_CONFIG,
    getConfig: getConfig,
    saveConfig: saveConfig,
    balance: balance,
    recentTxns: recentTxns,
    earnOnBill: earnOnBill,
    redeem: redeem,
    reverseBill: reverseBill,
    adjust: adjust,
    previewEarn: previewEarn,
    maxRedeemable: maxRedeemable,
    formatMessage: formatMessage,
    clearBalanceCache: clearBalanceCache,
    isPro: _._isPro,
    isBiz: _._isBiz
  };

})(typeof window !== 'undefined' ? window : this);
