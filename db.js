/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Database Module
   All Supabase CRUD operations + local fallback
   Tables: shops, customers, bills, bill_items, payments, products, expenses
══════════════════════════════════════════════════════════════════ */

const DB = (() => {

  /* ── Helper: get shop_id ── */
  function _shopId() { return window.SBP?.shopId; }
  function _online()  { return window.SBP?.online !== false; }

  /* ── Generic error handler ── */
  function _handle(error, fallback = null) {
    if (error) {
      console.error('DB Error:', error.message);
      if (!_online()) UI.toast('📶 Offline — saved locally', 'info');
      return fallback;
    }
  }

  /* ════════════════════════════════════
     SHOP
  ════════════════════════════════════ */

  async function getShop() {
    if (!_shopId()) return null;
    const cached = localStorage.getItem('sbp_shop');

    if (!_online() && cached) return JSON.parse(cached);

    const { data, error } = await _sb.from('shops').select('*').eq('id', _shopId()).single();
    if (error) return cached ? JSON.parse(cached) : null;

    localStorage.setItem('sbp_shop', JSON.stringify(data));
    window.SBP.shop = data;
    return data;
  }

  async function updateShop(updates) {
    localStorage.setItem('sbp_shop', JSON.stringify({ ...window.SBP.shop, ...updates }));
    window.SBP.shop = { ...window.SBP.shop, ...updates };

    if (!_online()) {
      SyncEngine.enqueue('UPDATE_SHOP', { id: _shopId(), ...updates });
      return true;
    }
    const { error } = await _sb.from('shops').update(updates).eq('id', _shopId());
    return !_handle(error);
  }

  async function updateInvoiceCounter(num) {
    const { error } = await _sb.from('shops')
      .update({ invoice_counter: num })
      .eq('id', _shopId());
    if (!error) {
      const cached = JSON.parse(localStorage.getItem('sbp_shop') || '{}');
      cached.invoice_counter = num;
      localStorage.setItem('sbp_shop', JSON.stringify(cached));
    }
  }

  function getNextInvoiceNo() {
    const shop    = window.SBP.shop || JSON.parse(localStorage.getItem('sbp_shop') || '{}');
    const prefix  = shop.invoice_prefix || 'INV';
    const counter = shop.invoice_counter || 1;
    return prefix + '-' + String(counter).padStart(4, '0');
  }

  // FIX #23 — Atomic invoice counter via Supabase RPC. Returns null if offline
  // or RPC not yet deployed; caller should fall back to local counter and
  // queue a sync update.
  async function reserveNextInvoiceNo() {
    if (!_online() || !_shopId()) return null;
    try {
      const { data, error } = await _sb.rpc('next_invoice_no', { p_shop_id: _shopId() });
      if (error || !data || !data.length) return null;
      const row = Array.isArray(data) ? data[0] : data;
      const prefix = row.invoice_prefix || 'INV';
      const counter = row.invoice_counter;
      // Sync local cache
      const shop = window.SBP.shop || JSON.parse(localStorage.getItem('sbp_shop') || '{}');
      shop.invoice_counter = counter;
      window.SBP.shop = shop;
      localStorage.setItem('sbp_shop', JSON.stringify(shop));
      return prefix + '-' + String(counter).padStart(4, '0');
    } catch(e) {
      console.warn('reserveNextInvoiceNo failed:', e.message);
      return null;
    }
  }

  async function incrementInvoiceCounter() {
    const shop    = window.SBP.shop || JSON.parse(localStorage.getItem('sbp_shop') || '{}');
    const next    = (shop.invoice_counter || 1) + 1;
    await updateInvoiceCounter(next);
    return next;
  }

  /* ════════════════════════════════════
     CUSTOMERS
  ════════════════════════════════════ */

  async function getCustomers(search = '') {
    const cached = JSON.parse(localStorage.getItem('sbp_customers') || '[]');

    if (!_online()) {
      if (!search) return cached;
      const s = search.toLowerCase();
      return cached.filter(c =>
        c.name?.toLowerCase().includes(s) ||
        c.whatsapp?.includes(s) ||
        c.phone?.includes(s) ||
        c.email?.toLowerCase().includes(s)
      );
    }

    let q = _sb.from('customers').select('*').eq('shop_id', _shopId()).order('name');
    if (search) q = q.ilike('name', `%${search}%`);

    const { data, error } = await q;
    if (error) return cached;

    localStorage.setItem('sbp_customers', JSON.stringify(data));
    return data;
  }

  async function getCustomerById(id) {
    const cached = JSON.parse(localStorage.getItem('sbp_customers') || '[]');
    const local  = cached.find(c => c.id === id);

    if (!_online()) return local || null;

    const { data, error } = await _sb.from('customers').select('*').eq('id', id).single();
    if (error) return local || null;
    return data;
  }

  async function createCustomer(cust) {
    const newCust = {
      shop_id:       _shopId(),
      name:          cust.name,
      whatsapp:      cust.whatsapp || cust.wa || '',
      phone:         cust.phone    || cust.ph || '',
      email:         cust.email    || '',
      address:       cust.address  || cust.addr || '',
      city:          cust.city     || '',
      gstin:         cust.gstin    || cust.gst || '',
      customer_type: cust.customer_type || cust.type || 'Regular',
      balance:       0,
      credit_limit:  cust.credit_limit  || 0
    };

    // Save locally first
    const cached = JSON.parse(localStorage.getItem('sbp_customers') || '[]');
    const tempId = 'local_' + Date.now();

    if (!_online()) {
      const localCust = { ...newCust, id: tempId, created_at: new Date().toISOString() };
      cached.unshift(localCust);
      localStorage.setItem('sbp_customers', JSON.stringify(cached));
      SyncEngine.enqueue('CREATE_CUSTOMER', newCust);
      return localCust;
    }

    const { data, error } = await _sb.from('customers').insert(newCust).select().single();
    if (error) {
      const localCust = { ...newCust, id: tempId, created_at: new Date().toISOString() };
      cached.unshift(localCust);
      localStorage.setItem('sbp_customers', JSON.stringify(cached));
      SyncEngine.enqueue('CREATE_CUSTOMER', newCust);
      return localCust;
    }

    cached.unshift(data);
    localStorage.setItem('sbp_customers', JSON.stringify(cached));
    return data;
  }

  async function updateCustomer(id, updates) {
    const cached = JSON.parse(localStorage.getItem('sbp_customers') || '[]');
    const idx    = cached.findIndex(c => c.id === id);
    if (idx >= 0) {
      cached[idx] = { ...cached[idx], ...updates };
      localStorage.setItem('sbp_customers', JSON.stringify(cached));
    }

    if (!_online()) {
      SyncEngine.enqueue('UPDATE_CUSTOMER', { id, ...updates });
      return true;
    }
    const { error } = await _sb.from('customers').update(updates).eq('id', id);
    return !_handle(error);
  }

  async function deleteCustomer(id) {
    const cached = JSON.parse(localStorage.getItem('sbp_customers') || '[]');
    const filtered = cached.filter(c => c.id !== id);
    localStorage.setItem('sbp_customers', JSON.stringify(filtered));

    if (!_online()) {
      SyncEngine.enqueue('DELETE_CUSTOMER', { id });
      return true;
    }
    const { error } = await _sb.from('customers').delete().eq('id', id);
    return !_handle(error);
  }

  async function updateCustomerBalance(id, delta) {
    const cached = JSON.parse(localStorage.getItem('sbp_customers') || '[]');
    const idx    = cached.findIndex(c => c.id === id);
    const oldBal = idx >= 0 ? (parseFloat(cached[idx].balance) || 0) : 0;
    const newBal = Math.max(0, oldBal + delta);

    if (idx >= 0) {
      cached[idx].balance = newBal;
      localStorage.setItem('sbp_customers', JSON.stringify(cached));
    }

    if (_online()) {
      await _sb.from('customers').update({ balance: newBal }).eq('id', id);
    }
    return newBal;
  }

  /* ════════════════════════════════════
     BILLS
  ════════════════════════════════════ */

  async function getBills(filter = 'all') {
    const cached = JSON.parse(localStorage.getItem('sbp_bills') || '[]');

    if (!_online()) return _filterBills(cached, filter);

    let q = _sb.from('bills').select(`*, bill_items(*)`).eq('shop_id', _shopId()).order('created_at', { ascending: false });
    if (filter !== 'all') q = q.eq('status', filter);

    const { data, error } = await q;
    if (error) return _filterBills(cached, filter);

    localStorage.setItem('sbp_bills', JSON.stringify(data));
    return data;
  }

  function _filterBills(bills, filter) {
    if (filter === 'all') return bills;
    return bills.filter(b => b.status === filter);
  }

  async function getBillById(id) {
    const cached = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
    const local  = cached.find(b => b.id === id);

    if (!_online()) return local || null;

    const { data, error } = await _sb.from('bills').select(`*, bill_items(*), payments(*)`).eq('id', id).single();
    return error ? (local || null) : data;
  }

  async function getBillsByCustomer(customerId) {
    const cached = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
    const local  = cached.filter(b => b.customer_id === customerId || b.customer_name === customerId);

    if (!_online()) return local;

    const { data, error } = await _sb.from('bills')
      .select('*, bill_items(*)')
      .eq('shop_id', _shopId())
      .eq('customer_id', customerId)
      .order('created_at', { ascending: false });

    return error ? local : data;
  }

  async function createBill(billData, items = []) {
    const bill = {
      shop_id:         _shopId(),
      customer_id:     billData.customer_id      || null,
      invoice_no:      billData.invoice_no       || billData.invno,
      invoice_date:    billData.invoice_date     || billData.invdate || UI.todayISO(),
      due_date:        billData.due_date         || billData.duedate || null,
      customer_name:   billData.customer_name    || billData.cust   || '',
      customer_wa:     billData.customer_wa      || billData.wa     || '',
      customer_gstin:  billData.customer_gstin   || billData.cgst   || '',
      payment_mode:    billData.payment_mode     || billData.paymode || 'Cash',
      status:          billData.status           || 'Pending',
      subtotal:        parseFloat(billData.subtotal)    || 0,
      gst_amount:      parseFloat(billData.gst_amount)  || 0,
      discount:        parseFloat(billData.discount)    || 0,
      grand_total:     parseFloat(billData.grand_total) || 0,
      paid_amount:     parseFloat(billData.paid_amount) || 0,
      balance_due:     parseFloat(billData.balance_due) || 0,
      is_gst_invoice:  billData.is_gst_invoice   || false,
      supply_type:     billData.supply_type      || 'intra',
      place_of_supply: billData.place_of_supply  || '',
      notes:           billData.notes            || billData.note   || ''
    };

    // Save locally
    const cached = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
    const tempId = 'local_' + Date.now();

    if (!_online()) {
      const localBill = { ...bill, id: tempId, bill_items: items, created_at: new Date().toISOString() };
      cached.unshift(localBill);
      localStorage.setItem('sbp_bills', JSON.stringify(cached));
      SyncEngine.enqueue('CREATE_BILL', { bill, items });
      return localBill;
    }

    const { data: billRow, error: billErr } = await _sb.from('bills').insert(bill).select().single();
    if (billErr) {
      const localBill = { ...bill, id: tempId, bill_items: items, created_at: new Date().toISOString() };
      cached.unshift(localBill);
      localStorage.setItem('sbp_bills', JSON.stringify(cached));
      SyncEngine.enqueue('CREATE_BILL', { bill, items });
      return localBill;
    }

    // Save bill items
    if (items.length) {
      const billItems = items.map(it => ({
        bill_id:    billRow.id,
        item_name:  it.nm || it.name || it.item_name || '',
        hsn_code:   it.hsn || it.hsn_code || '',
        qty:        parseFloat(it.q || it.qty)      || 1,
        rate:       parseFloat(it.r || it.rate)     || 0,
        gst_rate:   parseFloat(it.rate || it.gst_rate) || 0,
        discount:   parseFloat(it.disc || it.discount) || 0,
        line_total: parseFloat(it.tot  || it.line_total) || 0,
        gst_amount: parseFloat(it.lineGST || it.gst_amount) || 0
      }));

      await _sb.from('bill_items').insert(billItems);
      billRow.bill_items = items;
    }

    cached.unshift(billRow);
    localStorage.setItem('sbp_bills', JSON.stringify(cached));

    // Increment invoice counter
    await incrementInvoiceCounter();

    return billRow;
  }

  async function updateBillStatus(id, status, paidAmount = null) {
    const cached = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
    const idx    = cached.findIndex(b => b.id === id);

    const updates = { status };
    if (paidAmount !== null) {
      const total   = parseFloat(cached[idx]?.grand_total || 0);
      updates.paid_amount = paidAmount;
      updates.balance_due = Math.max(0, total - paidAmount);
    }

    if (idx >= 0) { cached[idx] = { ...cached[idx], ...updates }; localStorage.setItem('sbp_bills', JSON.stringify(cached)); }

    if (_online()) await _sb.from('bills').update(updates).eq('id', id);
    return true;
  }

  async function deleteBill(id) {
    const cached   = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
    const filtered = cached.filter(b => b.id !== id);
    localStorage.setItem('sbp_bills', JSON.stringify(filtered));

    if (_online()) {
      await _sb.from('bill_items').delete().eq('bill_id', id);
      await _sb.from('bills').delete().eq('id', id);
    }
    return true;
  }

  /* ════════════════════════════════════
     PAYMENTS
  ════════════════════════════════════ */

  async function recordPayment(billId, amount, mode = 'Cash', notes = '') {
    const payment = {
      bill_id:      billId,
      shop_id:      _shopId(),
      amount:       parseFloat(amount),
      payment_date: UI.todayISO(),
      payment_mode: mode,
      notes
    };

    if (_online()) {
      const { data, error } = await _sb.from('payments').insert(payment).select().single();
      if (!error) return data;
    }

    // Update bill paid_amount locally
    const cached = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
    const idx    = cached.findIndex(b => b.id === billId);
    if (idx >= 0) {
      const bill        = cached[idx];
      const newPaid     = parseFloat(bill.paid_amount || 0) + parseFloat(amount);
      const newBalance  = Math.max(0, parseFloat(bill.grand_total || 0) - newPaid);
      const newStatus   = newBalance <= 0 ? 'Paid' : newPaid > 0 ? 'Partial' : bill.status;
      cached[idx] = { ...bill, paid_amount: newPaid, balance_due: newBalance, status: newStatus };
      localStorage.setItem('sbp_bills', JSON.stringify(cached));
    }

    return payment;
  }

  /* ════════════════════════════════════
     PRODUCTS / INVENTORY
  ════════════════════════════════════ */

  async function getProducts(search = '', category = '') {
    const cached = JSON.parse(localStorage.getItem('sbp_products') || '[]');

    if (!_online()) return _filterProducts(cached, search, category);

    let q = _sb.from('products').select('*').eq('shop_id', _shopId()).order('name');
    if (search)   q = q.ilike('name', `%${search}%`);
    if (category) q = q.eq('category', category);

    const { data, error } = await q;
    if (error) return _filterProducts(cached, search, category);

    localStorage.setItem('sbp_products', JSON.stringify(data));
    return data;
  }

  function _filterProducts(products, search, category) {
    let result = products;
    if (search)   result = result.filter(p => p.name?.toLowerCase().includes(search.toLowerCase()) || p.code?.toLowerCase().includes(search.toLowerCase()));
    if (category) result = result.filter(p => p.category === category);
    return result;
  }

  async function createProduct(prod) {
    const newProd = {
      shop_id:       _shopId(),
      code:          prod.code         || '',
      name:          prod.name,
      category:      prod.category     || 'General',
      sub_category:  prod.sub_category || prod.sub || '',
      price:         parseFloat(prod.price)      || 0,
      cost_price:    parseFloat(prod.cost_price) || parseFloat(prod.cost) || 0,
      unit:          prod.unit         || 'Piece',
      stock_qty:     parseFloat(prod.stock_qty)  || parseFloat(prod.stock) || 0,
      low_stock_alert: parseInt(prod.low_stock_alert) || 10,
      gst_rate:      parseFloat(prod.gst_rate)   || parseFloat(prod.gst) || 0,
      emoji:         prod.emoji        || '📦'
    };

    const cached = JSON.parse(localStorage.getItem('sbp_products') || '[]');
    const tempId = 'local_' + Date.now();

    if (!_online()) {
      const local = { ...newProd, id: tempId, created_at: new Date().toISOString() };
      cached.push(local);
      localStorage.setItem('sbp_products', JSON.stringify(cached));
      SyncEngine.enqueue('CREATE_PRODUCT', newProd);
      return local;
    }

    const { data, error } = await _sb.from('products').insert(newProd).select().single();
    if (error) {
      const local = { ...newProd, id: tempId, created_at: new Date().toISOString() };
      cached.push(local);
      localStorage.setItem('sbp_products', JSON.stringify(cached));
      SyncEngine.enqueue('CREATE_PRODUCT', newProd);
      return local;
    }

    cached.push(data);
    localStorage.setItem('sbp_products', JSON.stringify(cached));
    return data;
  }

  async function updateProduct(id, updates) {
    const cached = JSON.parse(localStorage.getItem('sbp_products') || '[]');
    const idx    = cached.findIndex(p => p.id === id);
    if (idx >= 0) { cached[idx] = { ...cached[idx], ...updates }; localStorage.setItem('sbp_products', JSON.stringify(cached)); }

    if (!_online()) { SyncEngine.enqueue('UPDATE_PRODUCT', { id, ...updates }); return true; }
    const { error } = await _sb.from('products').update(updates).eq('id', id);
    return !_handle(error);
  }

  async function deleteProduct(id) {
    const cached   = JSON.parse(localStorage.getItem('sbp_products') || '[]');
    localStorage.setItem('sbp_products', JSON.stringify(cached.filter(p => p.id !== id)));
    if (_online()) await _sb.from('products').delete().eq('id', id);
    return true;
  }

  async function deductStock(cartItems) {
    const cached = JSON.parse(localStorage.getItem('sbp_products') || '[]');
    for (const { productId, qty } of cartItems) {
      const idx = cached.findIndex(p => p.id == productId);
      if (idx >= 0) {
        const newStock = Math.max(0, (parseFloat(cached[idx].stock_qty) || 0) - parseFloat(qty));
        cached[idx].stock_qty = newStock;
        if (_online()) await _sb.from('products').update({ stock_qty: newStock }).eq('id', productId);
      }
    }
    localStorage.setItem('sbp_products', JSON.stringify(cached));
  }

  /* ════════════════════════════════════
     EXPENSES
  ════════════════════════════════════ */

  async function getExpenses() {
    const cached = JSON.parse(localStorage.getItem('sbp_expenses') || '[]');
    if (!_online()) return cached;

    const { data, error } = await _sb.from('expenses')
      .select('*')
      .eq('shop_id', _shopId())
      .order('expense_date', { ascending: false });

    if (error) return cached;
    localStorage.setItem('sbp_expenses', JSON.stringify(data));
    return data;
  }

  async function createExpense(exp) {
    const newExp = {
      shop_id:      _shopId(),
      name:         exp.name,
      category:     exp.category    || 'Other',
      amount:       parseFloat(exp.amount) || 0,
      expense_date: exp.expense_date || exp.date || UI.todayISO(),
      payment_mode: exp.payment_mode || exp.payMode || 'Cash',
      notes:        exp.notes        || exp.note  || ''
    };

    const cached = JSON.parse(localStorage.getItem('sbp_expenses') || '[]');
    const tempId = 'local_' + Date.now();

    if (!_online()) {
      const local = { ...newExp, id: tempId, created_at: new Date().toISOString() };
      cached.unshift(local);
      localStorage.setItem('sbp_expenses', JSON.stringify(cached));
      SyncEngine.enqueue('CREATE_EXPENSE', newExp);
      return local;
    }

    const { data, error } = await _sb.from('expenses').insert(newExp).select().single();
    if (error) {
      const local = { ...newExp, id: tempId, created_at: new Date().toISOString() };
      cached.unshift(local);
      localStorage.setItem('sbp_expenses', JSON.stringify(cached));
      return local;
    }

    cached.unshift(data);
    localStorage.setItem('sbp_expenses', JSON.stringify(cached));
    return data;
  }

  async function deleteExpense(id) {
    const cached   = JSON.parse(localStorage.getItem('sbp_expenses') || '[]');
    localStorage.setItem('sbp_expenses', JSON.stringify(cached.filter(e => e.id !== id)));
    if (_online()) await _sb.from('expenses').delete().eq('id', id);
    return true;
  }

  /* ════════════════════════════════════
     REPORTS / ANALYTICS
  ════════════════════════════════════ */

  async function getDashboardStats() {
    const bills    = JSON.parse(localStorage.getItem('sbp_bills')    || '[]');
    const expenses = JSON.parse(localStorage.getItem('sbp_expenses') || '[]');
    const today    = UI.todayISO();
    const thisMonth= today.substring(0, 7); // YYYY-MM

    const todayBills   = bills.filter(b => (b.invoice_date || b.created_at || '').startsWith(today));
    const monthBills   = bills.filter(b => (b.invoice_date || b.created_at || '').startsWith(thisMonth));
    const overdueBills = bills.filter(b => b.status === 'Overdue');
    const monthExp     = expenses.filter(e => (e.expense_date || '').startsWith(thisMonth));

    const todaySales   = todayBills.reduce((s, b) => s + parseFloat(b.paid_amount || 0), 0);
    const monthRevenue = monthBills.reduce((s, b) => s + parseFloat(b.paid_amount || 0), 0);
    const outstanding  = bills.reduce((s, b) => s + parseFloat(b.balance_due || 0), 0);
    const gstPayable   = monthBills.reduce((s, b) => s + parseFloat(b.gst_amount || 0), 0);
    const totalExp     = monthExp.reduce((s, e) => s + parseFloat(e.amount || 0), 0);

    return {
      todaySales,
      monthRevenue,
      outstanding,
      gstPayable,
      totalBills: bills.length,
      todayBills: todayBills.length,
      overdueBills,
      overdueAmt: overdueBills.reduce((s, b) => s + parseFloat(b.balance_due || 0), 0),
      netProfit: monthRevenue - totalExp,
      expenses: totalExp
    };
  }

  async function getTopCustomers(limit = 5) {
    const bills = JSON.parse(localStorage.getItem('sbp_bills') || '[]');
    const map   = {};
    bills.forEach(b => {
      const name = b.customer_name || 'Walk-in';
      map[name]  = (map[name] || 0) + parseFloat(b.paid_amount || 0);
    });
    return Object.entries(map)
      .sort((a, b) => b[1] - a[1])
      .slice(0, limit)
      .map(([name, total]) => ({ name, total }));
  }

  /* ── Public API ── */
  /* ── Stock Update (with history) ── */
  async function updateProductStock(id, newQty) {
    const cached = JSON.parse(localStorage.getItem('sbp_products') || '[]');
    const idx = cached.findIndex(p => String(p.id) === String(id));
    if (idx >= 0) { cached[idx].stock_qty = newQty; localStorage.setItem('sbp_products', JSON.stringify(cached)); }
    if (!_online() || String(id).startsWith('local_')) {
      SyncEngine.enqueue('UPDATE_PRODUCT', { id, stock_qty: newQty });
      return true;
    }
    const { error } = await _sb.from('products').update({ stock_qty: newQty }).eq('id', id);
    return !_handle(error);
  }

  /* ── Product Photo Update ── */
  async function updateProductPhoto(id, photoBase64) {
    const cached = JSON.parse(localStorage.getItem('sbp_products') || '[]');
    const idx = cached.findIndex(p => String(p.id) === String(id));
    if (idx >= 0) { cached[idx].photo = photoBase64; localStorage.setItem('sbp_products', JSON.stringify(cached)); }
    if (!_online() || String(id).startsWith('local_')) {
      SyncEngine.enqueue('UPDATE_PRODUCT', { id, photo: photoBase64 });
      return true;
    }
    const { error } = await _sb.from('products').update({ photo: photoBase64 }).eq('id', id);
    return !_handle(error);
  }

  /* ── Plan Update ── */
  async function updateShopPlan(plan, paymentId = null) {
    const updates = { plan, plan_activated_at: new Date().toISOString() };
    if (paymentId) updates.plan_payment_id = paymentId;
    const cached = JSON.parse(localStorage.getItem('sbp_shop') || '{}');
    Object.assign(cached, updates);
    localStorage.setItem('sbp_shop', JSON.stringify(cached));
    if (window.SBP) window.SBP.shop = cached;
    if (!_online()) { SyncEngine.enqueue('UPDATE_SHOP', { id: _shopId(), ...updates }); return true; }
    const { error } = await _sb.from('shops').update(updates).eq('id', _shopId());
    return !_handle(error);
  }

  /* ── Barcode / Product Code Lookup ── */
  function lookupProductByCode(code) {
    const products = JSON.parse(localStorage.getItem('sbp_products') || '[]');
    const c = (code || '').toLowerCase().trim();
    return products.find(p =>
      (p.code || '').toLowerCase() === c ||
      (p.barcode || '').toLowerCase() === c ||
      (p.hsn_code || '').toLowerCase() === c
    ) || null;
  }

  return {
    getShop, updateShop, updateInvoiceCounter, getNextInvoiceNo, reserveNextInvoiceNo, incrementInvoiceCounter,
    updateProductStock, updateProductPhoto, updateShopPlan, lookupProductByCode,
    getCustomers, getCustomerById, createCustomer, updateCustomer, deleteCustomer, updateCustomerBalance,
    getBills, getBillById, getBillsByCustomer, createBill, updateBillStatus, deleteBill,
    recordPayment,
    getProducts, createProduct, updateProduct, deleteProduct, deductStock,
    getExpenses, createExpense, deleteExpense,
    getDashboardStats, getTopCustomers
  };

})();

window.DB = DB;
