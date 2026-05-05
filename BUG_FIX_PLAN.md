# ShopBill Pro — Bug Fix Plan v1.1 (COMPLETED)

**Sprint:** Batch 012 — Bug fix sprint
**Status:** ✅ **COMPLETED 6 May 2026** — see `BATCH_012_DEPLOY.md` for the actual deploy guide
**Outcome:** 12 bugs closed, 4 verticals unblocked from broken to ~95% complete

This document was the pre-execution plan. After Batch 012 shipped, the closed-bug record moved to `CURRENT_STATE_AUDIT.md §2.1`.

Kept here for reference / audit trail of the planning approach.

---

## Original Sprint Goals (achieved)

By end of this batch:
- Service Catalog list works (admin + public)
- Appointments admin tabs work (Bookings + Providers + Blocks)
- Public booking flow on `/s/[slug]` works end-to-end
- Loyalty txn history works
- Sidebar appears correctly on services.html + appointments.html
- Bilingual text renders correctly (one language at a time)
- Sidebar items "Services" + "Appointments" navigate properly (no Coming Soon toast)
- DB drift on loyalty profile resolved
- settings.html structural bug fixed

**Not in scope** (deferred to future batches):
- Mobile accessibility for Marketing/Plans/Team pages (BUG-011)
- Manual billing payment-mode field repositioning (BUG-012)
- Public shop page desktop layout decision (BUG-010)
- Marketing pamphlet redesign (BUG-016)
- Loyalty bill-void hook (carry-over from Loyalty batch)

---

## §2. Fix Order (priority + dependencies)

| Order | Fix | Severity | File(s) | Approx LOC change |
|-------|-----|----------|---------|-------------------|
| 1 | row_to_jsonb → to_jsonb (009/010/011) | 🔴 | 3 SQL migrations | 8 lines |
| 2 | Remove services + appointments from PENDING_PAGES | 🟠 | lib/sidebar-engine.js | 2 lines |
| 3 | Add SBPSidebar.render() to services.html + appointments.html | 🟠 | 2 HTML files | ~15 lines per file |
| 4 | Fix settings.html orphan modal | 🟠 | settings.html | Restructure (move modal to bottom) |
| 5 | Hide gallery card when 0 images load (PSP) | 🟡 | s.html | ~8 lines |
| 6 | Loyalty status flip in 003 seed | 🟡 | 003_business_categories.sql | 2 lines + new migration option |
| 7 | Website Content modal placeholder fix | 🟢 | settings.html | ~5 lines |
| 8 | Cleanup stale files | 🟢 | delete `pages/`, root sidebar-engine.js, etc. | — |

---

## §3. Detailed Fixes (with exact diffs)

### 3.1 Fix #1 — row_to_jsonb everywhere

**Pattern:** Postgres treats subquery aliases as `record` type, and `row_to_jsonb` doesn't have a `record` overload in some Postgres builds. `to_jsonb` does. Functionally equivalent for our use case.

**Files affected:** 3 migration files, 8 instances total.

#### 3.1.1 `009_loyalty.sql` line 584

```diff
-  SELECT COALESCE(jsonb_agg(row_to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
+  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
```

#### 3.1.2 `010_service_catalog.sql` lines 276 + 326

```diff
-  SELECT COALESCE(jsonb_agg(row_to_jsonb(s) ORDER BY s.display_order, s.created_at), '[]'::jsonb)
+  SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.display_order, s.created_at), '[]'::jsonb)
```
```diff
-  SELECT COALESCE(jsonb_agg(row_to_jsonb(s) ORDER BY s.display_order), '[]'::jsonb)
+  SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.display_order), '[]'::jsonb)
```

#### 3.1.3 `011_appointments.sql` lines 215, 442, 476, 708, 720

5 identical patterns, all `row_to_jsonb(<alias>)` → `to_jsonb(<alias>)`.

**Deploy:** Re-run all 3 migrations in Supabase SQL Editor (idempotent — `CREATE OR REPLACE FUNCTION` overwrites).

