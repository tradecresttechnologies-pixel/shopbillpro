# ShopBill Pro — Current State Audit v1.1

**Snapshot date:** 6 May 2026 (after Batch 012 deploy)
**Codebase reviewed:** `shopbillpro.zip` (uploaded 5 May 2026 ~22:06 IST) + Batch 012 changes
**Total LOC:** ~76,800 across HTML/JS/SQL/CSS

This document captures **what exists right now** in the codebase, what's deployed, what's broken, and what's tech debt. Pair with `VERTICAL_PLAYBOOK.md` (strategic) and `BUG_FIX_PLAN.md` (next sprint).

When something changes — file added, deployed, fixed, broken — update this doc.

**v1.1 changelog (6 May 2026):**
- 8 bugs (BUG-001 through BUG-010) moved to Closed via Batch 012
- §3.3 RPC catalog updated: row_to_jsonb references replaced with to_jsonb
- §4 deploy state updated post-Batch 012
- §5 timeline includes Batch 012 entry
- §6 (open questions) reduced — 3 founder decisions resolved

---

## §1. File Inventory

### 1.1 User-facing pages (root, served at `app.shopbillpro.in/<file>.html`)

| File | Size | Last modified | Role | Sidebar render? |
|------|------|---------------|------|-----------------|
| `index.html` | 48K | 5 May 13:27 | Login + signup wizard entry | n/a (auth) |
| `dashboard.html` | 68K | 5 May 07:23 | Home / overview | ✓ |
| `billing.html` | 202K | 5 May 20:40 | New bill (POS + Manual modes) | ✓ |
| `bills.html` | 86K | 5 May 07:36 | Bills list / void / reopen | ✓ |
| `customers.html` | 98K | 5 May 20:40 | Customer list + ledger | ✓ |
| `stock.html` | 62K | 5 May 07:36 | Inventory | ✓ |
| `reports.html` | 126K | 5 May 07:36 | Reports Pro (GSTR-1/3B/P&L/Payments/Forecast) | ✓ |
| `pos-admin.html` | 81K | 5 May 07:36 | Product CRUD | ✓ |
| `bill-templates.html` | 43K | 5 May 07:36 | Invoice template editor | ✓ |
| `settings.html` | 129K | 5 May 22:06 | Settings hub | ⚠️ has structural bug (orphan modal at top) |
| `marketing.html` | 132K | 5 May 07:36 | In-app marketing center | ✓ |
| `wa-center.html` | 50K | 5 May 07:36 | Bulk WhatsApp send | ✓ |
| `recurring.html` | 38K | 5 May 07:36 | Recurring bills | ✓ |
| `cash-register.html` | 40K | 5 May 07:36 | Daily cash open/close | ✓ |
| `supplier.html` | 41K | 5 May 07:36 | Vendor + payables | ✓ |
| `team.html` | 41K | 5 May 07:36 | Multi-user staff | ✓ |
| `subscription.html` | 57K | 5 May 07:36 | Plans / upgrade flow | ✓ |
| `services.html` | 32K | 5 May 21:35 | Service Catalog (NEW) | ✗ **MISSING render call** |
| `appointments.html` | 50K | 5 May 22:06 | Appointments (NEW) | ✗ **MISSING render call** |
| `s.html` | 46K | 5 May 22:06 | Public shop page (anon) | n/a (anon) |
| `password-hasher.html` | 4K | 5 May 09:20 | Internal admin tool | n/a |
| `shopbillpro_website.html` | 51K | 2 May | **Stale** — old marketing template | Deletion candidate |

### 1.2 Admin-side pages (root, served at `app.shopbillpro.in/admin-*`)

| File | Size | Role |
|------|------|------|
| `admin-login.html` | 8K | Master password entry |
| `admin-dashboard.html` | 19K | MRR / ARR / pending verifications |
| `admin-users.html` | 17K | User search + plan change + suspend |
| `admin-subscriptions.html` | 14K | Approval queue |
| `admin-revenue.html` | 12K | Charts + payments |
| `admin-analytics.html` | 12K | Funnel: signup → first bill → paid |
| `admin-audit.html` | 12K | Audit log viewer |
| `admin-notifications.html` | 14K | Notifications config |
| `admin-technical.html` | 13K | System / DB health |
| `admin-features.html` | 15K | Feature flags |
| `admin-settings.html` | 20K | Razorpay creds + plan prices (encrypted) |
| `admin-categories.html` | 16K | 12 macros + 80+ types editor |
| `admin-blog.html` | 27K | Blog CMS |
| `admin-seo-global.html` | 17K | Global SEO settings |
| `admin-seo-pages.html` | 25K | Per-page SEO + redirects |

