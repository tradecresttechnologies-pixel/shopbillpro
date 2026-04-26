# Razorpay Webhook — Deploy Instructions

## What this does
When a customer pays via Razorpay, Razorpay POSTs a payment event to your
public webhook URL. This Edge Function:
1. Verifies the HMAC-SHA256 signature using your shared secret
2. Calls Postgres RPC `process_razorpay_webhook` to log + activate the subscription
3. The DB trigger then auto-flips the user's plan to Pro/Business

Net result: customer pays → plan activates within seconds. **Zero manual SQL.**

## Prerequisites
- Supabase project (you have this)
- Supabase CLI installed (one-time): https://supabase.com/docs/guides/cli/getting-started
- Razorpay account in test or live mode

## Deployment steps

### 1. Install Supabase CLI (skip if already done)
```bash
# macOS
brew install supabase/tap/supabase
# or via npm
npm i -g supabase
```

### 2. Link your project
```bash
cd /path/to/your/shopbillpro/repo
supabase login
supabase link --project-ref jfqeirfrkjdkqqixivru   # your project ref
```

### 3. Set secret (webhook signing secret you'll enter in Razorpay dashboard)
Choose ANY long random string (32+ characters). You'll paste this same string into Razorpay dashboard later.

```bash
supabase secrets set RAZORPAY_WEBHOOK_SECRET="paste-your-long-random-string-here"
```

### 4. Deploy the function
```bash
supabase functions deploy razorpay-webhook --no-verify-jwt
```

The `--no-verify-jwt` flag is required because Razorpay doesn't pass a Supabase JWT.

After deploy, the webhook URL will be:
```
https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/razorpay-webhook
```

### 5. Configure Razorpay dashboard
1. Log into https://dashboard.razorpay.com
2. Go to **Settings → Webhooks → Add New Webhook**
3. **Webhook URL**: paste the URL from step 4
4. **Secret**: paste the SAME string you used in step 3
5. **Events to subscribe**: tick at minimum:
   - `payment.captured` (this is what activates plans)
   - `payment.failed` (for logging only)
6. Save

### 6. Test it
1. In your app, do a test payment using Razorpay test card (`4111 1111 1111 1111`, any future expiry, any CVV)
2. After payment, check Supabase Dashboard → Table Editor → `webhook_events`
3. You should see a row with `signature_ok=true, processed=true`
4. Check `subscriptions` table — the matching row should have `status='active'`
5. Check `shops` table — the user's plan should now be `pro` or `business`

## Local testing
```bash
supabase functions serve razorpay-webhook --no-verify-jwt
```
Then use a tunnel like ngrok to expose `http://localhost:54321/functions/v1/razorpay-webhook` so Razorpay can reach it.

## Troubleshooting
- **`signature_ok=false` in webhook_events**: Secret mismatch. Make sure the same string is in both `supabase secrets set` AND Razorpay dashboard webhook secret.
- **No webhook events appearing**: Check Razorpay dashboard → Webhooks → click your webhook → "Recent deliveries" — look at the response code. 200 = good. 401 = signature failed. 500 = check Edge Function logs (`supabase functions logs razorpay-webhook --tail`).
- **Subscription not activating**: Means the webhook found no matching `pending_verification` subscription. Check that `subscription.html` is creating the subscription row with `payment_ref = razorpay_payment_id`.
