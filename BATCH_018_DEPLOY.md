# BATCH 018 — CIN Switch + Carryover Fixes

**Date:** 8 May 2026
**Migration #:** 019_company_details.sql
**Status:** Ready to deploy
**Scope:** Company Details admin panel · 3 legal pages · 18 marketing footers updated · BUG-007 (settings.html quirks mode) · BUG-013 (signup resume) · Loyalty void hook

---

## 🎯 What this batch ships

1. **CIN Switch — Company Details panel** that controls TradeCrest Technologies Pvt. Ltd.'s legal & contact details everywhere on the platform.
2. **3 new legal pages** — `/terms`, `/privacy`, `/refund` (previously 404).
3. **CIN line added to all 18 marketing footers** (incorporation date + registered office).
4. **BUG-007 fixed** — settings.html no longer renders in quirks mode.
5. **BUG-013 fixed** — signup → email confirm → login now correctly resumes shop creation.
6. **Loyalty void hook** — voiding a bill now reverses earned/redeemed loyalty points.

---

## 📦 Files in this deploy zip

```
batch018/
├── BATCH_018_DEPLOY.md                    ← you are here
├── db/migrations/
│   └── 019_company_details.sql            ← run FIRST in Supabase SQL Editor
├── admin-company-details.html             ← NEW admin page (replaces nothing)
├── admin_patches/                         ← 10 admin pages with new nav link
│   ├── admin-analytics.html
│   ├── admin-blog.html
│   ├── admin-categories.html
│   ├── admin-dashboard.html
│   ├── admin-revenue.html
│   ├── admin-seo-global.html
│   ├── admin-seo-pages.html
│   ├── admin-settings.html
│   ├── admin-subscriptions.html
│   └── admin-users.html
├── lib/
│   └── company-footer.js                  ← NEW dynamic footer lib (caches 24h)
├── site/                                  ← 3 NEW legal pages
│   ├── terms.html
│   ├── privacy.html
│   └── refund.html
├── site_existing/                         ← 18 marketing pages with CIN line in footer
│   ├── faq.html
│   ├── index.html
│   ├── pricing.html
│   ├── ... (all 18 pages from your /site/)
│   └── sitemap.xml                        ← updated with 3 legal URLs
├── settings.html                          ← BUG-007 fix (orphan modal removed)
├── index.html                             ← BUG-013 fix (signup resume)
└── bills.html                             ← Loyalty void hook + lib/loyalty.js script tag
```

---

## 🚀 DEPLOY STEPS — IN ORDER

### Step 1 — Database migration

Open Supabase SQL Editor → New Query → paste contents of `db/migrations/019_company_details.sql` → Run.

**Verification queries** (paste & run after the migration):

```sql
-- 1. Confirm seed landed with TradeCrest data
SELECT cin, pan, tan, registered_address, support_phone
FROM sbp_company_details;
-- Expected: U62099UP2026PTC247501 / AANCT1122A / LKNT09100A / 529, Harsewakpur... / +91-7800766561

-- 2. Test public RPC (anon-callable)
SELECT sbp_get_company_details_public();
-- Expected: { ok: true, data: {...} }

-- 3. Test admin RPC with default token
SELECT sbp_admin_get_company_details('SBP_ADMIN_2024_SECURE');
-- Expected: { ok: true, data: {full row} }
-- (or with whatever password you've set via admin_set_master_token)
```

**If any verification fails:**
- "permission denied" on RPC → re-grant: `GRANT EXECUTE ON FUNCTION public.sbp_get_company_details_public() TO authenticated, anon;`
- "function admin_verify_token does not exist" → migration `admin_panel_full.sql` was never run; deploy that first, then re-run 019.

### Step 2 — Push files to GitHub

The file layout in this zip mirrors your repo structure. Copy each file to the matching path in your repo:

| From zip | To repo |
|---|---|
| `admin-company-details.html` | `/admin-company-details.html` |
| `admin_patches/admin-*.html` | `/admin-*.html` (overwrites the 10 admin pages) |
| `lib/company-footer.js` | `/lib/company-footer.js` |
| `site/terms.html` | `/site/terms.html` |
| `site/privacy.html` | `/site/privacy.html` |
| `site/refund.html` | `/site/refund.html` |
| `site_existing/*.html` | `/site/*.html` (overwrites the 18 marketing pages) |
| `site_existing/sitemap.xml` | `/site/sitemap.xml` |
| `settings.html` | `/settings.html` (BUG-007) |
| `index.html` | `/index.html` (BUG-013) |
| `bills.html` | `/bills.html` (loyalty void) |

Commit message suggestion:
```
Batch 018: CIN switch — company details admin panel, legal pages,
18 marketing footers updated with CIN/registered office, BUG-007
(settings.html quirks mode), BUG-013 (signup resume), loyalty void hook
```

Vercel auto-deploys on push.

### Step 3 — Verify on production

Run through this checklist on `app.shopbillpro.in` (app) and `shopbillpro.in` (marketing):