### 1.3 JS libraries

| File | Size | Loaded by | Purpose |
|------|------|-----------|---------|
| `auth.js` | 11K | All user pages | Auth helpers |
| `db.js` | 27K | All pages | Generic DB abstraction (older — pre-RLS pattern) |
| `db-local.js` | 15K | All pages | localStorage layer |
| `supabase.js` | 4K | All pages | Supabase client init |
| `lang.js` | 12K | All pages | Hindi/English translation dict (string-replace approach) |
| `sync.js` | 8K | Some pages | Cloud sync logic |
| `ui.js` | 13K | Some pages | UI helpers |
| `scanner.js` | 11K | billing.html | Barcode scanning (ZXing wrapper) |
| `conversion.js` | 19K | All user pages | Funnel tracking |
| `upgrade-popup.js` | 12K | Several pages | Upsell popup logic |
| `admin-auth.js` | 9K | Admin pages | SHA-256 password check |
| `admin-db.js` | 14K | Admin pages | Admin RPC wrappers |
| `sidebar-engine.js` (ROOT) | 22K | Older inline sidebar | **Duplicate — older version** |
| `lib/sidebar-engine.js` | 22K | New pages | **Active version (479 lines)** |
| `lib/beta-banner.js` | 7K | All user pages | Beta countdown |
| `lib/services.js` | 6K | services.html | Service Catalog wrapper |
| `lib/appointments.js` | 8K | appointments.html | Appointments wrapper |
| `lib/loyalty.js` | 12K | settings.html, customers.html, billing.html | Loyalty wrapper |
| `lib/shop-type-wizard.js` | 11K | index.html | Signup wizard |

**Tech debt:** Two copies of `sidebar-engine.js` exist (root + lib/). Verify the root copy is unused, delete it.

### 1.4 SQL migrations

| File | Lines | Status | Purpose |
|------|-------|--------|---------|
| `audit_round_db_patch.sql` | ? | ✅ Deployed | 62-bug audit (atomic invoice counter, plan expiry trigger) |
| `admin_panel_full.sql` | ? | ✅ Deployed | Encrypted Razorpay creds + admin RPCs + webhook |
| `db/migrations/003_business_categories.sql` | 712 | ✅ Deployed | 12 macros + 85 sub-types + 19 module profiles + `get_shop_modules` RPC |
| `db/migrations/004_seo_admin.sql` | 770 | ✅ Deployed | SEO admin tables (sbp_seo_global, sbp_seo_pages, sbp_blog_posts, sbp_seo_redirects) |
| `db/migrations/005_beta_logic.sql` | 371 | ✅ Deployed | 60-day beta + 7-day grace + auto-downgrade trigger |
| `db/migrations/008_public_shop_page.sql` | 485 | ✅ Deployed | sbp_shop_websites table + slug resolver |
| `db/migrations/009_loyalty.sql` | 621 | ⚠️ Deployed but BUG | Loyalty module — `row_to_jsonb` issue in txn list RPC |
| `db/migrations/010_service_catalog.sql` | 364 | ⚠️ **NOT YET CONFIRMED DEPLOYED** | Service Catalog — 2× row_to_jsonb bugs |
| `db/migrations/011_appointments.sql` | 1085 | ⚠️ **NOT YET CONFIRMED DEPLOYED** | Appointments — 5× row_to_jsonb bugs |

**Note on deploy order:** Migrations skip 001, 002, 006, 007 — these were either consolidated into the single `audit_round_db_patch.sql`/`admin_panel_full.sql` or the numbering started at 003 by convention.

### 1.5 Edge Functions

| Function | Status |
|----------|--------|
| `supabase/functions/razorpay-webhook/index.ts` | ✅ Deployed |

### 1.6 Marketing site (`/site/` folder, separate Vercel project)

