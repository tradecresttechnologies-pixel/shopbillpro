/* ════════════════════════════════════════════════════════════════
   lib/bill-template.js  —  ShopBill Pro shared bill renderer
   SINGLE SOURCE OF TRUTH for the invoice design.
   Used by:
     • billing.html  (POS / preview / print)  — via window.renderShopBill
     • bill.html     (public WhatsApp link)    — same design, identical output

   renderShopBill(data) -> returns full bill HTML string.
   data = {
     shop:  { name, address, phone, gstin, email, upi, emoji, plan|is_paid_plan },
     bill:  { invoice_no, datetime_ist|invoice_date, customer_name, customer_wa,
              customer_gstin, payment_mode, supply_type('intra'|'inter'),
              status, paid(bool), subtotal, gst_amount, discount, grand_total },
     items: [ { item_name|nm, qty|q, rate|r, gst_rate|rate, gst_amount|lineGST,
                line_total|tot, hsn_code|hsn, discount|disc } ],
     opts:  { showQR(bool, default true), watermark(bool) }
   }
   All numbers tolerant of string/number. Snake_case (Supabase) and
   camelCase (local) field names both accepted.
═══════════════════════════════════════════════════════════════════ */
(function (root) {
  function num(v){ const n = parseFloat(v); return isNaN(n) ? 0 : n; }
  function rs(n){ return '₹' + num(n).toLocaleString('en-IN', {minimumFractionDigits:2, maximumFractionDigits:2}); }
  function esc(s){ return String(s==null?'':s).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

  // field accessors (accept both naming styles)
  const iName = it => it.item_name ?? it.nm ?? 'Item';
  const iQty  = it => num(it.qty ?? it.q ?? 1);
  const iRate = it => num(it.rate ?? it.r ?? 0);
  const iGstR = it => num(it.gst_rate ?? it.rate ?? it.gst ?? 0);
  const iGstA = it => num(it.gst_amount ?? it.lineGST ?? 0);
  const iDisc = it => num(it.discount ?? it.disc ?? 0);
  const iHsn  = it => it.hsn_code ?? it.hsn ?? '';
  const iTot  = it => { const t = it.line_total ?? it.tot; return t!=null ? num(t) : (iRate(it)*iQty(it)); };

  function renderShopBill(data){
    data = data || {};
    const s = data.shop || {};
    const b = data.bill || {};
    const items = data.items || [];
    const opts = data.opts || {};

    const invoiceNo   = b.invoice_no || b.invno || 'INV-0001';
    const dateTime    = b.datetime_ist || b.invoice_date || b.invdate || '';
    const custName    = b.customer_name || b.nm || 'Walk-in Customer';
    const custPhone   = b.customer_wa || b.wa || '';
    const custGSTIN   = b.customer_gstin || b.cust_gstin || b.custGSTIN || '';
    const payMode     = b.payment_mode || b.paymode || 'Cash';
    const status      = b.status || (b.paid ? 'Paid' : 'Pending');
    const isPaid      = (b.paid === true) || String(status).toLowerCase() === 'paid';
    const isIntra     = (b.supply_type || b.supplyType || 'intra') === 'intra';
    const watermark   = opts.watermark != null ? opts.watermark
                        : (s.is_paid_plan === false || (s.plan||'free')==='free');
    const showQR      = opts.showQR !== false && !!s.upi && !isPaid;

    // per-item rows + roll-ups
    let subtotal = 0, totalGST = 0, itemDiscTotal = 0;
    const anyDisc = items.some(it => iDisc(it) > 0);
    const anyGST  = items.some(it => iGstR(it) > 0 || iGstA(it) > 0);
    const gstSlabs = {};

    const rows = items.map(it => {
      const q = iQty(it), rate = iRate(it), disc = iDisc(it);
      const gross = q*rate, net = gross - disc;
      const gstA = iGstA(it) || (net * iGstR(it)/100);
      const tot  = iTot(it) || (net + gstA);
      subtotal += net; totalGST += gstA; itemDiscTotal += disc;
      const r = iGstR(it);
      if(r>0){ if(!gstSlabs[r]) gstSlabs[r]={taxable:0,gst:0}; gstSlabs[r].taxable+=net; gstSlabs[r].gst+=gstA; }
      return {nm:iName(it), q, rate, disc, gstR:r, gstA, tot, hsn:iHsn(it)};
    });

    const billDisc   = num(b.discount ?? b.discAmt ?? b.billDiscount ?? 0);
    const grandTotal = num(b.grand_total ?? b.grand) || (subtotal + totalGST - billDisc);

    const taxSummary = anyGST && Object.keys(gstSlabs).length ? `
    <div style="margin-bottom:14px">
      <div style="font-size:10px;font-weight:700;color:#888;text-transform:uppercase;letter-spacing:1px;margin-bottom:8px">Tax Summary</div>
      <table style="width:100%;border-collapse:collapse;font-size:11px">
        <thead><tr style="background:#F8F7FF">
          <th style="padding:6px 8px;text-align:left;font-weight:700;color:#666;border-bottom:1px solid #E5E0FF">GST Rate</th>
          <th style="padding:6px 8px;text-align:right;font-weight:700;color:#666;border-bottom:1px solid #E5E0FF">Taxable ₹</th>
          ${isIntra
            ? '<th style="padding:6px 8px;text-align:right;font-weight:700;color:#666;border-bottom:1px solid #E5E0FF">CGST ₹</th><th style="padding:6px 8px;text-align:right;font-weight:700;color:#666;border-bottom:1px solid #E5E0FF">SGST ₹</th>'
            : '<th style="padding:6px 8px;text-align:right;font-weight:700;color:#666;border-bottom:1px solid #E5E0FF">IGST ₹</th>'}
          <th style="padding:6px 8px;text-align:right;font-weight:700;color:#666;border-bottom:1px solid #E5E0FF">Total Tax</th>
        </tr></thead>
        <tbody>
          ${Object.entries(gstSlabs).map(([rate,v])=>`
          <tr>
            <td style="padding:5px 8px;border-bottom:1px solid #F0EEFF">${rate}%</td>
            <td style="padding:5px 8px;text-align:right;border-bottom:1px solid #F0EEFF">${rs(v.taxable)}</td>
            ${isIntra
              ? '<td style="padding:5px 8px;text-align:right;border-bottom:1px solid #F0EEFF;color:#10B981">'+rs(v.gst/2)+'</td><td style="padding:5px 8px;text-align:right;border-bottom:1px solid #F0EEFF;color:#10B981">'+rs(v.gst/2)+'</td>'
              : '<td style="padding:5px 8px;text-align:right;border-bottom:1px solid #F0EEFF;color:#10B981">'+rs(v.gst)+'</td>'}
            <td style="padding:5px 8px;text-align:right;font-weight:700;border-bottom:1px solid #F0EEFF">${rs(v.gst)}</td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>` : '';

    return `<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Arial',sans-serif;font-size:12px;color:#1a1a2e;background:#fff}
  .bill-wrap{max-width:600px;margin:0 auto;padding:24px}
  .bill-header{display:flex;justify-content:space-between;align-items:flex-start;padding-bottom:16px;border-bottom:2px solid #F5A623;margin-bottom:16px}
  .shop-name{font-size:22px;font-weight:800;color:#F5A623;letter-spacing:-.5px}
  .shop-meta{font-size:11px;color:#666;margin-top:4px;line-height:1.6}
  .invoice-badge{text-align:right}
  .inv-label{font-size:10px;font-weight:700;color:#888;text-transform:uppercase;letter-spacing:1px}
  .inv-number{font-size:18px;font-weight:800;color:#1a1a2e}
  .inv-date{font-size:11px;color:#666;margin-top:2px}
  .status-badge{display:inline-block;padding:3px 10px;border-radius:20px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;margin-top:6px;background:${isPaid?'#D1FAE5':'#FEF3C7'};color:${isPaid?'#065F46':'#92400E'}}
  .bill-to-section{display:grid;grid-template-columns:1fr 1fr;gap:12px;background:#F8F7FF;border-radius:10px;padding:14px;margin-bottom:16px}
  .section-label{font-size:9px;font-weight:700;color:#888;text-transform:uppercase;letter-spacing:1px;margin-bottom:5px}
  .customer-name{font-size:14px;font-weight:700;color:#1a1a2e}
  .customer-meta{font-size:11px;color:#666;margin-top:2px;line-height:1.5}
  .items-table{width:100%;border-collapse:collapse;margin-bottom:12px}
  .items-table th{background:#F5A623;color:#fff;padding:8px 10px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;text-align:left}
  .items-table th:last-child,.items-table td:last-child{text-align:right}
  .items-table td{padding:8px 10px;font-size:12px;border-bottom:1px solid #F0EEFF;vertical-align:top}
  .item-name{font-weight:600;color:#1a1a2e}
  .item-meta{font-size:10px;color:#888;margin-top:2px}
  .totals-section{display:flex;justify-content:flex-end;margin-bottom:14px}
  .totals-box{width:240px}
  .total-row{display:flex;justify-content:space-between;padding:4px 0;font-size:12px;color:#444}
  .total-row.grand{font-size:15px;font-weight:800;color:#1a1a2e;border-top:2px solid #F5A623;margin-top:6px;padding-top:8px}
  .bill-footer{text-align:center;font-size:10px;color:#aaa;border-top:1px solid #F0EEFF;padding-top:12px;line-height:1.7;margin-top:8px}
  @media print{body{padding:0}.bill-wrap{padding:16px}}
</style></head><body>
<div class="bill-wrap">
  <div class="bill-header">
    <div>
      <div class="shop-name">${esc(s.emoji||'🏪')} ${esc(s.name||'Your Shop')}</div>
      <div class="shop-meta">
        ${s.address?esc(s.address)+'<br>':''}
        ${s.phone?'📞 '+esc(s.phone):''}
        ${s.gstin?' &nbsp;·&nbsp; GSTIN: '+esc(s.gstin):''}
        ${s.email?'<br>✉️ '+esc(s.email):''}
      </div>
    </div>
    <div class="invoice-badge">
      <div class="inv-label">${anyGST?'Tax Invoice':'Invoice'}</div>
      <div class="inv-number">${esc(invoiceNo)}</div>
      <div class="inv-date">🕒 ${esc(dateTime)}</div>
      <div><span class="status-badge">${esc(status)}</span></div>
    </div>
  </div>

  <div class="bill-to-section">
    <div>
      <div class="section-label">Bill To</div>
      <div class="customer-name">${esc(custName)}</div>
      <div class="customer-meta">
        ${custPhone?'📞 '+esc(custPhone):''}
        ${custGSTIN?'<br>🏛️ GSTIN: '+esc(custGSTIN):''}
      </div>
    </div>
    <div style="text-align:right">
      <div class="section-label">Payment</div>
      <div style="font-size:13px;font-weight:700;color:#F5A623;margin-top:3px">${esc(payMode)}</div>
    </div>
  </div>

  <table class="items-table">
    <thead><tr>
      <th style="width:35%">Item / Service</th>
      <th style="text-align:right">Qty</th>
      <th style="text-align:right">Rate</th>
      ${anyDisc?'<th style="text-align:right">Disc</th>':''}
      ${anyGST?'<th style="text-align:right">GST%</th><th style="text-align:right">GST ₹</th>':''}
      <th>Amount</th>
    </tr></thead>
    <tbody>
      ${rows.map(it=>`
      <tr>
        <td><div class="item-name">${esc(it.nm)}</div>${it.hsn?'<div class="item-meta">HSN: '+esc(it.hsn)+'</div>':''}</td>
        <td style="text-align:right">${it.q}</td>
        <td style="text-align:right">${rs(it.rate)}</td>
        ${anyDisc?'<td style="text-align:right">'+(it.disc>0?rs(it.disc):'—')+'</td>':''}
        ${anyGST?'<td style="text-align:right;color:#10B981">'+it.gstR+'%</td><td style="text-align:right;color:#10B981">'+rs(it.gstA)+'</td>':''}
        <td style="text-align:right;font-weight:600">${rs(it.tot)}</td>
      </tr>`).join('')}
    </tbody>
  </table>

  <div class="totals-section">
    <div class="totals-box">
      <div class="total-row"><span>Subtotal</span><span>${rs(subtotal)}</span></div>
      ${itemDiscTotal>0?`<div class="total-row"><span>Item Discount</span><span style="color:#EF4444">-${rs(itemDiscTotal)}</span></div>`:''}
      ${billDisc>0?`<div class="total-row"><span>Bill Discount</span><span style="color:#EF4444">-${rs(billDisc)}</span></div>`:''}
      ${anyGST && totalGST>0 && isIntra?`
        <div class="total-row"><span>CGST</span><span style="color:#10B981">${rs(totalGST/2)}</span></div>
        <div class="total-row"><span>SGST</span><span style="color:#10B981">${rs(totalGST/2)}</span></div>`:''}
      ${anyGST && totalGST>0 && !isIntra?`
        <div class="total-row"><span>IGST</span><span style="color:#10B981">${rs(totalGST)}</span></div>`:''}
      <div class="total-row grand"><span>Grand Total</span><span style="color:#F5A623">${rs(grandTotal)}</span></div>
    </div>
  </div>

  ${taxSummary}

  ${showQR?`
  <div style="text-align:center;margin-bottom:14px;padding:16px;background:#F8F7FF;border-radius:10px">
    <div style="font-size:10px;font-weight:700;color:#888;text-transform:uppercase;letter-spacing:1px;margin-bottom:10px">Scan &amp; Pay</div>
    <img src="https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=${encodeURIComponent('upi://pay?pa='+s.upi+'&pn='+(s.name||'Shop')+'&am='+num(grandTotal).toFixed(2)+'&cu=INR&tn=Bill '+invoiceNo)}" style="width:120px;height:120px;border-radius:6px" alt="UPI QR">
    <div style="font-size:12px;font-weight:700;color:#F5A623;margin-top:8px">${esc(s.upi)}</div>
    <div style="font-size:10px;color:#888;margin-top:3px">GPay · PhonePe · Paytm · Any UPI</div>
  </div>`:''}

  <div class="bill-footer">
    Thank you for your business! 🙏
    <br>${esc(s.name||'Your Shop')}
    ${watermark?'<br><span style="color:#ccc;font-size:9px">Powered by ShopBill Pro · TradeCrest Technologies Pvt. Ltd.</span>':''}
  </div>
</div>
</body></html>`;
  }

  root.renderShopBill = renderShopBill;
  if (typeof module !== 'undefined' && module.exports) module.exports = renderShopBill;
})(typeof window !== 'undefined' ? window : this);
