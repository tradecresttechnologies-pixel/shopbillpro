# Batch 022D-C Stage 1 — authorized-users.html (owner CRUD page)

**Prerequisites:** 022D-A + 022D-B fully deployed.
Verifies that operators can now manage the `sbp_authorized_users`
table (add managers/staff with PINs, toggle active, reset PINs,
delete) and flip the `shops.require_auth_for_high_risk` flag from a UI
instead of from the SQL editor.

**Why this matters:** without it, only the "Test Manager" PIN from
the 022D-A smoke test exists. Real shop owners couldn't add their own
managers to actually use the PIN gate in production.

---

## What's in this stage

**Files (1 new):**
```
authorized-users.html   ← standalone owner-facing CRUD page
```

**No SQL changes.** Uses the 5 RPCs already deployed in migration 031:
- `sbp_authorized_users_list`
- `sbp_authorized_users_upsert`
- `sbp_authorized_users_set_pin`
- `sbp_authorized_users_set_active`
- `sbp_authorized_users_delete`

Plus one direct table update for the global flag:
- `_sb.from('shops').update({require_auth_for_high_risk: bool})`

---

## What the page does

1. **Top: Global toggle** for `require_auth_for_high_risk`.
   - Footgun guard: refuses to turn ON if there are 0 active users
     with `can_authorize=true` (otherwise you'd lock yourself out).
   - Sub-text shows live count: "ON — 3 users can authorize" or
     "OFF — anyone signed in can perform high-risk actions".

2. **User list.** Each user card shows:
   - Avatar with initials
   - Name
   - Role tag (owner / manager / supervisor / cashier, color-coded)
   - "Can authorize" badge if applicable
   - "Inactive" badge if applicable
   - "Last used N min/hours/days ago"
   - 4 action buttons: edit, reset PIN, toggle active, delete

3. **Add/Edit modal:**
   - Name (required, 80 char max)
   - Role dropdown with auto-set "can authorize" default
     (manager/supervisor/owner → true; cashier → false; only on add)
   - PIN field (4–12 digits, only shown on add — uses `text-security:disc`
     CSS to avoid the password-reveal flicker we hit in 022D-A)
   - Can-authorize checkbox
   - Active checkbox (default on for new)
   - Notes (optional, 500 char)
   - PIN field is hidden in Edit mode; use Reset PIN button instead

4. **Reset PIN modal:**
   - Standalone modal, just a PIN input
   - Calls `sbp_authorized_users_set_pin` which bcrypt-hashes the new
     PIN server-side

5. **Delete confirm:** browser confirm() with clear text about what
   happens to audit log entries (preserved, denormalized name field
   in audit log keeps record of who authorized historically).

6. **Bilingual EN/HI**, dark/light theme, mobile-responsive (single
   column up to 600px, sheet-style modals on mobile).

---

## Deploy

1. Push `authorized-users.html` via GitHub Desktop
2. Bump SW version in `sw.js` (e.g. v1.5.23 → v1.5.24) so PWA
   clients re-fetch
3. Open `https://app.shopbillpro.in/authorized-users.html` while
   signed in as the shop owner

There's no link to it from anywhere yet — you can reach it via direct
URL. **Adding a link from settings.html happens later** when you
upload that file.

---

## Smoke test

### 1. Sanity — page loads, lists Test Manager from 022D-A

Open the page. Expected:
- Topbar with "Authorized Users" + back/lang/theme buttons
- Auth toggle card visible, says "OFF — anyone signed in can perform..."
  (assuming you reset it to false at the end of 022D-B smoke tests)
- One user in the list: **Test Manager** with role MANAGER, can-authorize
  badge, "Last: just now" (or relative time of last verify)

If you see "Access denied" instead, the owner check is rejecting
you — verify you're signed in as the shop owner (`sbp_check_shop_owner`
returns ok-false otherwise).

### 2. Add a new user

Click **+ Add User**. Fill in:
- Name: `Suresh Kumar`
- Role: Cashier
- PIN: `5678`
- (can-authorize should auto-uncheck since cashier)
- Active: on (default)
- Notes: `Evening shift`

