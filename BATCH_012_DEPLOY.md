# ShopBill Pro — Batch 012 Bug Fix Sprint

**Sprint:** Batch 012 (6 May 2026)
**Risk level:** Low — all fixes additive or surgical
**Time to deploy:** ~10 min (SQL) + ~30 sec (Vercel auto-deploy after Git push)
**Effect:** Unblocks 4 verticals (salon, healthcare, education, services) from broken to ~95% complete + closes 8 bugs

---

## Files in this batch (10 files)

| File | Action | Purpose |
|------|--------|---------|
| `db/migrations/009_loyalty.sql` | MODIFIED (1 line) | row_to_jsonb → to_jsonb |
| `db/migrations/010_service_catalog.sql` | MODIFIED (2 lines) | row_to_jsonb → to_jsonb |
| `db/migrations/011_appointments.sql` | MODIFIED (5 lines) | row_to_jsonb → to_jsonb |
| `db/migrations/012_module_status_updates.sql` | NEW | Loyalty status flip + website-everywhere |
| `lib/sidebar-engine.js` | MODIFIED | Remove services + appointments from PENDING_PAGES; add loyalty href |
| `services.html` | MODIFIED | Add SBPSidebar.render() — fixes missing sidebar + bilingual concat |
| `appointments.html` | MODIFIED | Add SBPSidebar.render() — same fixes |
| `settings.html` | MODIFIED | Remove orphan modal at top + URL validation in Website Content |
| `s.html` | MODIFIED | Responsive desktop layout + auto-hide gallery card if all images fail |
| `BATCH_012_DEPLOY.md` | NEW (this file) | Deploy guide |

---

## Deploy steps

### Step 1 — SQL in Supabase SQL Editor (in this order)

The 3 existing migrations are idempotent (`CREATE OR REPLACE FUNCTION`). Re-running overwrites the broken functions with the fixed versions.

```
1. Run 009_loyalty.sql
2. Run 010_service_catalog.sql
3. Run 011_appointments.sql       ← if not yet run, this is its first deploy
4. Run 012_module_status_updates.sql  ← NEW
```

Each completes in <2 seconds. No data migration, no destructive changes.

### Step 2 — Verification queries

Paste these into Supabase SQL Editor after Step 1:

```sql
-- (1) row_to_jsonb bug eliminated everywhere — search for residue
SELECT pg_get_functiondef(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'sbp_loyalty_txns',
    'sbp_services_list_admin',
    'sbp_get_shop_services_public',
    'sbp_appt_providers_list',
    'sbp_appt_blocks_list',
    'sbp_appointments_list',
    'sbp_get_appointment_config_public'
  )
  AND pg_get_functiondef(p.oid) LIKE '%row_to_jsonb%';
-- Expected: 0 rows (none of these functions should still use row_to_jsonb)

-- (2) Loyalty active across retail-leaning profiles
SELECT profile, status, badge FROM sbp_module_profiles
WHERE module_code = 'loyalty' ORDER BY profile;
-- Expected: 13 rows, all status='active', badge='NEW'

-- (3) Website module on every profile (locked decision 3)
SELECT profile, status, badge FROM sbp_module_profiles
WHERE module_code = 'website' ORDER BY profile;
-- Expected: 19 rows (one per profile), all status='active', badge='BIZ'

-- (4) Live smoke test: each public RPC returns ok=true
SELECT sbp_get_appointment_config_public('viraj-enterprises');  -- {ok:true, enabled:false} unless providers added
SELECT sbp_get_shop_services_public('viraj-enterprises');       -- {ok:true, services:[...]}
```

### Step 3 — Push files to GitHub

Push the 6 modified code files + 1 new SQL + 1 new doc to the PWA repo (root of `tradecresttechnologies-pixel-shopbillpro` on Vercel):

```
db/migrations/012_module_status_updates.sql  (new)
lib/sidebar-engine.js                         (modified)
services.html                                 (modified)
appointments.html                             (modified)
settings.html                                 (modified)
s.html                                        (modified)
BATCH_012_DEPLOY.md                           (new)
```

