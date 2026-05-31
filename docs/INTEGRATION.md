# INTEGRATION — v9 Payments, wired to the ACTUAL repo (shopbillpro17)

All anchors below are real line references from the uploaded repo. Per your
rules: **targeted insertion, never regex bulk edits, never full rewrites.**

Good news from the audit — two things you already have, so **less work than planned**:
- `bills.html` already sets `window._sb` (line 588). ✓ No client-init fix needed.
- `settings.html` already has a **UPI ID field** (`#ss-upi`, line 1146) that saves to
  `shops.upi` (line 1581). ✓ The free UPI-intent button needs NO new settings UI.

---

## A. `bills.html`

### A1. Load the modules — after the existing lib includes (after line 65)
Current block:
```html
63: <script src="lib/sidebar-engine.js"></script>
64: <script src="lib/auth-pin.js"></script>
65: <script src="conversion.js"></script>
```
Insert after line 65:
```html
<script src="lib/pay-link.js"></script>
<script src="lib/pay-announce.js"></script>
<script src="lib/pay-realtime.js"></script>
<script src="lib/pay-push.js"></script>
```

### A2. Add the bill link to the existing WhatsApp message (`sendBillWA`, line 854)
The function already builds `msg` and opens wa.me. Make it async and append the link.
Replace the body of `sendBillWA()` with:
```js
async function sendBillWA(){
  const b=_curPreviewBill;if(!b)return;
  const wa=(b.customer_wa||'').replace(/\D/g,'');
  if(!wa||wa.length<10){toast('No WhatsApp number for this customer','e');return}
  const s=_shop||{};

  // v9: public bill link (+ optional Razorpay auto-confirm link for Pro/Business)
  let linkLine='', payLine='';
  try{
    const link=await SBPPay.getBillLink(b.id);
    if(link.ok){ linkLine='\n🔗 View/Download: '+link.url; }
    if(typeof isPro==='function' && isPro()){
      const g=await SBPPay.createGatewayLink(b.id,'link');
      if(g && g.ok && g.short_url){ payLine='\n💸 Pay online: '+g.short_url; }
    }
  }catch(_){}

  const msg=`🧾 *INVOICE — ${s.name||'ShopBill Pro'}*\n━━━━━━━━━━━━━━━━━━\n📋 Invoice: *${b.invoice_no}*\n📅 Date: ${fDate(b.invoice_date)}\n━━━━━━━━━━━━━━━━━━\n👤 *${b.customer_name}*\n\n✅ *Grand Total: ${fINR(b.grand_total)}*\n💳 Payment: ${b.payment_mode}\n${s.upi?'📲 UPI: '+s.upi:''}${linkLine}${payLine}\n\n🙏 Thank you!\n_ShopBill Pro by TradeCrest Technologies_`;
  window.open('https://wa.me/91'+String(wa).replace(/\D/g,'').slice(-10)+'?text='+encodeURIComponent(msg),'_blank');
}
```
> `_shop` (line 593) already holds the shop incl. `_shop.upi`. `isPro()` is global
> (defined in shared/auth.js per your settings audit).

### A3. Unlock audio + start the soundbox once (Pro/Business)
Add inside your post-load init (after `_shop`/`_shopId` are set, ~line 1471+),
but the audio unlock MUST be triggered by a user tap to satisfy autoplay policy.
Simplest: unlock on the first tap anywhere, then start realtime:
```js
document.addEventListener('click', function _unlock(){
  if(window.SBPAnnounce) SBPAnnounce.unlock();
  document.removeEventListener('click', _unlock);
}, {once:true});

if(typeof isPro==='function' && isPro() && _shopId && window.SBPPayRealtime){
  SBPPayRealtime.start(_shopId);
}
```

---

## B. `settings.html` — add ONLY the Razorpay connect panel (Pro/Business)

The UPI field already exists, so add just the gateway panel. Put the markup near
the UPI field (after line 1146’s `.ff` block). Gate the whole panel with `isPro()`.