**Verification:**
```sql
-- After deploy, test each:
SELECT sbp_services_list_admin('<your-shop-id>');           -- should return {ok:true, services:[...]}
SELECT sbp_appt_providers_list('<your-shop-id>');           -- ditto
SELECT sbp_get_appointment_config_public('viraj-enterprises'); -- ditto
SELECT sbp_loyalty_txns('<your-shop-id>', '<customer-id>'); -- ditto
```

---

### 3.2 Fix #2 — Remove services + appointments from PENDING_PAGES

**File:** `lib/sidebar-engine.js` lines 151-156

**Current:**
```javascript
const PENDING_PAGES = new Set([
  'services',          // services.html — Phase 5a placeholder
  'appointments',      // appointments.html — Phase 5a placeholder
  'stylists',          // stylists.html — already 'soon' in catalog
  'customer_history',  // customer-history.html — already 'soon' in catalog
]);
```

**Change to:**
```javascript
const PENDING_PAGES = new Set([
  // 'services',       — built and shipped 5 May 2026
  // 'appointments',   — built and shipped 5 May 2026
  'stylists',          // stylists.html — placeholder
  'customer_history',  // customer-history.html — placeholder
]);
```

**Effect:** Sidebar items for Services + Appointments will navigate to their pages instead of showing "Coming Soon" toast. The `'NEW'` badge from `sbp_module_profiles` will also start rendering correctly (was being suppressed by the soon override).

---

### 3.3 Fix #3 — Add SBPSidebar.render() to services.html + appointments.html

**Why this fixes 2 bugs at once:** `SBPSidebar.render()` does two things:
1. Renders the desktop sidebar (`#dsb` element)
2. Calls `_injectStyles()` which injects the CSS rules `.lang-hi { display: none }` etc.

If render() is never called, the sidebar is missing AND both `lang-en` + `lang-hi` spans render concatenated.

#### 3.3.1 services.html

**Find** the closing `</script>` of the page's main IIFE / init block. Add this just before it:

```html
<!-- Sidebar engine init (desktop side rail + mobile bnav-aware) -->
<script>
  // Desktop: full side rail
  if (window.SBPSidebar) {
    SBPSidebar.render({ currentPage: 'services', layout: 'desktop' });
    // Also init mobile drawer (used when "More" tapped on mobile bnav)
    SBPSidebar.render({ currentPage: 'services', layout: 'mobile-drawer', container: '.bnav-drawer' });
  }
</script>
```

Plus ensure the page has the necessary DOM anchors:
```html
<!-- Mobile bottom nav structure -->
<div class="bnav"></div>
<div class="bnav-overlay"></div>
<div class="bnav-drawer"></div>
```

(These already exist in services.html — just verify before adding.)

#### 3.3.2 appointments.html

Same pattern. The DOM anchors are already in the file (verified). Just need to add the render call.

```html
<script>
  if (window.SBPSidebar) {
    SBPSidebar.render({ currentPage: 'appointments', layout: 'desktop' });
    SBPSidebar.render({ currentPage: 'appointments', layout: 'mobile-drawer', container: '.bnav-drawer' });
  }
</script>
```

**Verification:** Reload either page on desktop — left sidebar should appear. Reload on mobile + tap "More" — drawer should slide in. Bilingual text should show only one language (English by default, Hindi if `localStorage.sbp_lang === 'hi'`).

---

### 3.4 Fix #4 — settings.html orphan modal

**Issue:** First 24 lines of `settings.html` are an orphan `<div class="overlay" id="sync-modal">` modal fragment, BEFORE the `<!DOCTYPE html>` on line 25. Browser renders in quirks mode.

**Fix approach:**
1. Identify the orphan modal block (lines 1-24)
2. Move it to before `</body>` (where modals belong)
3. Verify the file starts with `<!DOCTYPE html>` cleanly