- [ ] **Admin panel:** Visit `/admin-login.html` → log in → click "🏢 Company Details" in sidebar → page loads with TradeCrest data pre-filled → CIN/PAN/TAN/Date show as locked → support phone shows `+91-7800766561` → save flow works (try changing the support email → reload → still saved).
- [ ] **Marketing footer:** Visit `https://shopbillpro.in/` → scroll to bottom → footer shows new CIN line: `CIN: U62099UP2026PTC247501 · Incorporated 6 May 2026 · Registered Office: 529, Harsewakpur No 2, Sadar, Gorakhpur – 273014, Uttar Pradesh, India`
- [ ] **Terms page:** `https://shopbillpro.in/terms` loads (no more 404), full Terms text renders, footer has CIN line.
- [ ] **Privacy page:** `https://shopbillpro.in/privacy` loads, mentions DPDP Act 2023, lists subprocessors, mentions Data Protection Board grievance.
- [ ] **Refund page:** `https://shopbillpro.in/refund` loads, mentions 7-day satisfaction refund, Razorpay reconciliation flow.
- [ ] **BUG-007:** Open DevTools console on `/settings.html` — should show NO "quirks mode" warning.
- [ ] **BUG-013:** New email-confirm signup flow → confirm via email → log in → dashboard loads with shop already created (not blank/broken).
- [ ] **Loyalty void:** On a Pro/Business shop with loyalty active, void a bill that earned points → check console for `[loyalty void hook] reversed` log → customer's loyalty balance decreases.

### Step 4 — Marketing site routing (verify or fix)

The marketing site has links to `/terms`, `/privacy`, `/refund` already in its footer (existed before this batch). After deploy:

1. Visit `https://shopbillpro.in/terms`
2. **If it loads:** ✓ done, no action needed.
3. **If 404:** your marketing site's `vercel.json` doesn't have a rewrite for these clean URLs. Add this to your marketing project's `vercel.json` `rewrites` array:

```json
{ "source": "/terms",   "destination": "/site/terms.html" },
{ "source": "/privacy", "destination": "/site/privacy.html" },
{ "source": "/refund",  "destination": "/site/refund.html" }
```

(Or if your marketing project serves files directly from `/site/`, ensure cleanUrls:true is set, which strips `.html`.)

### Step 5 — Resubmit sitemap to Google Search Console

After the 3 legal pages are live, go to GSC → Sitemaps → re-submit `https://shopbillpro.in/sitemap.xml` so Google picks up the 3 new URLs.

---

## 🔄 Rollback plan

If anything goes wrong:

1. **Database:** The migration is safe — it only ADDs a table & 3 RPCs. To roll back:
   ```sql
   DROP FUNCTION IF EXISTS sbp_get_company_details_public();
   DROP FUNCTION IF EXISTS sbp_admin_update_company_details(text, jsonb);
   DROP FUNCTION IF EXISTS sbp_admin_get_company_details(text);
   DROP TABLE IF EXISTS sbp_company_details;
   ```
2. **Files:** `git revert` the deploy commit. Vercel auto-redeploys the previous version. The legal page URLs go back to 404 (the original state — no degradation).

---

## ⚠️ Things to know about

### A) Email accounts not yet created
The migration seeds `support@shopbillpro.in`, `billing@shopbillpro.in`, `legal@shopbillpro.in`, `privacy@shopbillpro.in`, `security@shopbillpro.in`, `hello@shopbillpro.in`, `no-reply@shopbillpro.in`, `vinay@shopbillpro.in` as the contact emails — but these mailboxes don't exist yet. **Set them up on Zoho Mail Free (or Hostinger Email)** in the next 7 days, otherwise:
- `support@` mails will bounce back to senders (legal exposure: T&C says we're reachable here)
- `privacy@` mails may bounce → DPDP Act risk
- `billing@` should be set up before paid subscriptions start (Razorpay will email this)

If you want to use a different email address than what's seeded, just go to Admin → Company Details and edit. Changes apply within 24h on public surfaces.

### B) Phone is your personal number
`+91-7800766561` is seeded as both `registered_phone` and `support_phone`. When you set up a business line (or a WhatsApp Business number), edit via Admin → Company Details. **Do not** edit by re-running the migration — that won't work (ON CONFLICT DO NOTHING preserves existing values).

### C) Legal pages are first drafts
The Terms/Privacy/Refund pages I generated are good-faith first drafts based on:
- Indian Companies Act 2013
- DPDP Act 2023 compliance requirements (Data Fiduciary, lawful basis, principal rights, grievance redressal)
- Razorpay refund policy norms

**Recommended:** Have your CA Deepak Kumar OR a service like Vakilsearch/LexStart review them before launch. They're publishable as-is for the beta period, but should be reviewed before paid subscribers in volume.

### D) Schema.org JSON-LD not yet updated
The `<script type="application/ld+json">` Organization markup on marketing pages still has the old data without CIN. This is a future polish item — it doesn't affect users or rankings critically. Will update in Batch 019 or 020.

### E) Things deferred to later batches
- **Universal Item Picker** → Batch 019 (next session)
- **Reports Engine** → Batch 020
- **Hotel/Salon/Retail polish** → Batches 021-023
- **Security Hardening** (RLS audit, XSS sweep, captcha, Sentry) → Batch 023.5 — non-skippable before paid launch

---

## ✅ Acceptance criteria

After deploy, this batch is "done" when:
1. Visit `/terms`, `/privacy`, `/refund` → all 3 load with TradeCrest details visible
2. Marketing footer shows CIN + Gorakhpur address line
3. Admin → Company Details panel works end-to-end (load + save)
4. settings.html doesn't trigger quirks-mode warning in DevTools
5. New signup with email-confirm enabled → after confirm + login, dashboard renders with shop
6. Voiding a loyalty-earning bill reverses points

If any of those fail, share a DevTools console screenshot and I'll fix in a hotfix.

---

**Built by Claude · Batch 018 · 8 May 2026 · ShopBill Pro · TradeCrest Technologies Pvt. Ltd.**
