/* ════════════════════════════════════════════════════════════════════
   lib/reservation-state.js  —  Shop reservation state helper

   Exposes window.SBPReservationState with:
     • loadBlockedTables(shopId)     — fetch + cache blocked-table map
     • getBlockForTable(tableId)     — returns block info { reservation_id,
       guest_name, party_size, expected_at, block_starts_at, block_ends_at,
       phone, notified } OR null
     • formatBlockBadge(block)       — human-friendly badge text
     • clearCache()                  — invalidate (call after reservation
                                       changes)

   Used by:
     • tables.html  — overlay "reserved-window" badge on table cards
     • walk-in.html — warn before assigning a blocked table
     • reservations.html — share single source of truth

   Cache TTL: 60 seconds. Refresh on visibilitychange.
   ════════════════════════════════════════════════════════════════════ */
(function (root) {
  'use strict';

  const CACHE_TTL_MS = 60 * 1000;
  let _cache = null;        // { fetchedAt, byTableId, all }
  let _shopId = null;

  async function _fetch(shopId) {
    if (!root._sb) {
      console.warn('[reservation-state] window._sb not available');
      return null;
    }
    try {
      const { data, error } = await root._sb.rpc('sbp_reservations_blocked_tables', {
        p_shop_id: shopId
      });
      if (error) {
        console.warn('[reservation-state] RPC error:', error.message);
        return null;
      }
      if (!data || !data.ok) {
        console.warn('[reservation-state] RPC returned not ok:', data);
        return null;
      }
      return data.blocked || [];
    } catch (e) {
      console.error('[reservation-state] fetch threw:', e);
      return null;
    }
  }

  async function loadBlockedTables(shopId, opts) {
    opts = opts || {};
    const force = !!opts.force;
    const now = Date.now();
    if (!force && _cache && _shopId === shopId && (now - _cache.fetchedAt) < CACHE_TTL_MS) {
      return _cache;
    }
    const blocked = await _fetch(shopId);
    if (blocked === null) {
      // Failed to fetch — return existing cache if any, else empty
      return _cache || { fetchedAt: now, byTableId: {}, all: [] };
    }
    const byTableId = {};
    blocked.forEach(function (b) {
      if (b && b.table_id) {
        byTableId[String(b.table_id)] = b;
      }
    });
    _cache = { fetchedAt: now, byTableId: byTableId, all: blocked };
    _shopId = shopId;
    return _cache;
  }

  function getBlockForTable(tableId) {
    if (!_cache || !tableId) return null;
    return _cache.byTableId[String(tableId)] || null;
  }

  function formatBlockBadge(block) {
    if (!block) return '';
    let timeStr = '';
    try {
      const d = new Date(block.expected_at);
      const hh = d.getHours();
      const mm = String(d.getMinutes()).padStart(2, '0');
      const period = hh >= 12 ? 'PM' : 'AM';
      const hh12 = ((hh + 11) % 12) + 1;
      timeStr = hh12 + ':' + mm + ' ' + period;
    } catch (_) {
      timeStr = '—';
    }
    const name = block.guest_name || 'Guest';
    const party = block.party_size ? ' (' + block.party_size + ')' : '';
    return 'Reserved ' + timeStr + ' — ' + name + party;
  }

  function formatBlockTooltip(block) {
    if (!block) return '';
    let timeStr = '', endStr = '';
    try {
      const e = new Date(block.expected_at);
      const t = new Date(block.block_ends_at);
      timeStr = e.toLocaleString('en-IN', { dateStyle: 'short', timeStyle: 'short' });
      endStr  = t.toLocaleString('en-IN', { dateStyle: 'short', timeStyle: 'short' });
    } catch (_) {}
    return 'Reservation: ' + (block.guest_name || 'Guest') +
           ' for ' + (block.party_size || '?') + '\n' +
           'Expected: ' + timeStr + '\n' +
           'Block ends: ' + endStr;
  }

  function clearCache() {
    _cache = null;
    _shopId = null;
  }

  // Auto-refresh when tab becomes visible (someone returns to it after a while)
  if (typeof document !== 'undefined' && document.addEventListener) {
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && _shopId) {
        // Force refresh on next loadBlockedTables call
        if (_cache) _cache.fetchedAt = 0;
      }
    });
  }

  root.SBPReservationState = {
    loadBlockedTables: loadBlockedTables,
    getBlockForTable:  getBlockForTable,
    formatBlockBadge:  formatBlockBadge,
    formatBlockTooltip: formatBlockTooltip,
    clearCache:        clearCache
  };
})(window);