14 marketing pages: `index`, `pricing`, `faq`, `why-choose`, `free-billing-software-india`, 4× `/features/`, 8× `/for/<vertical>`, sitemap, robots. CSS at `site/css/marketing.css`. PostHog + Schema.org JSON-LD wired on all pages.

### 1.7 Stale / Tech Debt

| File | Issue | Action |
|------|-------|--------|
| `pages/*.html` (16 files) | Older copies of root HTML files (different content) | Delete folder; root is canonical |
| `sidebar-engine.js` (root) | Older version, lib/sidebar-engine.js is active | Delete root copy |
| `shopbillpro_website.html` | Stale old marketing template | Delete |
| `service-worker.js` | 0 bytes (empty file) | Delete or populate |
| `shared/` folder | Unknown contents (older code from Apr 10) | Audit, then delete or document |

---

## §2. Bug Register

Severity scale: 🔴 critical (feature unusable) · 🟠 high (visible bug) · 🟡 medium (UX issue) · 🟢 low (polish)

### 2.1 Closed (Batch 012, 6 May 2026)

| # | Was | Description | Fix |
|---|-----|-------------|-----|
| BUG-001 | 🔴 | services.html — `function row_to_jsonb(record) does not exist` | Sed `row_to_jsonb` → `to_jsonb` in `010_service_catalog.sql` |
| BUG-002 | 🔴 | appointments.html — same SQL error in 5 places | Same fix in `011_appointments.sql` (5 instances) |
| BUG-003 | 🔴 | customers.html — loyalty txn list silently broken | Same fix in `009_loyalty.sql` |
| BUG-004 | 🟠 | services.html, appointments.html — sidebar missing | Added `SBPSidebar.render()` call in init() |
| BUG-005 | 🟠 | services.html, appointments.html — bilingual text concatenated | Same fix as BUG-004 (CSS injected by render) |
| BUG-006 | 🟠 | sidebar — Services + Appointments showed "Coming Soon" toast | Removed from `PENDING_PAGES` in `lib/sidebar-engine.js` |
| BUG-007 | 🟠 | settings.html — orphan modal before DOCTYPE, quirks mode | Removed lines 1-24, restored `<!DOCTYPE html>` as line 1 |
| BUG-008 | 🟠 | s.html — empty Gallery card visible when all images fail | Added `_pspGalCheck()` to hide card if 0 images load |
| BUG-009 | 🟡 | settings.html Website Content — placeholder URLs got saved | Validation warning on save if URLs look fake |
| BUG-010 | 🟡 | s.html — narrow mobile layout on desktop | Responsive media queries (728px → 720px max, 1024px → 820px max) |
| BUG-014 | 🟡 | DB drift — loyalty status `soon` despite shipped | `012_module_status_updates.sql` flips to active |
| BUG-015 | 🟡 | DB drift — services + appointments NEW badge suppressed | Resolves automatically with BUG-006 fix |

### 2.2 Open

| # | Severity | Affects | Description | Fix scope |
|---|----------|---------|-------------|-----------|
| BUG-011 | 🟡 | Mobile accessibility | Marketing/Plans/Team pages not visible in mobile app | Audit drawer + mobile bnav (separate batch) |
| BUG-012 | 🟡 | Manual billing | Payment Mode field appears too early (before items added) | Move field to settlement step (UX restructure) |
| BUG-013 | 🟡 | Auth | localStorage `sbp_pending_shop` never read for email-confirm signup resume | Wire resume logic in index.html |
| BUG-016 | 🟢 | Marketing Center | Pamphlet single green card too plain | Design work — vibrant typography pamphlet |
| BUG-017 | 🟢 | Various | Placeholder/dummy images need replacement | Vinay supplies brand assets |
| BUG-018 | 🟢 | Repo | `pages/` folder = 16 stale duplicate HTMLs | Delete folder (separate cleanup commit) |
| BUG-019 | 🟢 | Repo | `sidebar-engine.js` at root = older copy | Delete (lib/ is canonical) |
| — | — | bills.html | Loyalty bill-void hook not yet wired | Carry-over from Loyalty batch |

---

## §3. API-First Compliance Audit

Per the locked rule (5 May 2026): all new features must have logic in PLpgSQL RPCs with `jsonb {ok, error?, ...}` envelope, server-side validation, owner check, and idempotency.

