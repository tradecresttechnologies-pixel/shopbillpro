/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — IndexedDB Local Database
   Mirrors Supabase schema for full offline support
   TradeCrest Technologies Pvt. Ltd.
══════════════════════════════════════════════════════════════════ */

const DBLocal = (() => {

  const DB_NAME    = 'shopbillpro_db';
  const DB_VERSION = 1;
  let _db = null;

  /* ── Open / Init IndexedDB ── */
  function open() {
    return new Promise((resolve, reject) => {
      if (_db) { resolve(_db); return; }

      const req = indexedDB.open(DB_NAME, DB_VERSION);

      req.onupgradeneeded = (e) => {
        const db = e.target.result;

        // shops
        if (!db.objectStoreNames.contains('shops')) {
          db.createObjectStore('shops', { keyPath: 'id' });
        }

        // customers
        if (!db.objectStoreNames.contains('customers')) {
          const cs = db.createObjectStore('customers', { keyPath: 'id' });
          cs.createIndex('shop_id', 'shop_id', { unique: false });
          cs.createIndex('name',    'name',    { unique: false });
        }

        // bills
        if (!db.objectStoreNames.contains('bills')) {
          const bs = db.createObjectStore('bills', { keyPath: 'id' });
          bs.createIndex('shop_id',      'shop_id',      { unique: false });
          bs.createIndex('status',       'status',       { unique: false });
          bs.createIndex('invoice_date', 'invoice_date', { unique: false });
        }

        // bill_items
        if (!db.objectStoreNames.contains('bill_items')) {
          const bi = db.createObjectStore('bill_items', { keyPath: 'id', autoIncrement: true });
          bi.createIndex('bill_id', 'bill_id', { unique: false });
        }

        // products
        if (!db.objectStoreNames.contains('products')) {
          const ps = db.createObjectStore('products', { keyPath: 'id' });
          ps.createIndex('shop_id',  'shop_id',  { unique: false });
          ps.createIndex('category', 'category', { unique: false });
        }

        // expenses
        if (!db.objectStoreNames.contains('expenses')) {
          const es = db.createObjectStore('expenses', { keyPath: 'id' });
          es.createIndex('shop_id',      'shop_id',      { unique: false });
          es.createIndex('expense_date', 'expense_date', { unique: false });
        }

        // payments
        if (!db.objectStoreNames.contains('payments')) {
          const pms = db.createObjectStore('payments', { keyPath: 'id', autoIncrement: true });
          pms.createIndex('bill_id', 'bill_id', { unique: false });
        }

        // sync_queue — pending offline changes
        if (!db.objectStoreNames.contains('sync_queue')) {
          const sq = db.createObjectStore('sync_queue', { keyPath: 'id', autoIncrement: true });
          sq.createIndex('action', 'action', { unique: false });
          sq.createIndex('ts',     'ts',     { unique: false });
        }
      };

      req.onsuccess = (e) => { _db = e.target.result; resolve(_db); };
      req.onerror   = (e) => { reject(e.target.error); };
    });
  }

  /* ── Generic helpers ── */
  async function _store(storeName, mode = 'readonly') {
    const db = await open();
    return db.transaction(storeName, mode).objectStore(storeName);
  }

  function _req(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = (e) => resolve(e.target.result);
      request.onerror   = (e) => reject(e.target.error);
    });
  }

  async function getAll(storeName, indexName = null, value = null) {
    const store = await _store(storeName);
    if (indexName && value !== null) {
      return _req(store.index(indexName).getAll(value));
    }
    return _req(store.getAll());
  }

  async function getOne(storeName, id) {
    const store = await _store(storeName);
    return _req(store.get(id));
  }

  async function put(storeName, data) {
    const store = await _store(storeName, 'readwrite');
    return _req(store.put(data));
  }

  async function putMany(storeName, items) {
    const db  = await open();
    const tx  = db.transaction(storeName, 'readwrite');
    const st  = tx.objectStore(storeName);
    for (const item of items) st.put(item);
    return new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = rej; });
  }

  async function remove(storeName, id) {
    const store = await _store(storeName, 'readwrite');
    return _req(store.delete(id));
  }

  async function clear(storeName) {
    const store = await _store(storeName, 'readwrite');
    return _req(store.clear());
  }

  async function count(storeName) {
    const store = await _store(storeName);
    return _req(store.count());
  }

  /* ════════════════════════════════════
     SHOP
  ════════════════════════════════════ */
  async function saveShop(shop) {
    await put('shops', shop);
  }

  async function getShop(id) {
    return getOne('shops', id);
  }

  /* ════════════════════════════════════
     CUSTOMERS
  ════════════════════════════════════ */
  async function saveCustomers(customers) {
    await putMany('customers', customers);
  }

  async function saveCustomer(customer) {
    await put('customers', customer);
  }

  async function getCustomers(shopId) {
    const all = await getAll('customers', 'shop_id', shopId);
    return all.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  }

  async function getCustomer(id) {
    return getOne('customers', id);
  }

  async function deleteCustomer(id) {
    await remove('customers', id);
  }

  async function searchCustomers(shopId, query) {
    const all = await getCustomers(shopId);
    if (!query) return all;
    const q = query.toLowerCase();
    return all.filter(c =>
      c.name?.toLowerCase().includes(q) ||
      c.whatsapp?.includes(q) ||
      c.phone?.includes(q) ||
      c.email?.toLowerCase().includes(q)
    );
  }

  /* ════════════════════════════════════
     BILLS
  ════════════════════════════════════ */
  async function saveBills(bills) {
    await putMany('bills', bills);
  }

  async function saveBill(bill) {
    await put('bills', bill);
  }

  async function getBills(shopId, filter = 'all') {
    const all = await getAll('bills', 'shop_id', shopId);
    const sorted = all.sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
    if (filter === 'all') return sorted;
    return sorted.filter(b => b.status === filter);
  }

  async function getBill(id) {
    return getOne('bills', id);
  }

  async function getBillsByCustomer(shopId, customerId) {
    const all = await getBills(shopId);
    return all.filter(b => b.customer_id === customerId || b.customer_name === customerId);
  }

  async function deleteBill(id) {
    await remove('bills', id);
    // Also delete related items
    const items = await getBillItems(id);
    for (const item of items) {
      if (item.id) await remove('bill_items', item.id);
    }
  }

  /* ════════════════════════════════════
     BILL ITEMS
  ════════════════════════════════════ */
  async function saveBillItems(billId, items) {
    const db = await open();
    const tx = db.transaction('bill_items', 'readwrite');
    const st = tx.objectStore('bill_items');
    for (const item of items) st.put({ ...item, bill_id: billId });
    return new Promise((res, rej) => { tx.oncomplete = res; tx.onerror = rej; });
  }

  async function getBillItems(billId) {
    return getAll('bill_items', 'bill_id', billId);
  }

  /* ════════════════════════════════════
     PRODUCTS
  ════════════════════════════════════ */
  async function saveProducts(products) {
    await putMany('products', products);
  }

  async function saveProduct(product) {
    await put('products', product);
  }

  async function getProducts(shopId, category = '') {
    const all = await getAll('products', 'shop_id', shopId);
    const sorted = all.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
    if (!category) return sorted;
    return sorted.filter(p => p.category === category);
  }

  async function getProduct(id) {
    return getOne('products', id);
  }

  async function deleteProduct(id) {
    await remove('products', id);
  }

  async function searchProducts(shopId, query) {
    const all = await getProducts(shopId);
    if (!query) return all;
    const q = query.toLowerCase();
    return all.filter(p =>
      p.name?.toLowerCase().includes(q) ||
      p.code?.toLowerCase().includes(q)
    );
  }

  /* ════════════════════════════════════
     EXPENSES
  ════════════════════════════════════ */
  async function saveExpenses(expenses) {
    await putMany('expenses', expenses);
  }

  async function saveExpense(expense) {
    await put('expenses', expense);
  }

  async function getExpenses(shopId) {
    const all = await getAll('expenses', 'shop_id', shopId);
    return all.sort((a, b) => new Date(b.expense_date || 0) - new Date(a.expense_date || 0));
  }

  async function deleteExpense(id) {
    await remove('expenses', id);
  }

  /* ════════════════════════════════════
     PAYMENTS
  ════════════════════════════════════ */
  async function savePayment(payment) {
    await put('payments', payment);
  }

  async function getPayments(billId) {
    return getAll('payments', 'bill_id', billId);
  }

  /* ════════════════════════════════════
     SYNC QUEUE
  ════════════════════════════════════ */
  async function enqueueSync(action, data) {
    const store = await _store('sync_queue', 'readwrite');
    return _req(store.add({ action, data, ts: Date.now(), retries: 0 }));
  }

  async function getSyncQueue() {
    return getAll('sync_queue');
  }

  async function removeSyncItem(id) {
    await remove('sync_queue', id);
  }

  async function clearSyncQueue() {
    await clear('sync_queue');
  }

  async function getSyncQueueCount() {
    return count('sync_queue');
  }

  /* ════════════════════════════════════
     FULL SYNC — Supabase → IndexedDB
     Call after login to populate local DB
  ════════════════════════════════════ */
  async function syncFromSupabase(sb, shopId) {
    try {
      const [custRes, billRes, prodRes, expRes] = await Promise.all([
        sb.from('customers').select('*').eq('shop_id', shopId),
        sb.from('bills').select('*, bill_items(*)').eq('shop_id', shopId).order('created_at', { ascending: false }).limit(200),
        sb.from('products').select('*').eq('shop_id', shopId),
        sb.from('expenses').select('*').eq('shop_id', shopId).order('expense_date', { ascending: false }).limit(200)
      ]);

      if (custRes.data?.length) await saveCustomers(custRes.data);
      if (prodRes.data?.length) await saveProducts(prodRes.data);
      if (expRes.data?.length)  await saveExpenses(expRes.data);

      if (billRes.data?.length) {
        for (const bill of billRes.data) {
          const items = bill.bill_items || [];
          delete bill.bill_items;
          await saveBill(bill);
          if (items.length) await saveBillItems(bill.id, items);
        }
      }

      console.log('✅ IndexedDB synced from Supabase');
      return true;
    } catch (err) {
      console.warn('IndexedDB sync error:', err.message);
      return false;
    }
  }

  /* ── Fallback: migrate from localStorage to IndexedDB ── */
  async function migrateFromLocalStorage(shopId) {
    try {
      const custs = JSON.parse(localStorage.getItem('sbp_customers') || '[]');
      const bills = JSON.parse(localStorage.getItem('sbp_bills')     || '[]');
      const prods = JSON.parse(localStorage.getItem('sbp_products')  || '[]');
      const exps  = JSON.parse(localStorage.getItem('sbp_expenses')  || '[]');

      if (custs.length) await saveCustomers(custs);
      if (prods.length) await saveProducts(prods);
      if (exps.length)  await saveExpenses(exps);
      if (bills.length) {
        for (const bill of bills) {
          const items = bill.bill_items || [];
          const cleanBill = { ...bill };
          delete cleanBill.bill_items;
          await saveBill(cleanBill);
          if (items.length) await saveBillItems(bill.id, items);
        }
      }
      console.log('✅ Migrated from localStorage to IndexedDB');
    } catch (err) {
      console.warn('Migration error:', err.message);
    }
  }

  /* ── Clear all local data (on logout) ── */
  async function clearAll() {
    const stores = ['customers','bills','bill_items','products','expenses','payments','sync_queue'];
    for (const s of stores) await clear(s);
  }

  /* ── Get DB stats ── */
  async function getStats() {
    const [c, b, p, e, q] = await Promise.all([
      count('customers'), count('bills'), count('products'),
      count('expenses'),  count('sync_queue')
    ]);
    return { customers: c, bills: b, products: p, expenses: e, pendingSync: q };
  }

  /* ── Public API ── */
  return {
    open,
    // Shop
    saveShop, getShop,
    // Customers
    saveCustomers, saveCustomer, getCustomers, getCustomer, deleteCustomer, searchCustomers,
    // Bills
    saveBills, saveBill, getBills, getBill, getBillsByCustomer, deleteBill,
    // Bill Items
    saveBillItems, getBillItems,
    // Products
    saveProducts, saveProduct, getProducts, getProduct, deleteProduct, searchProducts,
    // Expenses
    saveExpenses, saveExpense, getExpenses, deleteExpense,
    // Payments
    savePayment, getPayments,
    // Sync Queue
    enqueueSync, getSyncQueue, removeSyncItem, clearSyncQueue, getSyncQueueCount,
    // Utility
    syncFromSupabase, migrateFromLocalStorage, clearAll, getStats
  };

})();

window.DBLocal = DBLocal;
