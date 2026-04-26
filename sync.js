/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Offline Sync Engine
   Queues changes when offline, syncs when online
══════════════════════════════════════════════════════════════════ */

const SyncEngine = (() => {

  const QUEUE_KEY = 'sbp_sync_queue';
  const MAX_RETRIES = 5;  // FIX #31 — cap retries

  function _getQueue() { return JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]'); }
  function _saveQueue(q) { localStorage.setItem(QUEUE_KEY, JSON.stringify(q)); }

  function enqueue(action, data) {
    const queue = _getQueue();
    // FIX #32 — collision-resistant ID
    const uniq = 'q_' + Date.now() + '_' + Math.random().toString(36).slice(2,8);
    queue.push({ action, data, ts: Date.now(), id: uniq, retries: 0 });
    _saveQueue(queue);
    _updateSyncBar(queue.length);
  }

  async function processQueue() {
    const queue = _getQueue();
    if (!queue.length) { _updateSyncBar(0); return; }

    // FIX #30 — Verify auth before attempting sync
    if (!_sb) return;
    try {
      const { data: { session } } = await _sb.auth.getSession();
      if (!session) {
        if(typeof UI !== 'undefined' && UI.toast) UI.toast('🔒 Sign in to sync offline changes', 'info');
        return;
      }
    } catch(e) { console.warn('Auth check failed:', e); return; }

    const bar = document.getElementById('offline-bar');
    if (bar) { bar.textContent = `🔄 Syncing ${queue.length} change${queue.length > 1 ? 's' : ''}...`; bar.className = 'syncing'; }

    const stillPending = [];
    const dropped = [];

    for (const item of queue) {
      try {
        await _processItem(item);
      } catch (err) {
        item.retries = (item.retries || 0) + 1;
        item.lastError = err.message || String(err);
        console.warn('Sync failed for', item.action, '(retry', item.retries+'/'+MAX_RETRIES+')', err.message);
        if(item.retries >= MAX_RETRIES){
          dropped.push(item);  // FIX #31 — drop after max retries to unblock queue
        } else {
          stillPending.push(item);
        }
      }
    }

    _saveQueue(stillPending);
    if(dropped.length){
      // Save to dead-letter so we don't lose them silently
      const dead = JSON.parse(localStorage.getItem('sbp_sync_dead') || '[]');
      localStorage.setItem('sbp_sync_dead', JSON.stringify(dead.concat(dropped)));
    }

    if (bar) {
      if (stillPending.length) {
        bar.textContent = `⚠️ ${stillPending.length} change${stillPending.length > 1 ? 's' : ''} pending sync`;
        bar.className = 'offline';
      } else {
        bar.className = '';
        setTimeout(() => { if (bar.className === '') bar.style.display = 'none'; }, 2000);
      }
    }

    if (!stillPending.length && typeof UI !== 'undefined' && UI.toast) UI.toast('☁️ All changes synced!', 'success');
    if (dropped.length && typeof UI !== 'undefined' && UI.toast) UI.toast(`⚠️ ${dropped.length} change${dropped.length>1?'s':''} could not sync after ${MAX_RETRIES} attempts`, 'error');
  }

  async function _processItem(item) {
    const shopId = window.SBP?.shopId;
    let res;
    switch (item.action) {
      // ── Customers ──
      case 'CREATE_CUSTOMER':
        res = await _sb.from('customers').insert({ ...item.data, shop_id: shopId }); break;
      case 'UPDATE_CUSTOMER':
        res = await _sb.from('customers').update(item.data).eq('id', item.data.id); break;
      case 'UPDATE_CUSTOMER_BALANCE':
        res = await _sb.from('customers').update({balance: item.data.balance}).eq('id', item.data.id); break;
      case 'DELETE_CUSTOMER':
        res = await _sb.from('customers').delete().eq('id', item.data.id); break;

      // ── Bills ── (FIX #29 — handlers were missing)
      case 'CREATE_BILL': {
        const { data: bill, error } = await _sb.from('bills').insert({ ...item.data.bill, shop_id: shopId }).select().single();
        if (error) throw error;
        if (bill && item.data.items?.length) {
          await _sb.from('bill_items').insert(item.data.items.map(i => ({ ...i, bill_id: bill.id })));
        }
        return;
      }
      case 'UPDATE_BILL':
        res = await _sb.from('bills').update(item.data.changes).eq('id', item.data.id); break;
      case 'VOID_BILL':
        res = await _sb.from('bills').update({status:'Voided', voided_at: item.data.voided_at, voided_by: item.data.voided_by}).eq('id', item.data.id); break;
      case 'REOPEN_BILL':
        res = await _sb.from('bills').update({status:'Pending', paid_amount:0, balance_due: item.data.balance_due, reopened_at: item.data.reopened_at}).eq('id', item.data.id); break;
      case 'DELETE_BILL':
        res = await _sb.from('bills').delete().eq('id', item.data.id); break;
      case 'RECORD_PAYMENT': {
        await _sb.from('bills').update({paid_amount: item.data.paid_amount, balance_due: item.data.balance_due, status: item.data.status, payment_mode: item.data.payment_mode}).eq('id', item.data.bill_id);
        await _sb.from('payments').insert({bill_id: item.data.bill_id, shop_id: shopId, amount: item.data.amount, payment_mode: item.data.payment_mode, payment_date: item.data.payment_date});
        return;
      }

      // ── Products ──
      case 'CREATE_PRODUCT':
        res = await _sb.from('products').insert({ ...item.data, shop_id: shopId }); break;
      case 'UPDATE_PRODUCT':
        res = await _sb.from('products').update(item.data).eq('id', item.data.id); break;
      case 'UPDATE_PRODUCT_STOCK':
        res = await _sb.from('products').update({ stock_qty: item.data.stock_qty }).eq('id', item.data.id); break;
      case 'DELETE_PRODUCT':
        res = await _sb.from('products').delete().eq('id', item.data.id); break;

      // ── Suppliers ──
      case 'CREATE_SUPPLIER':
        res = await _sb.from('suppliers').insert({ ...item.data, shop_id: shopId }); break;
      case 'UPDATE_SUPPLIER':
        res = await _sb.from('suppliers').update(item.data).eq('id', item.data.id); break;

      // ── Misc ──
      case 'CREATE_EXPENSE':
        res = await _sb.from('expenses').insert({ ...item.data, shop_id: shopId }); break;
      case 'UPDATE_SHOP':
        res = await _sb.from('shops').update(item.data).eq('id', item.data.id); break;

      default:
        throw new Error('Unknown sync action: ' + item.action);
    }
    // FIX #33 — Catch Supabase error responses (not exceptions)
    if (res && res.error) throw res.error;
  }

  function _updateSyncBar(count) {
    const bar = document.getElementById('offline-bar');
    if (!bar) return;
    if (count > 0 && !window.SBP?.online) {
      bar.textContent = `📶 Offline — ${count} change${count > 1 ? 's' : ''} pending sync`;
      bar.className = 'offline';
    }
  }

  function getPendingCount() { return _getQueue().length; }
  function getDeadCount() { return JSON.parse(localStorage.getItem('sbp_sync_dead') || '[]').length; }
  function clearDead() { localStorage.removeItem('sbp_sync_dead'); }

  // FIX #34 — Auto-sync when network returns
  if(typeof window !== 'undefined'){
    window.addEventListener('online', () => {
      if(window.SBP) window.SBP.online = true;
      setTimeout(processQueue, 500);
    });
    window.addEventListener('offline', () => {
      if(window.SBP) window.SBP.online = false;
      _updateSyncBar(_getQueue().length);
    });
  }

  return { enqueue, processQueue, getPendingCount, getDeadCount, clearDead };
})();

window.SyncEngine = SyncEngine;
