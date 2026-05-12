# Batch 022D Link Wiring — settings + reports + sidebar + DB

**Scope:** Make `authorized-users.html` and `audit-log.html` (built in
022D-C-1 / C-2) reachable from the rest of the app via their natural
homes — Settings menu, Reports topbar, and the global Sidebar.

**Prerequisites:** 022D-A through 022D-C-4 all deployed. Both pages
exist at the expected URLs and work standalone.

---

## What's in this batch

**Files (4):**
```
db/migrations/034_authorized_users_audit_log_modules.sql   ← NEW
settings.html                                              ← +13 lines
reports.html                                               ← +2 lines
lib/sidebar-engine.js                                      ← +6 lines
```

---

## What each change does

### 1. `settings.html` — Three insertions

**A.** After "Staff & Roles" menu item, insert two new menu items:
- 🔒 **Authorized Users** → `authorized-users.html`
- 📋 **Audit Log** → `audit-log.html`

**B.** Replaced the legacy "Manager PIN" menu item (which used to
open the localStorage-based `pin-modal`) with a redirect to
`authorized-users.html`. Cloud PINs are the canonical store now.

The pin-modal DOM is left in place for backwards compatibility — no
visible behavior change beyond the entry-point — but the user can
no longer reach the legacy local-PIN UI from settings.

### 2. `reports.html` — One icon button

In the topbar's `tb-r` group, after Print/Export, added a 🔒 icon
button: **"Audit Log — who did what"** → opens `audit-log.html`.

No new tab (audit-log is a separate page, not a sub-report panel).
Icon button keeps the tabs row uncluttered.

### 3. `lib/sidebar-engine.js` — Two catalog entries + two fallback entries

Added to `MODULE_CATALOG`:
```js
'authorized_users': { href: 'authorized-users.html', icon: '🔒', ..., order: 122 }
'audit_log':        { href: 'audit-log.html',        icon: '📋', ..., order: 124 }
```

Added to `DEFAULT_FALLBACK` so they appear even when the shop has
no cloud module profile yet (new installs, offline).

Slotted at orders 122/124 to sit right after `team` (120) and before
`subscription` (130) — the "shop config" group of the sidebar.

### 4. `db/migrations/034_...sql` — Add modules to every profile

Without this, shops driven by `get_shop_modules` RPC (which is most
production shops) won't see the new sidebar entries because the
server profile list filters them out. The migration uses a `SELECT
DISTINCT profile` + `INSERT ON CONFLICT` pattern to add both modules
to every existing profile. Idempotent.

---

## Deploy

### Order matters:

**Step 1.** Run `034_authorized_users_audit_log_modules.sql` in
Supabase SQL Editor. Expected: "Success", two INSERT statements
each affecting ~100 rows (number of profiles).

Verify:
```sql
SELECT profile, module_code, status
  FROM sbp_module_profiles
 WHERE module_code IN ('authorized_users','audit_log')
 ORDER BY module_code, profile
 LIMIT 10;
```
Should show both module codes across multiple profiles, all `active`.

**Step 2.** Push the 3 frontend files via GitHub Desktop:
- `lib/sidebar-engine.js`
- `settings.html`
- `reports.html`

**Step 3.** Bump SW version in `sw.js` (e.g. v1.5.25 → v1.5.26).

**Step 4.** Hard-refresh in your browser.

---

## Smoke test

### 1. Sidebar shows new entries

Open any page with the sidebar (e.g. `dashboard.html`). The sidebar
should now include:
- 🔒 **Authorized Users** (between Team and Plans)
- 📋 **Audit Log** (right after Authorized Users)

Click each → navigates to the right page.

### 2. Settings page

Open `settings.html`. Scroll to the "Staff & Roles" section. Two
new items should appear right below:
- 🔒 **Authorized Users**
- 📋 **Audit Log**

Click each → navigates correctly.

Scroll down to "App Settings". The "🔐 Manager PIN" item now goes
to `authorized-users.html` (instead of opening the legacy modal).

### 3. Reports page

Open `reports.html`. Top-right of the topbar should show four icons:
☀️ (theme), 🖨️ (print), 📤 (export), **🔒 (audit log)**.

Click 🔒 → opens `audit-log.html` in same tab.

### 4. SQL verification (optional)

In SQL Editor:
```sql
SELECT COUNT(DISTINCT profile) AS profiles_with_audit_log
  FROM sbp_module_profiles
 WHERE module_code = 'audit_log';
```
Should be roughly equal to the total number of distinct profiles
(was 19 INSERT blocks in 003, now expanded to ~100 distinct profiles
across all subsequent migrations).

---

## Pass criteria

- ✅ Migration 034 runs without errors
- ✅ Two new items visible in sidebar (between Team and Plans)
- ✅ Two new items visible in Settings menu (after Staff & Roles)
- ✅ Legacy "Manager PIN" item in Settings App Settings section now
  redirects to authorized-users.html
- ✅ New 🔒 icon button in reports.html topbar opens audit-log.html
- ✅ All navigation works in both directions (back button returns
  correctly)

---

## What's NOT done (yet)

- **Owner-only sidebar gating.** The sidebar shows these entries to
  all users (cashier, manager, owner). For non-owners, clicking
  them just opens an "Access denied" empty state because the
  server-side RPCs enforce owner-only. That's safe but slightly
  awkward UX. Adding role-based sidebar filtering is a separate
  enhancement (probably batched with 022E Vertical-Aware Sidebar).
- **Mobile bottom-nav exposure.** These two entries only show in
  the desktop side rail because mobile bottom-nav is capped at 5
  items. Owners visit settings-style features less often anyway;
  they're 1 tap away via the "More ☰" overflow.

---

## After this lands, 022D is FULLY shipped

| Stage | Status |
|---|---|
| 022D-A foundation | ✅ |
| 022D-B-1, B-2, B-3a, B-3b | ✅ |
| 022D-C-1 authorized-users.html | ✅ |
| 022D-C-2 audit-log.html | ✅ |
| 022D-C-3 team migration UI | ✅ |
| 022D-C-4 team.html simplification | ✅ |
| **022D Link Wiring (this)** | 📦 |

Next priorities from the master roadmap:
- 022E Vertical-Aware Sidebar (~1.5h)
- 021B-C Hotel KPIs (~2h)
- 028A Print stylesheet audit (~2-3h)
- Vertical polishing → Pre-beta QA → BETA LAUNCH 🚀