**Risk:** None — this is a structural cleanup. The modal's behavior should be unchanged once it's in the right place.

**Verification:** First line of settings.html should be `<!DOCTYPE html>`. Page should load in standards mode (no quirks-mode warnings in browser dev tools).

---

### 3.5 Fix #5 — Hide gallery card on PSP when no images

**File:** `s.html` `renderShop()` function

**Current behavior:** Gallery card renders if `gallery.length > 0`, but if all 6 image URLs return 404, the individual `<img>` tags hide via `onerror` while the parent card stays visible — empty.

**Fix:** Track successful loads. If 0 succeed, hide the parent card entirely.

**Approach (JS):**
```javascript
// In renderShop, after gallery card mounts:
const galleryCard = document.querySelector('#psp-gallery-card');
if (galleryCard) {
  const imgs = galleryCard.querySelectorAll('img');
  let loadedCount = 0;
  let pendingCount = imgs.length;
  imgs.forEach(img => {
    if (img.complete && img.naturalHeight > 0) loadedCount++;
    else {
      img.addEventListener('load', () => { loadedCount++; });
      img.addEventListener('error', () => {
        pendingCount--;
        if (pendingCount === 0 && loadedCount === 0) {
          galleryCard.style.display = 'none';
        }
      });
    }
  });
}
```

Add `id="psp-gallery-card"` to the gallery card render so the JS can find it.

---

### 3.6 Fix #6 — Loyalty status flip in 003

**Issue:** Loyalty module shipped 5 May 2026 but `sbp_module_profiles` still has `('kirana', 'loyalty', 'soon', 'SOON', 100)`. Sidebar shows "Loyalty SOON" instead of treating it as live.

**Fix:** Add an UPDATE statement at the END of `003_business_categories.sql`, OR create a new short migration `012_loyalty_active.sql` that runs after.

**Recommended:** New short migration (cleaner — keeps 003 idempotent without re-running everything).

```sql
-- ════════════════════════════════════════════════════════════════
-- 012_loyalty_status_flip.sql
-- Loyalty module shipped 5 May 2026 — flip from 'soon' to 'active'
-- in profiles where it's listed.
-- ════════════════════════════════════════════════════════════════

UPDATE sbp_module_profiles
SET status = 'active', badge = 'NEW'
WHERE module_code = 'loyalty';

-- Optionally add loyalty to other retail profiles where it should appear:
INSERT INTO sbp_module_profiles (profile, module_code, status, badge, display_order) VALUES
  ('standard',  'loyalty', 'active', 'NEW', 75),
  ('garments',  'loyalty', 'active', 'NEW', 75),
  ('jewellery', 'loyalty', 'active', 'NEW', 75),
  ('mobile',    'loyalty', 'active', 'NEW', 75),
  ('pharmacy',  'loyalty', 'active', 'NEW', 75),
  ('food',      'loyalty', 'active', 'NEW', 75),
  ('restaurant','loyalty', 'active', 'NEW', 75)
ON CONFLICT (profile, module_code) DO UPDATE SET
  status = EXCLUDED.status,
  badge = EXCLUDED.badge,
  display_order = EXCLUDED.display_order;
```

Also need to add `'loyalty'` to the `MODULE_CATALOG` in `lib/sidebar-engine.js` IF it isn't there yet — verify on read.

(Already there at line 90 with icon ⭐ and label "Loyalty".)

---

### 3.7 Fix #7 — Website Content modal placeholder fix

**File:** `settings.html` Website Content modal

**Current issue:** Textarea is pre-filled with example URLs ("https://yourlink.com/salon-interior.jpg"). User copy-pastes this thinking it's instruction, gallery breaks.

**Fix:**
- Remove pre-filled value
- Use HTML `placeholder=` attribute (greyed-out hint)
- Add a visual hint above the textarea: "Example: https://imgur.com/abc.jpg — one URL per line"
- Optional: validate URLs look like image URLs on save (`.jpg`, `.png`, `.webp`, `.gif`) — show warning if not

