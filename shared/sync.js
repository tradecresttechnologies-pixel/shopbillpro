/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Offline Sync Engine
   Queues changes when offline, syncs when online
══════════════════════════════════════════════════════════════════ */

const SyncEngine = (() => {

  const QUEUE_KEY = 'sbp_sync_queue';

  function _getQueue() { return JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]'); }
  function _saveQueue(q) { localStorage.setItem(QUEUE_KEY, JSON.stringify(q)); }

  function enqueue(action, data) {
    const queue = _getQueue();
    queue.push({ action, data, ts: Date.now(), id: 'q_' + Date.now() });
    _saveQueue(queue);
    _updateSyncBar(queue.length);
  }

  async function processQueue() {
    const queue = _getQueue();
    if (!queue.length) { _updateSyncBar(0); return; }

    const bar = document.getElementById('offline-bar');
    if (bar) { bar.textContent = `🔄 Syncing ${queue.length} change${queue.length > 1 ? 's' : ''}...`; bar.className = 'syncing'; }

    const failed = [];

    for (const item of queue) {
      try {
        await _processItem(item);
      } catch (err) {
        console.warn('Sync failed for', item.action, err.message);
        failed.push(item);
      }
    }

    _saveQueue(failed);

    if (bar) {
      if (failed.length) {
        bar.textContent = `⚠️ ${failed.length} change${failed.length > 1 ? 's' : ''} pending sync`;
        bar.className = 'offline';
      } else {
        bar.className = '';
        setTimeout(() => { if (bar.className === '') bar.style.display = 'none'; }, 2000);
      }
    }

    if (!failed.length) UI.toast('☁️ All changes synced!', 'success');
  }

  async function _processItem(item) {
    const shopId = window.SBP?.shopId;
    switch (item.action) {
      case 'CREATE_CUSTOMER':
        await _sb.from('customers').insert({ ...item.data, shop_id: shopId });
        break;
      case 'UPDATE_CUSTOMER':
        await _sb.from('customers').update(item.data).eq('id', item.data.id);
        break;
      case 'DELETE_CUSTOMER':
        await _sb.from('customers').delete().eq('id', item.data.id);
        break;
      case 'CREATE_BILL':
        const { data: bill } = await _sb.from('bills').insert({ ...item.data.bill, shop_id: shopId }).select().single();
        if (bill && item.data.items?.length) {
          await _sb.from('bill_items').insert(item.data.items.map(i => ({ ...i, bill_id: bill.id })));
        }
        break;
      case 'CREATE_PRODUCT':
        await _sb.from('products').insert({ ...item.data, shop_id: shopId });
        break;
      case 'UPDATE_PRODUCT':
        await _sb.from('products').update(item.data).eq('id', item.data.id);
        break;
      case 'CREATE_EXPENSE':
        await _sb.from('expenses').insert({ ...item.data, shop_id: shopId });
        break;
      case 'UPDATE_SHOP':
        await _sb.from('shops').update(item.data).eq('id', item.data.id);
        break;
      case 'UPDATE_PRODUCT':
        await _sb.from('products').update(item.data).eq('id', item.data.id);
        break;
      case 'UPDATE_PRODUCT_STOCK':
        await _sb.from('products').update({ stock_qty: item.data.stock_qty }).eq('id', item.data.id);
        break;
      case 'CREATE_SUPPLIER':
        await _sb.from('suppliers').insert({ ...item.data, shop_id: shopId });
        break;
      case 'UPDATE_SUPPLIER':
        await _sb.from('suppliers').update(item.data).eq('id', item.data.id);
        break;
    }
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

  return { enqueue, processQueue, getPendingCount };
})();

window.SyncEngine = SyncEngine;
