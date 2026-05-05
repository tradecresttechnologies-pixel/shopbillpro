/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Universal Service Catalog v1.0
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Wraps RPCs from 010_service_catalog.sql:
     - SBPServices.list(shopId)              → admin: all services
     - SBPServices.create(shopId, data)
     - SBPServices.update(serviceId, patch)
     - SBPServices.delete(serviceId)
     - SBPServices.toggleActive(serviceId)
     - SBPServices.reorder(shopId, idArray)
     - SBPServices.getPublic(slug)           → anon: active services for /s/[slug]

   Plan-gating: cloud sync is Pro+ only. Free shops can hold services
   in localStorage but they don't sync to Supabase or appear on the
   public website. Same pattern as products in stock.html.

   Requires: window._sb (Supabase client).
══════════════════════════════════════════════════════════════════ */

(function (global) {
  'use strict';

  const _sb = function () {
    if (!global._sb) { console.warn('[SBPServices] _sb not initialized'); return null; }
    return global._sb;
  };

  const _isPro = function () {
    if (typeof global.isPro === 'function') return global.isPro();
    try {
      const shop = JSON.parse(localStorage.getItem('sbp_shop') || '{}');
      return shop.plan === 'pro' || shop.plan === 'business';
    } catch (_) { return false; }
  };

  // ── Local cache (per-session) ──────────────────────────────────
  let _publicCache = {}; // slug -> {services, ts}
  const PUBLIC_TTL_MS = 60_000;

  // ════════════════════════════════════════════════════════════════
  // ADMIN
  // ════════════════════════════════════════════════════════════════

  async function list(shopId) {
    if (!shopId) return { ok: false, error: 'no_shop_id', services: [] };
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb', services: [] };

    try {
      const { data, error } = await sb.rpc('sbp_services_list_admin', { p_shop_id: shopId });
      if (error) return { ok: false, error: error.message, services: [] };
      if (!data || !data.ok) return { ok: false, error: (data && data.error) || 'no_data', services: [] };
      return { ok: true, services: data.services || [] };
    } catch (e) {
      return { ok: false, error: String(e), services: [] };
    }
  }

  async function create(shopId, payload) {
    if (!shopId) return { ok: false, error: 'no_shop_id' };
    if (!_isPro()) return { ok: false, error: 'free_plan_no_cloud_sync' };
    if (!payload || !payload.name || !String(payload.name).trim()) {
      return { ok: false, error: 'name_required' };
    }
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_services_create', {
        p_shop_id: shopId,
        p_data: payload
      });
      if (error) return { ok: false, error: error.message };
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  async function update(serviceId, patch) {
    if (!serviceId) return { ok: false, error: 'no_service_id' };
    if (!_isPro()) return { ok: false, error: 'free_plan_no_cloud_sync' };
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_services_update', {
        p_service_id: serviceId,
        p_patch: patch || {}
      });
      if (error) return { ok: false, error: error.message };
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  async function remove(serviceId) {
    if (!serviceId) return { ok: false, error: 'no_service_id' };
    if (!_isPro()) return { ok: false, error: 'free_plan_no_cloud_sync' };
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_services_delete', { p_service_id: serviceId });
      if (error) return { ok: false, error: error.message };
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  async function toggleActive(serviceId) {
    if (!serviceId) return { ok: false, error: 'no_service_id' };
    if (!_isPro()) return { ok: false, error: 'free_plan_no_cloud_sync' };
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_services_toggle_active', { p_service_id: serviceId });
      if (error) return { ok: false, error: error.message };
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  async function reorder(shopId, orderedIds) {
    if (!shopId) return { ok: false, error: 'no_shop_id' };
    if (!_isPro()) return { ok: false, error: 'free_plan_no_cloud_sync' };
    if (!Array.isArray(orderedIds) || orderedIds.length === 0) {
      return { ok: false, error: 'invalid_order' };
    }
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc('sbp_services_reorder', {
        p_shop_id: shopId,
        p_ordered_ids: orderedIds
      });
      if (error) return { ok: false, error: error.message };
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  // ════════════════════════════════════════════════════════════════
  // PUBLIC (anon — first API-first storefront endpoint)
  // ════════════════════════════════════════════════════════════════

  async function getPublic(slug, opts) {
    opts = opts || {};
    if (!slug) return { ok: false, error: 'no_slug', services: [] };

    if (!opts.skipCache && _publicCache[slug]) {
      const c = _publicCache[slug];
      if (Date.now() - c.ts < PUBLIC_TTL_MS) {
        return { ok: true, services: c.services, _cache: true };
      }
    }

    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb', services: [] };

    try {
      const { data, error } = await sb.rpc('sbp_get_shop_services_public', { p_slug: slug });
      if (error) return { ok: false, error: error.message, services: [] };
      if (!data) return { ok: false, error: 'no_data', services: [] };

      const services = data.services || [];
      _publicCache[slug] = { ts: Date.now(), services: services };
      return { ok: !!data.ok, error: data.error, services: services };
    } catch (e) {
      return { ok: false, error: String(e), services: [] };
    }
  }

  function clearPublicCache(slug) {
    if (slug) delete _publicCache[slug];
    else _publicCache = {};
  }

  // ════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ════════════════════════════════════════════════════════════════

  global.SBPServices = {
    list: list,
    create: create,
    update: update,
    delete: remove,    // 'delete' is reserved word in some old JS — keep both
    remove: remove,
    toggleActive: toggleActive,
    reorder: reorder,
    getPublic: getPublic,
    clearPublicCache: clearPublicCache,
    isPro: _isPro
  };

})(typeof window !== 'undefined' ? window : this);
