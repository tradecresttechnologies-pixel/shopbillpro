/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Hospitality (rooms + bookings + folio) v1.1
   ShopBill Pro is a product of TradeCrest Technologies Pvt. Ltd.

   Wraps the 015_hospitality.sql RPCs for use by:
     - rooms.html (room types + room inventory)
     - bookings.html (booking lifecycle + folio extras)

   API:
     SBPHotel.summary(shopId)
     SBPHotel.roomTypes.list/upsert/delete(shopId, ...)
     SBPHotel.rooms.list/upsert/delete/checkAvailability(shopId, ...)
     SBPHotel.bookings.list(shopId, filter, statusFilter)
     SBPHotel.bookings.create(shopId, data)
     SBPHotel.bookings.checkIn/checkOut/cancel(shopId, bookingId, reason?, authPin?)
     SBPHotel.bookings.linkBill(shopId, bookingId, billId)
     SBPHotel.extras.list/add(shopId, ...)
     SBPHotel.extras.remove(shopId, extraId, reason?, authPin?)

   v1.1 — 022D-B-3a — bookings.cancel and extras.remove now accept
   optional `reason` + `authPin` (passed through to PIN-gated RPCs).
   When the shop has `require_auth_for_high_risk = false`, these are
   ignored server-side, so existing call-sites continue working.

   Plan gating: hospitality is Pro/Business only — server enforces.
   Client should pre-check via window.isPro() before showing UI.

   Requires: window._sb (Supabase client). Same pattern as lib/loyalty.js.
══════════════════════════════════════════════════════════════════ */

