# ShopBill Pro v9 — Payments & Auto-Confirmation (repo-accurate bundle)

Built and **audited against the live repo `shopbillpro17`**. Razorpay BYO per shop,
no fund pooling. Free/Pro/Business all get bill link + PDF + UPI-intent pay (Free
watermarked); the auto-confirm soundbox is Pro+Business (`isPro()`).

This corrects the earlier draft against the real schema and conventions:
- Migrations renumbered **106 / 107** (repo is at 105).
- Real columns used: **`grand_total`**, `invoice_no`, `invoice_date`, `customer_name`,
  `status` ('Paid'/'Partial'/…), `payment_mode`; shop UPI = **`shops.upi`**;
  bill_items = `item_name/qty/rate/line_total/gst_amount/bill_id`.
- Secrets stored in **Supabase Vault** (the repo's proven pattern from 047), NOT raw
  pgcrypto (which 046/047 document as broken on managed Supabase).
- Reuses the existing **Settle / `status='Paid'`** flow instead of a parallel paid flag.
- Service worker gets push handlers only (v1.6.0→v1.7.0); the cache-free pass-through
  fetch handler is left untouched (the file documents a prior stale-cache disaster).
- Separate from the existing subscription webhook `razorpay-webhook` (Flow A).

---

## 🚀 DEPLOY PATHS (in order)

| # | Action | Repo path | Type |
|---|--------|-----------|------|
| 1 | Run SQL (Phase 1) | `db/migrations/106_bill_public_pay.sql` | NEW |
| 2 | Run SQL (Phase 2) | `db/migrations/107_bill_payments_gateway.sql` | NEW |
| 3 | Enable Realtime on payments | `ALTER PUBLICATION supabase_realtime ADD TABLE sbp_bill_payments;` | ONE-TIME |
| 4 | Deploy edge fn | `supabase/functions/create-bill-payment/index.ts` | NEW |
| 5 | Deploy edge fn `--no-verify-jwt` | `supabase/functions/bill-payment-webhook/index.ts` | NEW |
| 6 | Set fn secrets (VAPID_*) | Supabase project secrets | ONE-TIME |
| 7 | Add hosted bill page (web root) | `public/bill.html` → repo root | NEW |
| 8 | Add client modules | `lib/pay-link.js`, `lib/pay-announce.js`, `lib/pay-realtime.js`, `lib/pay-push.js` | NEW |
| 9 | SW push handlers (v1.6.0→v1.7.0) | `public/sw-push-additions.js` → into `service-worker.js` | EDIT |
| 10 | Wire UI hooks | `docs/INTEGRATION.md` (bills.html §A, settings.html §B) | EDIT |
| 11 | (Optional) generate audio | `audio/pay/generate_clips.py` → `audio/pay/<lang>/*.mp3` | NEW |
| 12 | Verify | `docs/TEST_PLAN.md` (PowerShell + UI) | TEST |

> Order honours your rule: **SQL → edge functions → UI → verify.**
> Steps 1–8 are standalone build-ready files. Steps 9–10 are targeted splices
> with real line anchors in `docs/INTEGRATION.md`.

---

## Contents
```
db/migrations/
  106_bill_public_pay.sql          Phase 1: pay_token + public bill RPC (reuses status)
  107_bill_payments_gateway.sql    Phase 2: Vault creds, payments, push subs, RPCs
supabase/functions/
  create-bill-payment/index.ts     Razorpay link/QR per bill (shop's own keys)
  bill-payment-webhook/index.ts    Customer-payment webhook → mark Paid + push (Flow B)
public/
  bill.html                        Customer bill page: view, PDF, UPI intent, watermark
  sw-push-additions.js             SW push/notificationclick (merge into service-worker.js)
lib/
  pay-link.js                      Bill link, WhatsApp text, UPI intent, gateway link
  pay-announce.js                  Soundbox: chime + spoken amount from clips
  pay-realtime.js                  Supabase Realtime → fire soundbox when app open
  pay-push.js                      Web Push subscribe for app-closed alerts
audio/pay/
  MANIFEST.md                      31 clips/lang the announcer needs
  generate_clips.py                gTTS bootstrap for en + hi
docs/
  INTEGRATION.md                   Real-line-anchor splices into bills.html / settings.html / SW
  TEST_PLAN.md                     Phase 1 + Phase 2 test + rollback
```

## Already in place (less work than planned)
- `bills.html` already sets `window._sb` (line 588) — no init fix needed.
- `settings.html` already has a UPI ID field saving to `shops.upi` — the free
  UPI-intent button needs NO new settings UI; only the Razorpay panel is added.

## Still to provide
- **VAPID keys** for Web Push (`npx web-push generate-vapid-keys`) → set as fn secrets
  and the public key in the settings push toggle.
- **Audio clips** (run `generate_clips.py` or record your own) before the spoken
  amount works; the chime + on-screen toast work without them.

## Sequencing
Per the plan, this track slots in **after** the current v8.2/v8.3/v8.4 + v7.0 deploys.