Markup:
```html
<div id="rzp-connect" class="ff" style="display:none;flex-direction:column;gap:8px">
  <label>Razorpay (auto-confirm customer payments)</label>
  <input type="text" id="rzp-key-id"  placeholder="Key ID (rzp_live_… / rzp_test_…)">
  <input type="password" id="rzp-key-secret" placeholder="Key Secret">
  <input type="password" id="rzp-wh-secret"  placeholder="Webhook Secret">
  <button type="button" class="btn" onclick="saveRzpCreds()">Connect Razorpay</button>
  <div id="rzp-status" style="font-size:12px;color:var(--t2)"></div>
</div>
```
Script (add near the other settings JS, ~line 1581 area or end-of-file script):
```js
async function refreshRzpPanel(){
  const panel=document.getElementById('rzp-connect'); if(!panel) return;
  if(typeof isPro!=='function' || !isPro()){ panel.style.display='none'; return; }
  panel.style.display='flex';
  try{
    const {data}=await _sb.rpc('sbp_payment_connection_status',{p_shop_id:window._shopId||window.SBP?.shopId});
    document.getElementById('rzp-status').textContent =
      (data&&data.connected)?'✓ Connected':'Not connected yet';
  }catch(_){}
}
async function saveRzpCreds(){
  const shopId=window._shopId||window.SBP?.shopId;
  const r=await _sb.rpc('sbp_save_payment_creds',{
    p_shop_id:shopId,
    p_key_id:document.getElementById('rzp-key-id').value.trim(),
    p_key_secret:document.getElementById('rzp-key-secret').value.trim(),
    p_webhook_secret:document.getElementById('rzp-wh-secret').value.trim()
  });
  const el=document.getElementById('rzp-status');
  if(r&&r.ok){ el.textContent='✓ Connected'; el.style.color='#16a34a'; }
  else { el.textContent='Error: '+(r&&r.error||'failed'); el.style.color='#b91c1c'; }
}
// call refreshRzpPanel() after settings load
```
Errors returned: `plan_required | not_owner | missing_keys`.

### B2. (Optional) Enable app-closed alerts toggle
```js
const VAPID_PUBLIC_KEY = "REPLACE_WITH_VAPID_PUBLIC_KEY"; // same keypair as fn env
await SBPPayPush.enable(window._shopId, VAPID_PUBLIC_KEY);
```

---

## C. `service-worker.js` (v1.6.0 → v1.7.0)
- Change `const SW_VERSION = 'v1.6.0-minimal-pwa-enable';` → `'v1.7.0-pwa-push';`
- Paste the two listeners from `public/sw-push-additions.js` at the END of the file.
- **Do not touch** the empty pass-through `fetch` handler (the file documents why).

---

## D. `vercel.json` — add a clean bill route (optional but recommended)
`cleanUrls:true` already means `/bill` serves `bill.html`, so `/bill?b=..&t=..` works
out of the box once `bill.html` is at web root. No rewrite strictly required.
If you want a path style `/bill/<id>` later, add to `rewrites`:
```json
{ "source": "/bill/:id", "destination": "/bill" }
```
(then read the id from the path). Not needed for launch.

---

## E. Razorpay dashboard (per connected shop, one-time)
1. Shop creates a Razorpay account (no GST needed — PAN + bank + below-threshold declaration).
2. Razorpay → Settings → Webhooks → add:
   `https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/bill-payment-webhook`
   with a **webhook secret** (paste the SAME secret into the app's Connect panel),
   events: `payment_link.paid`, `qr_code.credited`, `payment.captured`.
3. Shop pastes Key ID + Key Secret + Webhook Secret into the app's Connect panel.

---

## NOT TOUCHED (kept separate, by design)
- `supabase/functions/razorpay-webhook` (Flow A — subscription billing → `process_razorpay_webhook`). Untouched.
- The empty SW fetch handler. Untouched.
- The existing Settle flow / `bills.status` semantics — Phase 2 reuses `status='Paid'`.