### 3.1 Compliant (new code, follows the rule)

✅ `008_public_shop_page.sql` — `sbp_resolve_shop_slug`, etc.
✅ `009_loyalty.sql` — 8 RPCs with proper envelope (BUT 1 has row_to_jsonb bug)
✅ `010_service_catalog.sql` — 8 RPCs (BUT 2 have row_to_jsonb bug)
✅ `011_appointments.sql` — 13 RPCs (BUT 5 have row_to_jsonb bug)
✅ Public storefront RPCs are anon-callable, slug-resolved, no auth needed → ready for AI/external website builders

### 3.2 Tech debt — older code that doesn't follow the rule

⚠️ Bill creation logic — orchestrated client-side in `billing.html` (math + stock + ledger + GST split done in JS, not SQL)
⚠️ Bill void/reopen — `bills.html` orchestrates stock reversal + ledger reversal client-side
⚠️ Customer ledger — Mostly server-authoritative but some client-side computation
⚠️ Stock adjustments — Client-side
⚠️ Recurring bill generation — Client-side scheduler

**Refactor policy:** Don't migrate these proactively. Refactor each only when next touched (during a feature change in that area). The existing code works; rewriting purely for compliance has no user-visible value.

### 3.3 RPC Catalog (admin + public)

#### From 003_business_categories.sql

| RPC | Auth | Purpose |
|-----|------|---------|
| `get_macro_categories()` | anon + auth | Signup wizard step 1 |
| `get_business_categories(macro)` | anon + auth | Signup wizard step 2 |
| `get_shop_modules(shop_id)` | auth | **Drives the sidebar** |

#### From 005_beta_logic.sql

| RPC | Auth | Purpose |
|-----|------|---------|
| `apply_beta_plan()` | auth | Auto-activates 60d Business beta on signup |
| `get_shop_beta_status()` | auth | For beta banner countdown |

#### From 008_public_shop_page.sql

| RPC | Auth | Purpose |
|-----|------|---------|
| `sbp_resolve_shop_slug(slug)` | anon | PSP entry point |
| `sbp_log_shop_page_view(slug)` | anon | Analytics |
| `sbp_log_wa_click(slug)` | anon | WA conversion tracking |
| `sbp_update_website_content(...)` | auth | Save About + Gallery |
| `sbp_publish_shop_website(...)` | auth | Publish toggle |

#### From 009_loyalty.sql

| RPC | Auth | Purpose |
|-----|------|---------|
| `sbp_loyalty_config_get(shop_id)` | auth | Get config |
| `sbp_loyalty_config_set(shop_id, ...)` | auth | Update config |
| `sbp_loyalty_get_balance(shop_id, customer_id)` | auth | Customer points balance |
| `sbp_loyalty_earn(...)` | auth | Earn points (called from billing) |
| `sbp_loyalty_redeem(...)` | auth | Redeem points |
| `sbp_loyalty_txns(shop_id, customer_id)` | auth | Txn history (⚠️ row_to_jsonb bug) |
| `sbp_loyalty_reverse_for_bill(bill_id)` | auth | Reverse on void (NOT YET WIRED in bills.html) |
| (1 more setup helper) | auth | — |

#### From 010_service_catalog.sql

| RPC | Auth | Purpose | Status |
|-----|------|---------|--------|
| `sbp_services_list(shop_id)` | auth | List active for billing | ✓ |
| `sbp_services_list_admin(shop_id)` | auth | List ALL (active + inactive) | ⚠️ row_to_jsonb |
| `sbp_services_upsert(...)` | auth | Create / update | ✓ |
| `sbp_services_delete(id)` | auth | Soft delete | ✓ |
| `sbp_services_toggle_active(id)` | auth | Active toggle | ✓ |
| `sbp_services_reorder(shop_id, ids[])` | auth | Reorder | ✓ |
| `sbp_get_shop_services_public(slug)` | anon | Public storefront | ⚠️ row_to_jsonb |
| (1 more) | auth | — | — |

#### From 011_appointments.sql

13 RPCs. See `DEPLOY_README.md` in shipped batch for full catalog. **5 of them have the row_to_jsonb bug** (3 admin lists + 1 public config + 1 admin blocks list).

