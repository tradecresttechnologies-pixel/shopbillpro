/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Universal Appointments v1.0
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Wraps RPCs from 011_appointments.sql:

   ADMIN (auth required, Business plan only):
     SBPAppt.providers.list(shopId)
     SBPAppt.providers.upsert(shopId, providerId | null, data)
     SBPAppt.providers.delete(providerId)
     SBPAppt.blocks.create(providerId, date, startTime, endTime, reason)
     SBPAppt.blocks.delete(blockId)
     SBPAppt.blocks.list(providerId, fromDate, toDate)
     SBPAppt.list(shopId, fromTs, toTs, providerId?, status?)
     SBPAppt.create(shopId, data)
     SBPAppt.update(apptId, patch)
     SBPAppt.setStatus(apptId, newStatus, reason?)

   PUBLIC (anon — first-class API surface):
     SBPAppt.public.getConfig(slug)
     SBPAppt.public.getSlots(slug, providerId, dateISO, durationMinutes)
     SBPAppt.public.book(slug, data)
     SBPAppt.public.getStatus(appointmentId, phone)
══════════════════════════════════════════════════════════════════ */

(function (global) {
  'use strict';

  const _sb = function () {
    if (!global._sb) { console.warn('[SBPAppt] _sb not initialized'); return null; }
    return global._sb;
  };

  const _isBiz = function () {
    if (typeof global.isBiz === 'function') return global.isBiz();
    try {
      const shop = JSON.parse(localStorage.getItem('sbp_shop') || '{}');
      const plan = (shop.plan || '').toLowerCase();
      return plan === 'business' || plan === 'enterprise';
    } catch (_) { return false; }
  };

  // Generic RPC caller with consistent envelope
  async function _rpc(name, params, requireBiz) {
    if (requireBiz && !_isBiz()) {
      return { ok: false, error: 'business_plan_required' };
    }
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_sb' };

    try {
      const { data, error } = await sb.rpc(name, params || {});
      if (error) return { ok: false, error: error.message };
      return data || { ok: false, error: 'no_response' };
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  // ════════════════════════════════════════════════════════════════
  // ADMIN — Providers
  // ════════════════════════════════════════════════════════════════

  const providers = {
    async list(shopId) {
      if (!shopId) return { ok: false, error: 'no_shop_id', providers: [] };
      const r = await _rpc('sbp_appt_providers_list', { p_shop_id: shopId }, true);
      if (!r.ok) return { ...r, providers: [] };
      return { ok: true, providers: r.providers || [] };
    },

    async upsert(shopId, providerId, data) {
      if (!shopId) return { ok: false, error: 'no_shop_id' };
      return await _rpc('sbp_appt_providers_upsert', {
        p_shop_id: shopId,
        p_provider_id: providerId || null,
        p_data: data || {}
      }, true);
    },

    async delete(providerId) {
      if (!providerId) return { ok: false, error: 'no_provider_id' };
      return await _rpc('sbp_appt_providers_delete', { p_provider_id: providerId }, true);
    }
  };

  // ════════════════════════════════════════════════════════════════
  // ADMIN — Blocks (vacation / partial day blocks)
  // ════════════════════════════════════════════════════════════════

  const blocks = {
    async create(providerId, dateStr, startTime, endTime, reason) {
      if (!providerId) return { ok: false, error: 'no_provider_id' };
      return await _rpc('sbp_appt_block_create', {
        p_provider_id: providerId,
        p_date: dateStr,
        p_start_time: startTime || null,
        p_end_time: endTime || null,
        p_reason: reason || null
      }, true);
    },

    async delete(blockId) {
      if (!blockId) return { ok: false, error: 'no_block_id' };
      return await _rpc('sbp_appt_block_delete', { p_block_id: blockId }, true);
    },

    async list(providerId, fromDate, toDate) {
      const r = await _rpc('sbp_appt_blocks_list', {
        p_provider_id: providerId,
        p_from: fromDate || null,
        p_to: toDate || null
      }, true);
      if (!r.ok) return { ...r, blocks: [] };
      return { ok: true, blocks: r.blocks || [] };
    }
  };

  // ════════════════════════════════════════════════════════════════
  // ADMIN — Appointments
  // ════════════════════════════════════════════════════════════════

  async function list(shopId, fromTs, toTs, providerId, status) {
    if (!shopId) return { ok: false, error: 'no_shop_id', appointments: [] };
    const r = await _rpc('sbp_appointments_list', {
      p_shop_id: shopId,
      p_from: fromTs || null,
      p_to: toTs || null,
      p_provider_id: providerId || null,
      p_status: status || null
    }, true);
    if (!r.ok) return { ...r, appointments: [] };
    return { ok: true, appointments: r.appointments || [] };
  }

  async function create(shopId, data) {
    if (!shopId) return { ok: false, error: 'no_shop_id' };
    return await _rpc('sbp_appointments_create', {
      p_shop_id: shopId,
      p_data: data || {}
    }, true);
  }

  async function update(apptId, patch) {
    if (!apptId) return { ok: false, error: 'no_appt_id' };
    return await _rpc('sbp_appointments_update', {
      p_appt_id: apptId,
      p_patch: patch || {}
    }, true);
  }

  async function setStatus(apptId, newStatus, reason) {
    if (!apptId) return { ok: false, error: 'no_appt_id' };
    return await _rpc('sbp_appointments_set_status', {
      p_appt_id: apptId,
      p_status: newStatus,
      p_reason: reason || null
    }, true);
  }

  // ════════════════════════════════════════════════════════════════
  // PUBLIC (anon) — first-class API surface
  // ════════════════════════════════════════════════════════════════

  const publicApi = {
    async getConfig(slug) {
      if (!slug) return { ok: false, error: 'no_slug', enabled: false };
      // Public — no plan check on client (server enforces)
      const sb = _sb(); if (!sb) return { ok: false, error: 'no_sb', enabled: false };
      try {
        const { data, error } = await sb.rpc('sbp_get_appointment_config_public', { p_slug: slug });
        if (error) return { ok: false, error: error.message, enabled: false };
        return data || { ok: false, error: 'no_response', enabled: false };
      } catch (e) {
        return { ok: false, error: String(e), enabled: false };
      }
    },

    async getSlots(slug, providerId, dateStr, durationMinutes) {
      if (!slug || !providerId || !dateStr || !durationMinutes) {
        return { ok: false, error: 'missing_params', slots: [] };
      }
      const sb = _sb(); if (!sb) return { ok: false, error: 'no_sb', slots: [] };
      try {
        const { data, error } = await sb.rpc('sbp_get_available_slots_public', {
          p_slug: slug,
          p_provider_id: providerId,
          p_date: dateStr,
          p_duration_minutes: durationMinutes
        });
        if (error) return { ok: false, error: error.message, slots: [] };
        return data || { ok: false, error: 'no_response', slots: [] };
      } catch (e) {
        return { ok: false, error: String(e), slots: [] };
      }
    },

    async book(slug, data) {
      if (!slug) return { ok: false, error: 'no_slug' };
      const sb = _sb(); if (!sb) return { ok: false, error: 'no_sb' };
      try {
        const { data: res, error } = await sb.rpc('sbp_book_appointment_public', {
          p_slug: slug,
          p_data: data || {}
        });
        if (error) return { ok: false, error: error.message };
        return res || { ok: false, error: 'no_response' };
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    },

    async getStatus(appointmentId, phone) {
      if (!appointmentId || !phone) return { ok: false, error: 'missing_params' };
      const sb = _sb(); if (!sb) return { ok: false, error: 'no_sb' };
      try {
        const { data, error } = await sb.rpc('sbp_get_appointment_status_public', {
          p_appointment_id: appointmentId,
          p_phone: phone
        });
        if (error) return { ok: false, error: error.message };
        return data || { ok: false, error: 'no_response' };
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    }
  };

  // ════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ════════════════════════════════════════════════════════════════

  global.SBPAppt = {
    providers: providers,
    blocks: blocks,
    list: list,
    create: create,
    update: update,
    setStatus: setStatus,
    public: publicApi,
    isBiz: _isBiz
  };

})(typeof window !== 'undefined' ? window : this);
