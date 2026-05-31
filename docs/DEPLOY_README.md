# ShopBill Pro v9 — DEPLOY PACKAGE (Step 7 + 8)

Backend is already live (SQL 106/107, Realtime, VAPID secrets, both edge functions).
This package is the **front-end drop-in**. Every file mirrors your repo root.

## 📁 COPY THESE INTO YOUR REPO (overwrite where noted)

| File in this package | Repo destination | Action |
|---|---|---|
| `bills.html` | `bills.html` (root) | **REPLACE** (already patched: bill link + soundbox) |
| `settings.html` | `settings.html` (root) | **REPLACE** (already patched: Razorpay connect panel) |
| `service-worker.js` | `service-worker.js` (root) | **REPLACE** (v1.7.0 + push handlers) |
| `bill.html` | `bill.html` (root) | **NEW** (customer bill page) |
| `lib/pay-link.js` | `lib/pay-link.js` | **NEW** |
| `lib/pay-announce.js` | `lib/pay-announce.js` | **NEW** |
| `lib/pay-realtime.js` | `lib/pay-realtime.js` | **NEW** |
| `lib/pay-push.js` | `lib/pay-push.js` | **NEW** |
| `audio/pay/en/*.mp3` (34) | `audio/pay/en/` | **NEW** |
| `audio/pay/hi/*.mp3` (34) | `audio/pay/hi/` | **NEW** |

All 3 edited files were patched programmatically against your actual code, kept
CRLF line endings, and every inline `<script>` was syntax-checked. No hand-editing
needed — just replace.

## What changed in each edited file
- **bills.html**: (1) 4 new `lib` script tags after `conversion.js`; (2) `sendBillWA()`
  is now `async` and appends `🔗 View/Download` link + (Pro/Business) `💸 Pay online`
  Razorpay link to the WhatsApp message; (3) init now unlocks audio on first tap and
  starts the Realtime soundbox for paid plans.
- **settings.html**: adds the **Razorpay connect** panel under the UPI ID field
  (shown only when `isPro()`), plus `refreshRzpPanel()` / `saveRzpCreds()`.
- **service-worker.js**: `SW_VERSION` → `v1.7.0-pwa-push`; adds `push` +
  `notificationclick` handlers (icons fixed to your real `icon-192x192.png` /
  `icon-72x72.png`). The cache-free pass-through fetch handler is **unchanged**.

## DEPLOY
1. Copy all files above into the repo (GitHub Desktop).
2. Commit + push → Vercel auto-deploys both projects.
3. Verify the SW updated: open the app, DevTools → Application → Service Workers,
   confirm `v1.7.0-pwa-push` active.

## AFTER DEPLOY — connect Razorpay (per shop, to enable auto-confirm)
1. In the app: **Settings** → scroll to UPI ID → **Razorpay** panel (Pro/Business
   only) → paste **Key ID + Key Secret + Webhook Secret** → Connect.
2. In Razorpay dashboard → Webhooks → add:
   `https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/bill-payment-webhook`
   secret = the same Webhook Secret; events: `payment_link.paid`, `qr_code.credited`,
   `payment.captured`.

## NOTES
- Free shops: bill link + PDF + UPI-intent pay (watermarked). No Razorpay needed —
  the free UPI button uses the existing `shops.upi` (Settings → UPI ID).
- The soundbox spoken amount uses the bundled clips (auto voice). Replace any clip
  in `audio/pay/en|hi/` with your own recording later — same filename.
- Web Push public key: when you wire the "enable alerts" toggle, use:
  `BKKNQi9Efig6h9k5PyX24m2efwTU8H8cN3ejm3c9nL8HMoSobozUZpfNDXxpE0axms5e9TLgaV7C7Q6QvdnQfQQ`

## TEST (Indian Curry, Business)
See the test plan in the main v9 bundle (`docs/TEST_PLAN.md`). Quick path:
send a bill → open the link on a phone → PDF + UPI button work → connect Razorpay
test keys → pay a test link → app open shows toast + chime + spoken amount.
