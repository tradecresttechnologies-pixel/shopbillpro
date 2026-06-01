/* ════════════════════════════════════════════════════════════════
   lib/bill-template.js  —  ShopBill Pro shared A4 bill renderer (v10)
   SINGLE SOURCE OF TRUTH for the A4 / PDF / public-link invoice design.
   Used by:
     • bill.html  (public WhatsApp link page + Download PDF)
   renderShopBill(data) -> full bill HTML string. Signature UNCHANGED.
   data = { shop:{...}, bill:{...}, items:[...], opts:{showQR,watermark} }
   Accepts BOTH snake_case (Supabase) and camelCase (local) field names.
═══════════════════════════════════════════════════════════════════ */
(function (root) {
  function num(v){ const n = parseFloat(v); return isNaN(n) ? 0 : n; }
  function rs(n){ return '\u20b9' + num(n).toLocaleString('en-IN', {minimumFractionDigits:2, maximumFractionDigits:2}); }
  function esc(s){ return String(s==null?'':s).replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

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

    const invoiceNo = b.invoice_no || b.invno || 'INV-0001';
    const dateTime  = b.datetime_ist || b.invoice_date || b.invdate || '';
    const custName  = b.customer_name || b.nm || 'Walk-in Customer';
    const custPhone = b.customer_wa || b.wa || '';
    const custGSTIN = b.customer_gstin || b.cust_gstin || b.custGSTIN || '';
    const payMode   = b.payment_mode || b.paymode || 'Cash';
    const status    = b.status || (b.paid ? 'Paid' : 'Pending');
    const isPaid    = (b.paid === true) || String(status).toLowerCase() === 'paid';
    const isIntra   = (b.supply_type || b.supplyType || 'intra') === 'intra';
    const watermark = opts.watermark != null ? opts.watermark
                      : (s.is_paid_plan === false || (s.plan||'free')==='free');
    const showQR    = opts.showQR !== false && !!s.upi && !isPaid;

    // ── Build rows; compute taxable + gst per row and slabs ──
    let computedTaxable = 0, totalGST = 0, itemDiscTotal = 0;
    const anyDisc = items.some(it => iDisc(it) > 0);
    const anyGST  = items.some(it => iGstR(it) > 0 || iGstA(it) > 0);
    const gstSlabs = {};

    const rows = items.map(it => {
      const q = iQty(it), rate = iRate(it), disc = iDisc(it);
      const gross = q*rate, net = gross - disc;
      const gstA = iGstA(it) || (net * iGstR(it)/100);
      const tot  = iTot(it) || (net + gstA);
      computedTaxable += net; totalGST += gstA; itemDiscTotal += disc;
      const r = iGstR(it);
      if(r>0){ if(!gstSlabs[r]) gstSlabs[r]={taxable:0,gst:0}; gstSlabs[r].taxable+=net; gstSlabs[r].gst+=gstA; }
      return {nm:iName(it), q, rate, disc, gstR:r, gstA, tot, hsn:iHsn(it)};
    });

    const billDisc   = num(b.discount ?? b.discAmt ?? b.billDiscount ?? 0);
    // Trust the stored subtotal/gst/grand when present so the customer-facing
    // bill matches the WhatsApp message exactly; fall back to computed.
    const storedSub  = b.subtotal ?? b.sub;
    const subtotal   = storedSub != null ? num(storedSub) : computedTaxable;
    const storedGST  = b.gst_amount ?? b.gstAmt;
    if(storedGST != null) totalGST = num(storedGST);
    const grandTotal = num(b.grand_total ?? b.grand) || (subtotal + totalGST - billDisc);

    // Monogram from shop name (clean, no emoji)
    const monogram = esc((s.name||'S').trim().charAt(0).toUpperCase() || 'S');

    // Single consolidated tax line set (no duplicate summary table)
    let taxRows = '';
    if(anyGST && totalGST > 0){
      if(isIntra){
        taxRows = `<div class="t-row"><span>CGST</span><span>${rs(totalGST/2)}</span></div>
                   <div class="t-row"><span>SGST</span><span>${rs(totalGST/2)}</span></div>`;
      } else {
        taxRows = `<div class="t-row"><span>IGST</span><span>${rs(totalGST)}</span></div>`;
      }
    }

    return `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  :root{--ink:#1A1F2E;--mut:#6B7280;--ln:#ECEEF3;--brand:#F5A623;--brand2:#FF6B35;--soft:#FAFAFC;--ok:#0E9F6E;--warnbg:#FEF3C7;--warnfg:#92400E;--okbg:#D1FAE5;--okfg:#065F46}
  html,body{background:#fff;color:var(--ink)}
  body{font-family:'Inter','Segoe UI',system-ui,Arial,sans-serif;font-size:13px;line-height:1.5;-webkit-font-smoothing:antialiased}
  .doc{max-width:580px;margin:0 auto;padding:28px 26px 22px}
  /* Header */
  .hd{display:flex;justify-content:space-between;align-items:center;gap:14px;margin-bottom:6px}
  .hd-l{display:flex;align-items:center;gap:12px;min-width:0}
  .logo{width:46px;height:46px;border-radius:12px;flex:none;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:20px;color:#fff;background:linear-gradient(135deg,var(--brand),var(--brand2));box-shadow:0 4px 12px rgba(245,166,35,.28)}
  .sh-name{font-size:19px;font-weight:800;letter-spacing:-.3px;line-height:1.2;word-break:break-word}
  .sh-meta{font-size:11px;color:var(--mut);margin-top:2px;line-height:1.45}
  .hd-r{text-align:right;flex:none}
  .inv-kind{font-size:9.5px;font-weight:700;color:var(--mut);text-transform:uppercase;letter-spacing:1.2px}
  .inv-no{font-size:16px;font-weight:800;letter-spacing:-.2px;margin-top:1px}
  .inv-dt{font-size:11px;color:var(--mut);margin-top:1px}
  .badge{display:inline-block;margin-top:6px;padding:3px 11px;border-radius:999px;font-size:9.5px;font-weight:800;text-transform:uppercase;letter-spacing:.6px;background:${isPaid?'var(--okbg)':'var(--warnbg)'};color:${isPaid?'var(--okfg)':'var(--warnfg)'}}
  .rule{height:3px;border-radius:3px;background:linear-gradient(90deg,var(--brand),var(--brand2));margin:14px 0 16px}
  /* Parties */
  .parties{display:flex;gap:12px;margin-bottom:16px;align-items:stretch}
  .pcard{background:var(--soft);border:1px solid var(--ln);border-radius:11px;padding:11px 13px;min-width:0}
  .pcard.billed{flex:1}
  .pcard.payment{flex:none;width:160px;display:flex;flex-direction:column;justify-content:center;text-align:right}
  .plabel{font-size:9px;font-weight:700;color:var(--mut);text-transform:uppercase;letter-spacing:1px;margin-bottom:4px}
  .pname{font-size:14px;font-weight:700;word-break:break-word}
  .pmeta{font-size:11px;color:var(--mut);margin-top:2px;line-height:1.45;word-break:break-word}
  .pay-val{font-size:14px;font-weight:800;color:var(--brand2)}
  /* Items */
  .items{width:100%;border-collapse:collapse;margin-bottom:4px}
  .items thead th{font-size:9.5px;font-weight:700;color:var(--mut);text-transform:uppercase;letter-spacing:.6px;text-align:right;padding:0 0 8px;border-bottom:1.5px solid var(--ln)}
  .items thead th:first-child{text-align:left}
  .items tbody td{padding:9px 0;border-bottom:1px solid var(--ln);text-align:right;font-variant-numeric:tabular-nums;vertical-align:top}
  .items tbody td:first-child{text-align:left;padding-right:10px}
  .it-nm{font-weight:600;line-height:1.35}
  .it-sub{font-size:10px;color:var(--mut);margin-top:1px}
  .it-amt{font-weight:700}
  .gpill{color:var(--ok);font-weight:600}
  /* Totals */
  .foot{display:flex;justify-content:flex-end;margin-top:14px}
  .tbox{width:260px;max-width:100%}
  .t-row{display:flex;justify-content:space-between;padding:5px 0;font-size:12.5px;color:#444;font-variant-numeric:tabular-nums}
  .t-row.disc span:last-child{color:#EF4444}
  .grand{margin-top:8px;padding:11px 14px;border-radius:11px;background:linear-gradient(135deg,var(--brand),var(--brand2));color:#fff;display:flex;justify-content:space-between;align-items:center}
  .grand .g-lbl{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.8px;opacity:.95}
  .grand .g-val{font-size:20px;font-weight:800;letter-spacing:-.3px;font-variant-numeric:tabular-nums}
  /* Pay block */
  .pay{display:flex;gap:14px;align-items:center;margin-top:18px;padding:14px;border:1px solid var(--ln);border-radius:12px;background:var(--soft)}
  .pay img{width:104px;height:104px;border-radius:8px;flex:none;background:#fff;padding:5px;border:1px solid var(--ln)}
  .pay-info{min-width:0}
  .pay-h{font-size:10px;font-weight:700;color:var(--mut);text-transform:uppercase;letter-spacing:1px}
  .pay-id{font-size:14px;font-weight:800;color:var(--brand2);margin-top:3px;word-break:break-all}
  .pay-apps{font-size:10.5px;color:var(--mut);margin-top:3px}
  /* Footer */
  .ftr{text-align:center;margin-top:20px;padding-top:14px;border-top:1px solid var(--ln);color:var(--mut)}
  .ftr-thanks{font-size:12px;font-weight:600;color:var(--ink)}
  .ftr-shop{font-size:11px;margin-top:2px}
  .wm{font-size:9px;color:#C2C7D0;margin-top:7px;letter-spacing:.3px}
  @media (max-width:430px){
    .doc{padding:18px 14px}
    .parties{flex-direction:column;gap:8px}
    .pcard.payment{width:100%;text-align:left;flex-direction:row;justify-content:space-between;align-items:center}
    .tbox{width:100%}
    .pay{flex-direction:column;text-align:center}
    .pay-id{word-break:break-all}
    .items thead th.col-rate{display:none}
    .items tbody td.col-rate{display:none}
  }
  @media print{ body{background:#fff} .doc{padding:14px} .grand,.logo{-webkit-print-color-adjust:exact;print-color-adjust:exact} }
</style></head><body>
<div class="doc">

  <div class="hd">
    <div class="hd-l">
      <div class="logo">${monogram}</div>
      <div style="min-width:0">
        <div class="sh-name">${esc(s.name||'Your Shop')}</div>
        <div class="sh-meta">
          ${s.address?esc(s.address)+'<br>':''}
          ${s.phone?esc(s.phone):''}${s.gstin?(s.phone?' · ':'')+'GSTIN '+esc(s.gstin):''}
          ${s.email?'<br>'+esc(s.email):''}
        </div>
      </div>
    </div>
    <div class="hd-r">
      <div class="inv-kind">${anyGST?'Tax Invoice':'Invoice'}</div>
      <div class="inv-no">${esc(invoiceNo)}</div>
      ${dateTime?`<div class="inv-dt">${esc(dateTime)}</div>`:''}
      <div><span class="badge">${esc(status)}</span></div>
    </div>
  </div>

  <div class="rule"></div>

  <div class="parties">
    <div class="pcard billed">
      <div class="plabel">Billed To</div>
      <div class="pname">${esc(custName)}</div>
      <div class="pmeta">
        ${custPhone?esc(custPhone):''}
        ${custGSTIN?(custPhone?'<br>':'')+'GSTIN '+esc(custGSTIN):''}
      </div>
    </div>
    <div class="pcard payment">
      <div class="plabel">Payment</div>
      <div class="pay-val">${esc(payMode)}</div>
    </div>
  </div>

  <table class="items">
    <thead><tr>
      <th>Item</th>
      <th>Qty</th>
      <th class="col-rate">Rate</th>
      ${anyGST?'<th>GST</th>':''}
      <th>Amount</th>
    </tr></thead>
    <tbody>
      ${rows.map(it=>`
      <tr>
        <td>
          <div class="it-nm">${esc(it.nm)}</div>
          ${(it.hsn||it.disc>0)?`<div class="it-sub">${it.hsn?'HSN '+esc(it.hsn):''}${(it.hsn&&it.disc>0)?' · ':''}${it.disc>0?'Disc '+rs(it.disc):''}</div>`:''}
        </td>
        <td>${it.q}</td>
        <td class="col-rate">${rs(it.rate)}</td>
        ${anyGST?`<td><span class="gpill">${it.gstR>0?it.gstR+'%':'—'}</span></td>`:''}
        <td class="it-amt">${rs(it.tot)}</td>
      </tr>`).join('')}
    </tbody>
  </table>

  <div class="foot">
    <div class="tbox">
      <div class="t-row"><span>Subtotal</span><span>${rs(subtotal)}</span></div>
      ${itemDiscTotal>0?`<div class="t-row disc"><span>Item Discount</span><span>-${rs(itemDiscTotal)}</span></div>`:''}
      ${billDisc>0?`<div class="t-row disc"><span>Bill Discount</span><span>-${rs(billDisc)}</span></div>`:''}
      ${taxRows}
      <div class="grand"><span class="g-lbl">Grand Total</span><span class="g-val">${rs(grandTotal)}</span></div>
    </div>
  </div>

  ${showQR?`
  <div class="pay">
    <img src="https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=${encodeURIComponent('upi://pay?pa='+s.upi+'&pn='+(s.name||'Shop')+'&am='+num(grandTotal).toFixed(2)+'&cu=INR&tn=Bill '+invoiceNo)}" alt="Scan to pay">
    <div class="pay-info">
      <div class="pay-h">Scan &amp; Pay</div>
      <div class="pay-id">${esc(s.upi)}</div>
      <div class="pay-apps">Works with GPay · PhonePe · Paytm · any UPI app</div>
    </div>
  </div>`:''}

  <div class="ftr">
    <div class="ftr-thanks">Thank you for your business!</div>
    <div class="ftr-shop">${esc(s.name||'Your Shop')}</div>
    ${watermark?'<div class="wm">Powered by ShopBill Pro · TradeCrest Technologies Pvt. Ltd.</div>':''}
  </div>

</div>
</body></html>`;
  }

  root.renderShopBill = renderShopBill;
  if (typeof module !== 'undefined' && module.exports) module.exports = renderShopBill;
})(typeof window !== 'undefined' ? window : this);