**Diff:**
```html
<!-- BEFORE -->
<textarea ...>https://yourlink.com/salon-interior.jpg
https://yourlink.com/haircut-service.jpg</textarea>

<!-- AFTER -->
<div style="font-size:11px;color:var(--t2);margin-bottom:6px">
  💡 Example: <code>https://imgur.com/abc123.jpg</code> — one URL per line
</div>
<textarea
  placeholder="https://yourlink.com/photo1.jpg
https://yourlink.com/photo2.jpg"
  ...></textarea>
```

---

### 3.8 Fix #8 — Cleanup stale files

**Delete:**
- `pages/` folder (16 stale HTML files)
- `sidebar-engine.js` at root (older copy — `lib/sidebar-engine.js` is active)
- `shopbillpro_website.html` (old marketing template, not referenced)
- `service-worker.js` at root (0 bytes — broken, replaced by `sw.js`)

**Caveat:** Verify nothing in any HTML file references these paths first. Quick grep before delete.

---

## §4. Deploy Plan

### 4.1 Order of operations (single batch — Batch 012)

1. **SQL fixes first** — Re-run 009, 010, 011 in Supabase SQL Editor (in that order)
2. **Run 012_loyalty_status_flip.sql** — flip loyalty status across profiles
3. **Push code changes via Git:**
   - `lib/sidebar-engine.js` (PENDING_PAGES update)
   - `services.html` (sidebar render call)
   - `appointments.html` (sidebar render call)
   - `settings.html` (orphan modal restructure + Website Content placeholder fix)
   - `s.html` (gallery card visibility fix)
4. **Vercel auto-deploys** ~30 sec after push
5. **Smoke test** (see §5 below)
6. **Delete stale files** (separate small commit, low-risk)

### 4.2 Risk assessment

| Fix | Risk | Mitigation |
|-----|------|------------|
| row_to_jsonb → to_jsonb | Low — equivalent function | Idempotent migrations; `CREATE OR REPLACE` |
| PENDING_PAGES removal | Low — feature flag flip | If issues, easy 1-line revert |
| sidebar render() addition | Low — additive | Sidebar can fail silently without breaking page |
| settings.html restructure | Medium — large file change | Diff carefully; test all settings sections still work |
| Gallery card hide | Low — JS additive | Worst case: card stays visible (current behavior) |
| Loyalty status flip | Low — DB rows only | Easy to revert |
| Website Content placeholder | Low — HTML attribute change | None |
| Stale file deletion | Medium — could break unknown reference | Grep first; commit separately so easy to revert |

---

## §5. Smoke Test Checklist

After deploy, run through these manually:

### 5.1 Service Catalog (was BUG-001)

- [ ] Login → Settings → ✨ Service Catalog opens
- [ ] Stats show "0 Total / 0 Active / 0 Categories" (not error toast)
- [ ] Tap "+ Add Service" → modal opens
- [ ] Fill in: Name "Haircut", Price 300, Duration 30 min → Save
- [ ] Service appears in list (not just success toast)
- [ ] Stats update: "1 Total / 1 Active"
- [ ] Bilingual text shows ONE language only (no "Totalकुल")
- [ ] Sidebar visible on left (desktop)

### 5.2 Appointments (was BUG-002)

- [ ] Login → Settings → 📅 Appointments opens
- [ ] No "Could not load" error
- [ ] Bookings tab loads (empty state OK)
- [ ] Providers tab loads
- [ ] Blocks tab loads (after picking provider)
- [ ] Add Provider → save → appears in Providers tab
- [ ] Manual booking via + FAB works

### 5.3 Public booking flow (was BUG-002)

- [ ] Open `/s/[your-slug]` in incognito
- [ ] "📅 Book Appointment" CTA visible (assuming ≥1 active provider)
- [ ] Tap → modal opens
- [ ] Walk through Service → Provider → Date → Time → Customer → Confirm
- [ ] Booking lands in admin Appointments page with `🌐 Online` source

