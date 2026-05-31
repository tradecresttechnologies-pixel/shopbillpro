# TEST PLAN — v9 Payments (repo-accurate)

Test shop: **Indian Curry** `73aa8ede-6352-4549-8617-cccacdd5c821` (Business),
owner `sars0558`, PIN 1234, slug `glitz-glam`.

## Phase 1 (no gateway) — all tiers
1. **SQL:** run `db/migrations/106_bill_public_pay.sql`. No errors; schema reloads.
2. **Token RPC (authed):** open a bill in the app, trigger Send (📤) → the WhatsApp
   message now includes `🔗 View/Download: https://app.shopbillpro.in/bill?b=..&t=..`.
3. **Public page:** open that link in incognito → shop name, invoice no, date,
   customer, items, grand total render. "Download PDF" produces a PDF.
   Free shop → watermark shows; Pro/Business → no watermark.
4. **UPI intent:** with `shops.upi` set (Settings → UPI ID), open the link on a phone
   → "Pay via UPI" opens the GPay/PhonePe/Paytm chooser, amount pre-filled.
5. **Paid state:** settle the bill in-app (existing Settle flow sets status='Paid')
   → reopen link → badge shows "✓ Paid", Pay button hidden.

PowerShell smoke check:
```powershell
$body = @{ p_bill_id = "<BILL_ID>"; p_token = "<TOKEN>" } | ConvertTo-Json
Invoke-WebRequest -Method POST `
  -Uri "https://jfqeirfrkjdkqqixivru.supabase.co/rest/v1/rpc/sbp_get_bill_public" `
  -Headers @{ "apikey"="<ANON_KEY>"; "Authorization"="Bearer <ANON_KEY>"; "Content-Type"="application/json" } `
  -Body $body | Select-Object -ExpandProperty Content
# expect ok:true with a good token; ok:false invalid_token with a wrong one
```

## Phase 2 (gateway + soundbox) — Pro/Business, Razorpay TEST mode
1. **SQL:** run `db/migrations/107_bill_payments_gateway.sql`. Then:
   `ALTER PUBLICATION supabase_realtime ADD TABLE sbp_bill_payments;`
   Confirm Vault is on: `SELECT * FROM pg_extension WHERE extname='supabase_vault';`
2. **Edge functions:**
   ```
   supabase functions deploy create-bill-payment
   supabase functions deploy bill-payment-webhook --no-verify-jwt
   ```
   Set project secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`.
   (Generate VAPID keys once: `npx web-push generate-vapid-keys`.)
3. **Connect creds:** Settings → Razorpay panel → paste Indian Curry's **test**
   Key ID/Secret + a webhook secret → "Connect". `sbp_payment_connection_status`
   → connected:true. Confirm two Vault secrets exist:
   `SELECT name FROM vault.secrets WHERE name LIKE 'rzp_%';`
4. **Register webhook** in Razorpay test dashboard (URL + same secret + 3 events).
5. **Create link:** in-app Send → message includes `💸 Pay online: <short_url>`.
   Open it, pay with a Razorpay test success method.
6. **App open (soundbox):** app open + realtime started → green toast "₹X received"
   + chime (and spoken amount if `audio/pay/*` clips are deployed).
7. **App closed (push):** close app → repeat a test payment → OS notification
   "₹X received" (Android Chrome installed PWA; iOS needs 16.4+ installed PWA).
8. **Bill state:** the bill flips to status='Paid', a row lands in `sbp_bill_payments`.
9. **Idempotency:** redeliver the same webhook → no duplicate row, no second alert
   (`sbp_fn_record_payment` returns already:true).

## Rollback
- Both migrations are additive (IF NOT EXISTS columns/tables). To disable:
  set `sbp_shop_payment_creds.connected=false`, drop the new functions if needed.
  Existing billing, Settle flow, and the subscription webhook (Flow A) are untouched.
