# 🚀 ShopBill Pro — Audit Round Final Build

**This is the ONLY package you need. Replace your repo with these files.**

---

## What's in this build

- **62 bug fixes** (audit findings #1 through #62)
- **Phase 1 UPI**: WhatsApp QR-image send + Mark-as-Paid follow-up
- **Reports Pro**: GSTR-1, GSTR-3B, P&L, Payments tabs with CSV exports
- **Cleanup**: Deleted unused `shared/` folder + dead `db-local.js` references

---

## ⚠️ DEPLOY IN THIS ORDER

### Step 1 — Run SQL patch (REQUIRED, do FIRST)

1. Open Supabase Dashboard → SQL Editor → New Query
2. Open `audit_round_db_patch.sql` from this package
3. Copy entire contents → paste → Run
4. Verify no errors

### Step 2 — Update payment config

Open `subscription.html`. Near top of `<script>` find:

```javascript
const SBP_PAY_CONFIG = {
  RAZORPAY_KEY:  'rzp_test_YOUR_KEY_HERE',
  RECEIVING_UPI: 'shopbillpro@paytm',
  ADMIN_WA:      '919999999999'
};
```

Replace all 3 placeholder values. **Without this, payments will not work.**

### Step 3 — Deploy

1. In your local repo, delete every file except `.git/` and any deployment configs
2. Copy ALL files from this package into the repo
3. Commit + push → Vercel auto-deploys

### Step 4 — Hard refresh

Service worker version was bumped to `v1.3.0`. Existing PWA users may need:
- Mobile: Long-press app → Uninstall → reinstall from app.shopbillpro.in
- Or: DevTools → Application → Service Workers → Unregister → reload

### Step 5 — Verify

- [ ] Today's Sales shows correct amount with credit bills present
- [ ] Manual bill saves → stock decreases in Stock page
- [ ] Cash bill → entry auto-appears in Cash Register
- [ ] Void bill → stock restored, ledger reversed if credit
- [ ] Reopen credit bill → ledger reverses, redirected to billing.html in edit mode
- [ ] Reports → GSTR-1 tab shows B2B/B2C split → Export B2B CSV opens cleanly in Excel
- [ ] Reports → P&L shows Net Sales / COGS / Net Profit
- [ ] Settings has UPI ID saved → bill → 📲 WA → "Bill + UPI QR Image" option appears
- [ ] Customers page → reminder bell → after WA opens → "Did they pay?" follow-up
- [ ] Subscription page → "I Paid via UPI" → "Payment Under Verification" (NOT instant unlock)
- [ ] Settings in Hindi mode loads without flash/blink
- [ ] WhatsApp links don't have `9191...` doubled country code

---

## File structure

### Modified (32 files)
admin-auth.js · admin-db.js · auth.js · bill-templates.html · billing.html · bills.html · cash-register.html · customers.html · dashboard.html · db.js · index.html · lang.js · marketing.html · pos-admin.html · recurring.html · reports.html · service-worker.js · settings.html · stock.html · subscription.html · supplier.html · sync.js · team.html · ui.js · wa-center.html · supabase.js

### Unchanged (stays as-is)
admin-analytics.html · admin-audit.html · admin-dashboard.html · admin-features.html · admin-login.html · admin-notifications.html · admin-revenue.html · admin-technical.html · admin-users.html · conversion.js · fix.css · manifest.json · scanner.js · shopbillpro_website.html · styles.css · upgrade-popup.js · icons/

### New
audit_round_db_patch.sql · README.md · AUDIT_CHANGELOG.md

### Deleted from your repo
- `db-local.js` — dead code (was 404'ing on every page)
- `shared/` folder — unreferenced duplicates

---

## Key fix summary

**Money & Trust:** Closed revenue exploit (#46), centralized payment config (#43-45), plan expiry enforced (#49), admin password SHA-256 hashed.

**Math:** Today's Sales = grand_total (#1, screenshot bug), voided excluded everywhere (#2/5/6), timezone fix across 13 files (#3), CGST/SGST/IGST split per supply_type (#4), post-discount taxable base (#7).

**Stock & Ledger:** Manual stock deduction (#15), void/reopen restore stock (#16/17), customer match by ID/phone (#9/12), settle blocks Credit (#8), cash register auto-record (#10).

**Sync/SW/Admin:** Atomic invoice counter RPC (#23), service worker rewrite with all assets (#19/20), admin revenue uses grand_total (#54), business plan counted (#55), users-table fallback (#56).

**UX:** Lang.js perf + late-load fix (#58/60/61) — fixes Hindi screen-blink, WA country code dup (#50), bulk send cap (#51/53), bill template via sessionStorage (#39), profit per unit display (#38), recurring "Generate All Due" no longer drops bills (#21).

**Phase 1 UPI:** Bill+QR-image option in WA send modal, Mark-as-Paid follow-up after reminder.

**Reports Pro:** GSTR-1 (B2B+B2C with GSTN-format exports), GSTR-3B summary, P&L statement (true profit using cost prices), Payments breakdown.

---

See `AUDIT_CHANGELOG.md` for full bug-by-bug breakdown.