Save. Should toast "✓ User added" and the list now shows 2 users.

### 3. Toggle require_auth ON

Click the toggle at the top. Should turn orange/on, sub-text updates
to "ON — N users can authorize", toast "🔒 PIN authorization enabled".

### 4. Footgun check

Deactivate all can-authorize users (use the 🚫 button on Test Manager).
Then try to turn auth toggle ON again. Should refuse with toast:
*"Add at least one user who can authorize before enabling."*

Reactivate Test Manager (✅ button).

### 5. Edit user

Click ✏️ on Suresh. Modal opens with all fields pre-filled,
**PIN field hidden** (use Reset PIN instead). Change role to
Supervisor, check "Can authorize". Save. Card updates immediately.

### 6. Reset PIN

Click 🔑 on Suresh. Modal asks for new PIN. Enter `9999`. Save. Toast
"🔑 PIN updated".

Quick verify in browser console:
```js
const r = await _sb.rpc('sbp_verify_pin', { p_shop_id: _shopId, p_pin: '9999' });
console.log(r.data); // Should be ok:true, user_name:'Suresh Kumar'
```

### 7. End-to-end — actual high-risk action with new user's PIN

With require_auth ON, go to folio.html, find a bill with extras, click ×
on an extra. PIN modal pops up. Enter `9999` (Suresh's new PIN).
Should succeed.

Verify the audit log captured Suresh as authorizer:
```js
const a = await _sb.rpc('sbp_audit_log_query', { p_shop_id: _shopId, p_action_code: 'extras.remove' });
console.log(a.data.entries[0]);
// authorized_by_name: 'Suresh Kumar', authorized_by_user_id: <uuid>
```

### 8. Delete user

Click 🗑️ on Suresh. Browser confirm appears. Confirm. Toast
"🗑️ User deleted". List drops to 1 user.

Verify the audit entry from step 7 still references Suresh by NAME
even though his row is gone:
```js
const a2 = await _sb.rpc('sbp_audit_log_query', { p_shop_id: _shopId, p_action_code: 'extras.remove' });
console.log(a2.data.entries[0].authorized_by_name);
// 'Suresh Kumar' — preserved
console.log(a2.data.entries[0].authorized_by_user_id);
// null — FK was nulled because user was deleted
```

### 9. Reset for clean state

Toggle require_auth back OFF.

---

## Pass criteria

- ✅ Page loads cleanly, lists existing users
- ✅ Add new user with PIN works
- ✅ Toggle global flag works
- ✅ Footgun guard prevents lockout
- ✅ Edit user (without PIN field) works
- ✅ Reset PIN works, new PIN verifies via sbp_verify_pin
- ✅ End-to-end PIN flow with new user succeeds
- ✅ Delete user works, audit log preserves authorized_by_name
- ✅ Bilingual labels show correctly when toggling अ icon
- ✅ Dark/light theme works

---

## What's next

- **022D-C-2:** `audit-log.html` — operator-facing audit viewer.
  Searchable, filterable, with before/after JSON diff. Same standalone
  pattern.
- **022D-C-3:** `team.html` migration UI — one-time button to
  bcrypt-hash existing `localStorage.sbp_shop_users` plaintext PINs
  and upload them to `sbp_authorized_users`, then clear localStorage.

When you're ready, reply with **`START 022D-C-2`** or upload
`team.html` to start with the migration UI first.

---

## Future polish (deferred, not blocking)

- **Link from settings.html** — needs settings.html upload. One-line
  add: an item in the settings list that goes to authorized-users.html.
- **Link from sidebar** — adds an entry to `lib/sidebar-engine.js`
  catalog and `sbp_module_profiles`. Worth doing once we add the
  audit log page too, so both are reachable from the sidebar's
  Settings/Admin area.
- **Migration banner** — show a banner on the page if
  `localStorage.sbp_shop_users` has entries that haven't been
  migrated yet (links to team.html migration UI in C-3).
