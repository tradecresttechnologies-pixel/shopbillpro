# 🚀 ShopBill Pro — Audit Round Final Build
**This is the ONLY package you need to deploy. Replace your entire repo with these files.**

---

## What changed?

- **62 bugs** identified, **58 fixed** in code (audit round 1)
- **Phase 1 UPI** added: WhatsApp QR-image send + Mark-as-Paid follow-up
- **Reports professional upgrade**: GSTR-1, GSTR-3B, P&L, Payments tabs + period comparison
- **Dead code removed**: deleted unused `shared/` folder and unused `db-local.js`

---

## ⚠️ DEPLOY IN THIS ORDER

### Step 1 — Run the SQL patch (REQUIRED, do it FIRST)

1. Open Supabase → SQL Editor → New Query
2. Open `audit_round_db_patch.sql` from this package
3. Copy entire contents → paste into SQL Editor → Run
4. Verify no errors. This adds:
   - `next_invoice_no()` RPC (atomic invoice counter, prevents duplicate invoice numbers across devices)
   - `expire_lapsed_plans()` function (auto-downgrades expired paid users)
   - `subscription_apply_to_shop` trigger (admin verifies subscription → plan auto-activates)
   - Schema additions: `voided_at`, `audit_log`, `supply_type`, `plan_expires_at`, etc.

### Step 2 — Update payment configuration (REQUIRED before public launch)

Open `subscription.html`, find this block near the top of the `<script>` section:

```javascript
const SBP_PAY_CONFIG = {
  RAZORPAY_KEY:  'rzp_test_YOUR_KEY_HERE',     // ← Get from dashboard.razorpay.com
  RECEIVING_UPI: 'shopbillpro@paytm',          // ← Your actual receiving UPI ID
  ADMIN_WA:      '919999999999'                // ← Your WhatsApp (10-digit, no +)
};
```

Replace all 3 placeholder values. **Without this, payments will not work.**

### Step 3 — Deploy the files

There are **two ways** depending on your preference:

#### Option A — Replace everything (cleanest, recommended)

1. Open GitHub Desktop
2. In your `vinaykumars937/shopbillpro` repo folder, **delete all files except `.git/` and any deployment configs (`vercel.json`, `.gitignore` if present)**
3. Copy ALL files from this package into the repo folder
4. Commit message: `Audit round: 58 bug fixes + Phase 1 UPI + Pro Reports`
5. Push to GitHub → Vercel auto-deploys

#### Option B — Selective overwrite (riskier)

If you want to keep some local changes, replace **only these modified files**:

```
admin-auth.js
admin-db.js
auth.js
bill-templates.html
billing.html
bills.html
cash-register.html
customers.html
dashboard.html
db.js
index.html
lang.js
marketing.html
pos-admin.html
recurring.html
reports.html
service-worker.js
settings.html
stock.html
subscription.html
supplier.html
sync.js
team.html
ui.js
wa-center.html
```

Files that are **NEW** (didn't exist before, must add):

```
audit_round_db_patch.sql
AUDIT_CHANGELOG.md
AUDIT_CHANGELOG_ROUND2.md
README.md (this file)
```

Files **deleted** (must remove from your repo):

```
db-local.js              ← was dead code
shared/ folder           ← was duplicate dead code
```

### Step 4 — Hard refresh

Service worker version was bumped to `v1.3.0`. Existing PWA users may need:
- **Mobile:** Long-press app icon → Uninstall → reinstall from app.shopbillpro.in
- **Or:** Open Chrome DevTools → Application → Service Workers → Unregister → reload

### Step 5 — Verify

Run through the checklists at the end of:
- `AUDIT_CHANGELOG.md` (round 1 verification)
- `AUDIT_CHANGELOG_ROUND2.md` (round 2 verification)

---

## File status reference

### Files MODIFIED in this audit (25 total)
admin-auth.js, admin-db.js, auth.js, bill-templates.html, billing.html, bills.html, cash-register.html, customers.html, dashboard.html, db.js, index.html, lang.js, marketing.html, pos-admin.html, recurring.html, reports.html, service-worker.js, settings.html, stock.html, subscription.html, supplier.html, sync.js, team.html, ui.js, wa-center.html

### Files UNCHANGED (kept as-is from your original)
admin-analytics.html, admin-audit.html, admin-dashboard.html, admin-features.html, admin-login.html, admin-notifications.html, admin-revenue.html, admin-technical.html, admin-users.html, conversion.js, fix.css, manifest.json, scanner.js, shopbillpro_website.html, styles.css, supabase.js, upgrade-popup.js, icons/

### Files NEW (added by audit)
audit_round_db_patch.sql, AUDIT_CHANGELOG.md, AUDIT_CHANGELOG_ROUND2.md, README.md

### Files DELETED
db-local.js (was dead code, not used anywhere)
shared/ folder (was duplicate older copies, not used by any HTML page)

---

## Why was there a `shared/` folder?

Your original repo had a `shared/` folder with copies of `auth.js`, `db.js`, `sync.js`, `ui.js`, `db-local.js`, `styles.css`, `supabase.js`. **None of your HTML pages actually loaded from there** — they all pointed to root-level files. The `shared/` folder appears to have been an abandoned reorganization attempt. It's been removed since it would have caused confusion and possibly served stale code if Vercel routing changed.

---

## Quick verification commands (after deploy)

In your browser console at `app.shopbillpro.in/dashboard.html`:

```javascript
// Should NOT show "false" or undefined
console.log('Today function works:', typeof sbpToday === 'function');
console.log('Plan info works:', typeof _sbpPlanInfo === 'function');
console.log('Plan today:', _sbpPlanInfo());
```

In Supabase SQL Editor:

```sql
-- Should return 1 row with prefix='INV' and a counter number
SELECT * FROM next_invoice_no((SELECT id FROM shops LIMIT 1));
```

---

## Need help?

- See `AUDIT_CHANGELOG.md` for round 1 details (62 bugs)
- See `AUDIT_CHANGELOG_ROUND2.md` for round 2 details (Phase 1 UPI + Pro Reports)
- All bug numbers (#1, #2, etc.) are referenced in code comments where fixes were applied
