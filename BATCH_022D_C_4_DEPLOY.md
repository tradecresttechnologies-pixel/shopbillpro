# Batch 022D-C Stage 4 — team.html simplification (Option A)

Replaces the 022D-C-3 version with a cleaner, simpler team.html that
removes the now-redundant legacy PIN UI. Same file path. Drop-in
replacement.

**Why:** The screenshot review showed the page had too many overlapping
concepts — login accounts, manager PINs, activity log, invitations —
with stale "Multi-device note" (lying about cloud sync) and a confusing
"Owner PIN not set" warning even when the user had no need for a
legacy PIN. After 022D-A through C-3, the PIN authorization story
lives at `authorized-users.html`. team.html should be about LOGIN
ACCOUNTS, not PINs.

---

## What's removed

- **"🔐 Manager PINs" card** (whole section) — was a localStorage-based
  UI for setting per-user PINs. Cloud PINs (sbp_authorized_users) now
  do this properly with bcrypt hashing and audit trails.
- **"Multi-device note" info banner** — stated "PINs are stored on each
  device, cloud sync coming next update". That update IS 022D. The
  note was false post-deploy.
- **"⚠ Owner PIN not set"** warning — only made sense for the legacy
  localStorage system that just got retired.
- **"Set PIN" modal** + the 4 JS functions backing it (`renderPinSection`,
  `openSetPin`, `saveStaffPin`, `toggleStaffPinActive`). Dead code,
  all deleted.

## What's added

- **🔒 PIN Authorization card** — single info paragraph + two link tiles:
  - **👥 Authorized Users** → `authorized-users.html`
  - **📋 Audit Log** → `audit-log.html`
- **"See full audit log →"** small link below the Staff Activity Log
  section, also pointing at `audit-log.html`.

## What's preserved (intentionally)

- **Current Team section** — login accounts (sbp.shop_users table)
- **Invite Team Member form** — unchanged
- **Staff Activity Log card** — the local cached audit. Stays because
  it's been the de-facto place to see "what happened" historically.
  The link at the bottom funnels users to the richer cloud audit log
  when they need more detail.
- **Migration banner (☁️ Migrate PINs to cloud)** — from 022D-C-3. Still
  appears at the top of the PIN Authorization card if and only if
  there are legacy PINs in localStorage waiting to migrate. Once
  migrated, it auto-hides; the card becomes just the clean two-tile
  link grid.

---

## Net change

| Metric | Before | After | Delta |
|---|---|---|---|
| Lines | 890 | 835 | **−55** |
| Sections in body | 4 (Team / PINs / Activity / Invite) | 4, but PIN card is now a link card | clean |
| JS functions | with 4 dead legacy PIN funcs | dead funcs removed | cleaner |
| Stale info banners | 2 (multi-device + owner-warn) | 0 | accurate |

---

## Files

```
team.html   ← replace existing
```

## Deploy

1. Push the new `team.html`
2. Bump SW version (e.g. v1.5.25 → v1.5.26 — coordinate with C-2 SW bump)
3. Hard-refresh in browser

## Smoke test

### 1. Fresh shop (no legacy PINs)

Open `team.html`. Should see:
- Current Team section showing yourself as OWNER
- PIN Authorization card with intro text + two link tiles
- Staff Activity Log (probably empty + "See full audit log →" link)
- Invite Team Member form

Click 👥 Authorized Users tile → goes to authorized-users.html.
Click 📋 Audit Log tile → goes to audit-log.html.
Click "See full audit log →" → also goes to audit-log.html.

### 2. Shop with pending legacy migration

In console, seed legacy PINs:
```js
localStorage.setItem('sbp_manager_pin', '1234');
localStorage.removeItem('sbp_pin_migration_dismissed_at');
location.reload();
```

Now the PIN Authorization card should show the green ☁️ migration
banner AT TOP, followed by the regular intro + link tiles.

Click "Migrate now" → migration runs as before, banner disappears,
card is back to clean two-tile state.

### 3. Verify nothing legacy left behind

Open DevTools console after reload, run:
```js
console.log('Old PIN warning:', document.getElementById('owner-pin-warning'));
console.log('Old PIN list:', document.getElementById('pin-list'));
console.log('Old Set PIN modal:', document.getElementById('set-pin-modal'));
console.log('renderPinSection defined?', typeof window.renderPinSection);
```

All four should print null/undefined. (The functions/elements no longer
exist, so any old reference would throw — that's expected and good.)

### 4. Other features unaffected

- Invite a team member through the form — should still work as before
  (uses `_sb.from('shop_users').insert(...)`, untouched code).
- Theme toggle, lang toggle, sidebar — all unchanged.

## Pass criteria

- ✅ Page loads with cleaner layout (fewer noisy banners)
- ✅ Link tiles navigate correctly
- ✅ Migration banner still appears when legacy PINs exist
- ✅ Migration completes and banner disappears
- ✅ No JS errors in console
- ✅ Invite team member still works
- ✅ Staff activity log unchanged + new "See full audit log" link works

---

## Status of 022D after this lands

| Stage | Status |
|---|---|
| 022D-A foundation | ✅ |
| 022D-B-1, B-2, B-3a, B-3b (server + frontend gating) | ✅ |
| 022D-C-1 authorized-users.html | ✅ |
| 022D-C-2 audit-log.html | ✅ |
| 022D-C-3 team migration UI (initial) | ✅ |
| 022D-C-4 **team.html simplification (this)** | 📦 |

022D is done after this lands. Roughly 10 days of work from the first
authorization migration to the final UX polish.

## Next priorities

- **Link wiring** to sidebar/settings/reports for the two new pages.
  Upload `lib/sidebar-engine.js`, `settings.html`, `reports.html` and
  I'll batch the additions.
- **022E** Vertical-Aware Sidebar
- **021B-C** Hotel KPIs (occupancy / ADR / RevPAR)
- **028A** Print stylesheet audit
- Pre-beta QA → BETA LAUNCH 🚀
