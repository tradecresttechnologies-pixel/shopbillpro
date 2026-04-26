# 🚀 ShopBill Pro — Full Build with SaaS Admin Panel

**Replace your repo with these files. Run BOTH SQL migrations.**

---

## What's in this build

- All previous audit fixes (62 bugs, Phase 1 UPI, Reports Pro)
- **NEW: Full SaaS admin panel with Razorpay automation**
  - Encrypted settings (paste Razorpay creds in admin UI)
  - Razorpay webhook → auto-activates plans (zero manual SQL)
  - Subscription approval queue with one-click approve/reject
  - User management (search, plan change, suspend)
  - Real metrics (MRR, ARR, conversion, churn)
  - Revenue charts + recent payments
  - Signup funnel + activation rate

---

## ⚠️ DEPLOY ORDER — DO NOT SKIP STEPS

### Step 1 — Run BOTH SQL files in Supabase SQL Editor

**1a. First time only (if not done):** `audit_round_db_patch.sql`
**1b. New:** `admin_panel_full.sql`

Both are idempotent (safe to re-run).

### Step 2 — Set the encryption key (one-time, critical)

In Supabase SQL Editor:

```sql
ALTER DATABASE postgres SET app.encryption_key = 'replace-with-your-32-character-random-string';
```

Then **restart the database**: Supabase Dashboard → Settings → Database → Restart.

This key encrypts the Razorpay Key Secret. **Without it, secret storage will fail.**
**Save the key somewhere safe** — if you lose it, all stored secrets become unreadable.

### Step 3 — Set the admin master password

In Supabase SQL Editor (replace with your chosen password):

```sql
SELECT admin_set_master_token('YOUR_NEW_ADMIN_PASSWORD_HERE');
```

This becomes the password for `admin-login.html`. Until you run this, the default `SBP_ADMIN_2024_SECURE` still works as a fallback.

### Step 4 — Push files to GitHub

Replace your repo's contents with this package, commit, push. Vercel auto-deploys.

### Step 5 — Log into admin panel

Open: `https://app.shopbillpro.in/admin-login.html`

Enter your master password from Step 3.

### Step 6 — Configure Razorpay in admin

Admin panel → **Settings** → fill:
- **Razorpay Mode**: test (start here) or live
- **Razorpay Key ID**: from dashboard.razorpay.com → API Keys
- **Razorpay Key Secret**: same place (stored encrypted, never exposed to client)
- **UPI Receiving ID**: your UPI for direct payments
- **Admin WhatsApp**: 10-digit + country code (no `+`)
- **Plan prices**: leave default ₹99/₹199 or change

Click **Save All Changes**.

### Step 7 — Deploy Razorpay webhook

This is what auto-activates subscriptions when payments complete. See `supabase/functions/razorpay-webhook/README.md` for full instructions.

Quick version:
```bash
# 1. Install Supabase CLI (one-time)
npm i -g supabase

# 2. Link project
supabase login
supabase link --project-ref jfqeirfrkjdkqqixivru

# 3. Set webhook secret (any long random string)
supabase secrets set RAZORPAY_WEBHOOK_SECRET="paste-a-long-random-string-here"

# 4. Deploy
supabase functions deploy razorpay-webhook --no-verify-jwt
```

Then in **Razorpay Dashboard → Settings → Webhooks → Add**:
- URL: `https://jfqeirfrkjdkqqixivru.supabase.co/functions/v1/razorpay-webhook`
- Secret: same string as step 3 above
- Events: `payment.captured` (minimum)

### Step 8 — Test

1. Sign up a new test shop in your app (use Razorpay test card `4111 1111 1111 1111`)
2. Try to upgrade to Pro
3. Complete the test payment
4. Within seconds, the user's plan should flip to Pro automatically (no SQL needed)
5. Check Admin Panel → Subscriptions → should show as Active

---

## File map

### Modified (audit fixes)
admin-auth.js · admin-db.js · auth.js · bill-templates.html · billing.html · bills.html · cash-register.html · customers.html · dashboard.html · db.js · index.html · lang.js · marketing.html · pos-admin.html · recurring.html · reports.html · service-worker.js · settings.html · stock.html · subscription.html · supplier.html · sync.js · team.html · ui.js · wa-center.html · supabase.js

### Modified (admin panel)
admin-dashboard.html · admin-users.html · admin-revenue.html · admin-analytics.html

### NEW admin pages
admin-subscriptions.html · admin-settings.html

### NEW infrastructure
audit_round_db_patch.sql · admin_panel_full.sql · supabase/functions/razorpay-webhook/index.ts · supabase/functions/razorpay-webhook/README.md

---

## Daily workflow (after setup)

**Morning routine** — open `admin-dashboard.html`:
- See MRR, today's revenue, pending verifications, recent activity
- Pending count > 0 in nav badge means manual UPI payments to review

**Subscription review** — `admin-subscriptions.html`:
- Pending tab: review each, click ✅ Approve or ❌ Reject
- Razorpay payments auto-activate (no review needed)

**User support** — `admin-users.html`:
- Search by name/email/phone
- Click "Plan" to upgrade/downgrade/extend
- Click "Suspend" to lock out a user

**Revenue tracking** — `admin-revenue.html`:
- Stacked bar chart: Pro vs Business by day
- Top paying shops
- All recent payments with status

**Analytics** — `admin-analytics.html`:
- Signup funnel: Signup → First Bill → Paid → Active
- Drop-off at each step
- 30-day signup chart

---

## Security notes

- **Encryption key**: stored as Postgres database parameter, only readable via SQL. Anyone with full DB access can read encrypted secrets — same risk as any SQL backend.
- **Admin token**: SHA-256 hashed in `admin_settings.admin_token_hash`. Brute-force protected by lockout in `admin-auth.js` (5 attempts → 15 min lockout).
- **Webhook signature**: HMAC-SHA256 verified by Edge Function before reaching Postgres. Failed signatures still logged in `webhook_events` but never activate subscriptions.
- **Client never sees the Razorpay Key Secret** — it stays in Postgres, encrypted, only used by the webhook function (which has Service Role access).

---

## What still uses manual SQL?

After this build, **only one thing**: the initial encryption key setup (Step 2 above) and the master password bootstrap (Step 3). After that, everything else flows through the admin UI.

---

See `AUDIT_CHANGELOG.md` for the full bug-by-bug history.