(function (global) {
  'use strict';

  function _sb(){ return global._sb || null; }

  async function _rpc(name, args){
    const sb = _sb();
    if (!sb) return { ok: false, error: 'no_supabase' };
    try {
      const { data, error } = await sb.rpc(name, args);
      if (error) return { ok: false, error: error.message || String(error) };
      if (!data) return { ok: false, error: 'no_data' };
      return data;
    } catch (e) {
      return { ok: false, error: e?.message || String(e) };
    }
  }

  // ── Summary ───────────────────────────────────────────────────────
  async function summary(shopId){
    return _rpc('sbp_hospitality_summary', { p_shop_id: shopId });
  }

  // ── Room Types ────────────────────────────────────────────────────
  const roomTypes = {
    list:    (shopId)         => _rpc('sbp_room_types_list',   { p_shop_id: shopId }),
    upsert:  (shopId, data)   => _rpc('sbp_room_types_upsert', { p_shop_id: shopId, p_data: data }),
    delete:  (shopId, rtId)   => _rpc('sbp_room_types_delete', { p_shop_id: shopId, p_room_type_id: rtId })
  };

  // ── Rooms ─────────────────────────────────────────────────────────
  const rooms = {
    list:    (shopId)             => _rpc('sbp_rooms_list',   { p_shop_id: shopId }),
    upsert:  (shopId, data)       => _rpc('sbp_rooms_upsert', { p_shop_id: shopId, p_data: data }),
    delete:  (shopId, rId)        => _rpc('sbp_rooms_delete', { p_shop_id: shopId, p_room_id: rId }),
    checkAvailability: (shopId, checkIn, checkOut, roomTypeId, excludeBookingId) => _rpc('sbp_rooms_check_availability', {
      p_shop_id:            shopId,
      p_check_in:           checkIn,
      p_check_out:          checkOut,
      p_room_type_id:       roomTypeId || null,
      p_exclude_booking_id: excludeBookingId || null
    })
  };

  // ── Bookings ──────────────────────────────────────────────────────
  const bookings = {
    list:     (shopId, filter, statusFilter) => _rpc('sbp_bookings_list', {
      p_shop_id:        shopId,
      p_filter:         filter || 'upcoming',
      p_status_filter:  statusFilter || null
    }),
    create:   (shopId, data)      => _rpc('sbp_bookings_create',    { p_shop_id: shopId, p_data: data }),
    checkIn:  (shopId, bId)       => _rpc('sbp_bookings_check_in',  { p_shop_id: shopId, p_booking_id: bId }),
    checkOut: (shopId, bId)       => _rpc('sbp_bookings_check_out', { p_shop_id: shopId, p_booking_id: bId }),
    cancel:   (shopId, bId, reason, authPin) => _rpc('sbp_bookings_cancel',  { p_shop_id: shopId, p_booking_id: bId, p_reason: reason || null, p_auth_pin: authPin || null }),
    linkBill: (shopId, bId, billId) => _rpc('sbp_bookings_link_bill', { p_shop_id: shopId, p_booking_id: bId, p_bill_id: billId })
  };

  // ── Folio Extras ──────────────────────────────────────────────────
  const extras = {
    list:    (shopId, bId)        => _rpc('sbp_booking_extras_list',   { p_shop_id: shopId, p_booking_id: bId }),
    add:     (shopId, bId, data)  => _rpc('sbp_booking_extras_add',    { p_shop_id: shopId, p_booking_id: bId, p_data: data }),
    remove:  (shopId, extraId, reason, authPin) => _rpc('sbp_booking_extras_remove', { p_shop_id: shopId, p_extra_id: extraId, p_reason: reason || null, p_auth_pin: authPin || null })
  };

  // ── Helpers ───────────────────────────────────────────────────────
  function nightsBetween(checkIn, checkOut){
    if (!checkIn || !checkOut) return 0;
    const a = new Date(checkIn + 'T00:00:00');
    const b = new Date(checkOut + 'T00:00:00');
    return Math.max(0, Math.round((b - a) / 86400000));
  }

  // Batch 021: client-side mirror of sbp_hotel_room_gst_for_rate.
  // Indian statutory slabs (post 22 Sep 2025 GST reform):
  //   ≤ ₹1,000  → 0% (exempt)
  //   ≤ ₹7,500  → 5% (no ITC)
  //   > ₹7,500  → 18% (with ITC)
  function roomGstForRate(rate){
    const r = parseFloat(rate || 0);
    if (r <= 0)   return 0;
    if (r <= 1000) return 0;
    if (r <= 7500) return 5;
    return 18;
  }

  // Mirror of sbp_hotel_extra_gst_for_category. Defaults assume "non-specified
  // premises" (rooms < ₹7,500/night) — i.e. our 1-3 star target customer.
  function extraGstForCategory(category){
    const c = String(category || '').toLowerCase();
    switch(c){
      case 'food':      return 5;
      case 'transport': return 5;
      case 'laundry':
      case 'minibar':
      case 'service':
      case 'telephone':
      case 'other':     return 18;
      default:          return 18;
    }
  }

  function hsnForCategory(category){
    const c = String(category || '').toLowerCase();
    switch(c){
      case 'food':      return '996331';
      case 'minibar':   return '996331';
      case 'laundry':   return '999719';
      case 'service':   return '999722';
      case 'telephone': return '998414';
      case 'transport': return '996412';
      default:          return null;
    }
  }

  function statusBadgeColor(status){
    return ({
      pending:      { bg: 'rgba(245,166,35,.15)', fg: '#F5A623', label: 'Pending'    },
      confirmed:    { bg: 'rgba(59,130,246,.15)', fg: '#3B82F6', label: 'Confirmed'  },
      checked_in:   { bg: 'rgba(16,185,129,.15)', fg: '#10B981', label: 'In-house'   },
      checked_out:  { bg: 'rgba(138,138,168,.15)',fg: '#8A8AA8', label: 'Checked out'},
      cancelled:    { bg: 'rgba(244,63,94,.15)',  fg: '#F43F5E', label: 'Cancelled'  },
      no_show:      { bg: 'rgba(244,63,94,.15)',  fg: '#F43F5E', label: 'No show'    }
    }[status] || { bg: 'rgba(138,138,168,.15)', fg: '#8A8AA8', label: status });
  }

  // ── Export ────────────────────────────────────────────────────────
  global.SBPHotel = {
    summary,
    roomTypes,
    rooms,
    bookings,
    extras,
    nightsBetween,
    statusBadgeColor,
    // Batch 021 — GST helpers
    roomGstForRate,
    extraGstForCategory,
    hsnForCategory
  };

})(window);