### 5.4 Sidebar nav (was BUG-006)

- [ ] On dashboard.html, sidebar shows "Services NEW" + "Appointments NEW"
- [ ] Click "Services" — navigates to services.html (does NOT show "Coming Soon" toast)
- [ ] Click "Appointments" — navigates to appointments.html

### 5.5 Loyalty (was BUG-003)

- [ ] Customer detail view → Loyalty section
- [ ] Past txns list loads (was failing silently before)
- [ ] Sidebar in retail-profile shop: Loyalty appears with "NEW" badge instead of "SOON"

### 5.6 Settings.html structural fix (was BUG-007)

- [ ] Browser dev tools → Console: no "quirks mode" warning
- [ ] All settings sections render correctly (no displaced sync modal at top)

### 5.7 Gallery card on PSP (was BUG-008)

- [ ] Public shop with broken gallery URLs: no empty Gallery card visible
- [ ] Public shop with 1+ valid image: card shows with images

---

## §6. Rollback Plan

If anything goes wrong post-deploy:

1. **SQL issues:** Re-running idempotent migrations is safe. Worst case, run `DROP FUNCTION x; CREATE OR REPLACE FUNCTION x ...` from previous version.
2. **JS issues:** Revert the relevant file via Git, push.
3. **Vercel rollback:** Use Vercel dashboard to roll back to previous deploy if needed.

No data migrations or destructive changes in this batch — purely additive/corrective. Rollback risk is minimal.

---

## §7. Files in Final Zip

| File | Action |
|------|--------|
| `db/migrations/009_loyalty.sql` | Modified (1 line) |
| `db/migrations/010_service_catalog.sql` | Modified (2 lines) |
| `db/migrations/011_appointments.sql` | Modified (5 lines) |
| `db/migrations/012_loyalty_status_flip.sql` | NEW |
| `lib/sidebar-engine.js` | Modified (PENDING_PAGES) |
| `services.html` | Modified (sidebar render) |
| `appointments.html` | Modified (sidebar render) |
| `settings.html` | Modified (orphan modal fix + placeholder fix) |
| `s.html` | Modified (gallery hide) |
| `BATCH_012_DEPLOY.md` | NEW (deploy guide) |

Plus: a separate cleanup commit deleting `pages/`, `sidebar-engine.js` (root), `shopbillpro_website.html`, `service-worker.js` (zero bytes).

---

## §8. Time Estimate

- SQL fixes: 10 minutes
- sidebar-engine.js PENDING_PAGES: 2 minutes
- 2× sidebar render() additions: 10 minutes
- settings.html orphan modal: 20 minutes (need to identify the right location for the modal)
- s.html gallery hide: 10 minutes
- 012 migration: 5 minutes
- Website Content placeholder: 5 minutes
- Smoke test pass: 15 minutes
- Deploy README write: 10 minutes
- Stale file cleanup + grep verify: 15 minutes

**Total: ~100 minutes (~1.5-2 hours)** for a focused batch.

---

## §9. Decision Required Before I Start

1. **Cleanup stale files in this batch, or separate?**
   - In this batch: cleaner, but more diff
   - Separate: safer, easier to revert if cleanup breaks something

2. **Public shop page (`/s/`) desktop layout (BUG-010) — fix in this batch or defer?**
   - Currently: mobile-narrow column on desktop with big black bands
   - Option A: Keep mobile-feel intentional (Instagram-bio style) — defer
   - Option B: Widen for desktop (centered card up to 720-820px max-width with proportional padding) — small change, can include
   - Option C: Full desktop layout (sidebar nav, hero banner, multi-column) — Phase 5a scope

3. **Mobile accessibility for Marketing/Plans/Team (BUG-011) — fix in this batch or defer?**
   - This is broader scope (drawer routing audit). Recommend defer to next batch.

Pick answers and I execute.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Confidential — Internal Reference Document*