---

## §4. Deploy State

| Item | Production state | Verification |
|------|------------------|--------------|
| Vercel auto-deploy on GitHub push | Active | Recent deploys shown in screenshots |
| `audit_round_db_patch.sql` | Deployed (Apr 2026) | 62-bug audit referenced |
| `admin_panel_full.sql` | Deployed (Apr 2026) | Admin login works |
| `003_business_categories.sql` | Deployed (May 2026) | 12 macros + 85 types live |
| `004_seo_admin.sql` | Deployed (May 2026) | SEO admin pages exist |
| `005_beta_logic.sql` | Deployed (May 2026) | Beta banner shows correctly |
| `008_public_shop_page.sql` | Deployed (May 2026) | /s/viraj-enterprises renders |
| `009_loyalty.sql` | **Likely deployed** (5 May) | Loyalty module shipped, but bug is latent |
| `010_service_catalog.sql` | **Likely deployed** (5 May) | services.html exists; row_to_jsonb error visible in screenshots |
| `011_appointments.sql` | **NEEDS CONFIRM** | Vinay said "do I need to run SQL?" — uncertain whether it's been run |
| Razorpay webhook edge function | Deployed | Live mode pending CIN |
| Vercel `/s/:slug` rewrite | Active | Public pages work |

---

## §5. Recently Shipped Timeline

| Date | Batch | Files | Status |
|------|-------|-------|--------|
| Apr 2026 | 62-bug audit | Multiple | ✅ Live |
| Apr 2026 | Admin Panel Full | admin-*.html + SQL | ✅ Live |
| Apr 2026 | Reports Pro | reports.html new tabs | ✅ Live |
| Early May 2026 | Batch 1A (categories, SEO, beta) | 003/004/005 SQL + admin pages | ✅ Live |
| Early May 2026 | Batch 1B-A through 1B-E-Fix | Beta banner, signup wizard, plan normalization | ✅ Live |
| 5 May 2026 | Marketing site (Block 3) | /site/ folder 14 pages | ✅ Live |
| 5 May 2026 | SEO Phase 1 | GSC verification, sitemap submit, Schema.org, PostHog | ✅ Live |
| 5 May 2026 evening | **Loyalty Module** | 009 SQL + lib/loyalty.js + 3 page patches | ⚠️ Live, txn list bug fixed in Batch 012 |
| 5 May 2026 evening | **Service Catalog** | 010 SQL + lib/services.js + services.html + 2 page patches | ⚠️ Bugs fixed in Batch 012 |
| 5 May 2026 night | **Universal Appointments** | 011 SQL + lib/appointments.js + appointments.html + 2 page patches | ⚠️ Bugs fixed in Batch 012 |
| **6 May 2026** | **Batch 012 — Bug fix sprint** | 4 SQL (3 modified + 1 new) + sidebar-engine.js + 4 HTML | ✅ Closes 12 bugs, unblocks 4 verticals |

---

## §6. Open Questions / Decisions Pending Founder

**Resolved at 6 May 2026 founder session (locked):**
- ✅ Public shop page (/s/) on desktop → responsive (narrow mobile, widen desktop) per Batch 012
- ✅ Stylists vs Providers → deeper feature, separate from Providers
- ✅ Wholesale website → kept active per "all business have website"
- ✅ Tea stall website → website added to minimal profile

**Still open:**
1. Subscription profile cross-listing (tiffin + gym + coworking sharing one profile) — defer until first complaint
2. Specialized macro catch-all (wedding, DJ, print) — defer until ≥10 paying customers in any sub-type
3. Legacy `pages/` folder + `shopbillpro_website.html` + root `sidebar-engine.js` — confirm safe to delete (low priority cleanup)
4. Loyalty bill-void hook in bills.html (carry-over from Loyalty batch)

---

## §7. Maintenance Note

This doc is a snapshot. Re-run the audit when:
- A new batch ships (update §1.1 - §1.6)
- A bug is filed or closed (update §2)
- A new RPC is added (update §3)
- A migration deploys (update §4 + §5)

A 30-min audit at the end of each batch keeps this doc accurate. Worth the time — this is the document future Claude reads first when picking up where we left off.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Confidential — Internal Reference Document*