(The 3 modified SQL migrations don't need to push to repo — they were already in the repo, just needed to be re-run in Supabase. But you can update the repo copies for accurate version-control history.)

Vercel auto-deploys ~30 sec after push.

---

## Smoke test checklist (post-deploy)

### Critical path — Service Catalog & Appointments (BUG-001, BUG-002, BUG-004, BUG-005)

- [ ] Login → Settings → ✨ Service Catalog opens (no error toast)
- [ ] Stats show real numbers (not "Could not load")
- [ ] Bilingual labels show ONE language only — not "Totalकुल"
- [ ] **Left sidebar visible** on services.html (was missing entirely before)
- [ ] Add a service → it appears in the list (was failing silently before)
- [ ] Settings → 📅 Appointments opens
- [ ] All 3 tabs (Bookings / Providers / Blocks) load without error
- [ ] **Left sidebar visible** on appointments.html

### Sidebar nav (BUG-006)

- [ ] On dashboard, sidebar shows "Services NEW" + "Appointments NEW" badges
- [ ] Click "Services" — navigates to services.html (NOT a "Coming Soon" toast)
- [ ] Click "Appointments" — navigates to appointments.html
- [ ] Sidebar shows "Loyalty NEW" badge for retail-profile shops (kirana, garments, etc.)

### Public booking flow (also BUG-002)

- [ ] Open `/s/[your-slug]` in incognito (assuming Business plan + ≥1 active provider)
- [ ] "📅 Book Appointment" CTA visible
- [ ] Walk through Service → Provider → Date → Time → Customer → Confirm
- [ ] Booking lands in admin Appointments page

### Loyalty (BUG-003, BUG-014)

- [ ] Open a customer with loyalty txns → history loads (was failing silently before)
- [ ] Sidebar shows Loyalty active for retail profiles (was 'soon' / hidden)

### settings.html structure (BUG-007)

- [ ] Browser dev tools — no quirks-mode warning
- [ ] All settings sections render normally (no displaced sync modal at top)
- [ ] Page source line 1 is `<!DOCTYPE html>` (not orphan modal)

### Responsive PSP (BUG-010, locked decision 1)

- [ ] Open `/s/[slug]` on a phone — narrow Instagram-bio layout, looks good
- [ ] Open same URL on a laptop browser — page widens to ~820px max, gallery flows to 4 columns, more breathing room
- [ ] Resize browser between mobile/tablet/desktop widths — layout adapts smoothly

### Gallery card (BUG-008)

- [ ] Public shop with broken/placeholder gallery URLs — gallery card doesn't show (was empty box before)
- [ ] Public shop with at least 1 valid image URL — gallery card shows with that image

### Website Content modal (BUG-009)

- [ ] Settings → Website Content → Gallery URLs field
- [ ] Try to save with `https://yourlink.com/photo1.jpg` — gets confirmation warning "These look like placeholder URLs..."
- [ ] Try to save with `https://example.com/photo.html` — gets warning about non-image URLs
- [ ] Real image URL like `https://i.imgur.com/abc.jpg` saves without warning

### Website everywhere (locked decision 3)

- [ ] Sidebar of a tea-stall / pan-shop shop (minimal profile) NOW shows "Website" item (was hidden)
- [ ] Wholesale-profile shop sidebar still shows "Website" (verify still active)

---

## Rollback plan

If anything breaks after deploy:

| Fix | Rollback approach |
|-----|-------------------|
| SQL migrations | Re-run previous version (CREATE OR REPLACE overwrites) |
| `lib/sidebar-engine.js` | `git revert <commit>` and push |
| HTML files | `git revert <commit>` and push |
| 012 module status | Run `UPDATE sbp_module_profiles SET status='soon' WHERE module_code='loyalty'` to revert; or `DELETE FROM sbp_module_profiles WHERE profile='minimal' AND module_code='website'` |

Vercel keeps deploys for 7 days. Roll back via dashboard if needed.

No data is created, modified, or destroyed. Pure config + bugfix batch. Rollback risk minimal.

---

## API-first compliance

All fixes maintain the locked rule:

✅ Logic stays in PLpgSQL RPCs (just with corrected `to_jsonb` instead of broken `row_to_jsonb`)
✅ jsonb {ok, error?, ...} envelope unchanged — return shapes identical
✅ No new client-side orchestration
✅ Server-side ownership + plan checks unchanged
✅ Public RPCs (anon-callable) continue to work — same signatures

---

## What this batch does NOT fix (deferred)

These are open in the bug register (`CURRENT_STATE_AUDIT.md §2`) but out of scope for Batch 012:

- BUG-011: Mobile accessibility for Marketing/Plans/Team pages (broader drawer audit needed)
- BUG-012: Manual billing payment-mode field timing (UX restructure)
- BUG-016: Marketing pamphlet redesign (design work)
- BUG-017: Placeholder/dummy images (waiting on Vinay's brand assets)
- Loyalty bill-void hook (carry-over from Loyalty batch — needs bills.html change)
- Stylists module deeper feature (separate ~6-8 hr session)

Pick these up in a future batch when ready.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Batch 012 (6 May 2026)*
