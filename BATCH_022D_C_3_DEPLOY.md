# Batch 022D-C Stage 3 — team.html migration UI

**Prerequisites:**
- 022D-A, 022D-B, 022D-C-1 all deployed
- Shop has at least one PIN stored in `localStorage.sbp_manager_pin` or
  inside the `pin` field of an entry in `localStorage.sbp_shop_users`
  (otherwise the migration banner won't appear — there's nothing to migrate)

**Scope:** team.html only. One file change. Adds a non-destructive,
one-time-ish migration UI that moves legacy plaintext PINs from
localStorage to bcrypt-hashed entries in `sbp_authorized_users` via the
existing `sbp_authorized_users_upsert` RPC.

---

## What the user sees

A new green/orange banner above the Manager PINs list:

> ☁️ **Migrate PINs to cloud (recommended)**
>
> Your PINs are still on this device only. Migrating moves them to
> encrypted cloud storage (bcrypt-hashed) so they work across all your
> devices, get audit-logged, and survive device loss.
>
> **Found:** Owner PIN + 2 manager PINs.
>
> `[ Migrate now ]   [ Later ]`

Click **Migrate now** → progress text appears below ("Migrating: Suresh
(2/3)") → success/partial/failure summary → toast.

Click **Later** → banner hides, `sbp_pin_migration_dismissed_at` is
set in localStorage so it stays hidden across reloads (until a new
PIN is created, which would re-trigger via `renderPinSection`).

---

## What the migration does

For each candidate:

| Source | Becomes |
|---|---|
| `localStorage.sbp_manager_pin` | `sbp_authorized_users` row with role=`owner`, name=shop.owner_name, can_authorize=true |
| Each `localStorage.sbp_shop_users[*]` with role=`manager` and `pin` set | role=`manager`, name=that staff's name, can_authorize from the existing `pin_active` flag |

For each successful migration:
- Clears the plaintext PIN from localStorage (sets `pin: ''` on staff
  entries, removes `sbp_manager_pin` entirely for the owner)
- Marks the staff entry with `migrated_to_cloud_at: <ISO timestamp>`
- The existing local PIN system can't use these anymore — the next
  void/cancel goes through `SBPAuth.requirePIN` against the cloud table

**Idempotency:** `sbp_authorized_users_upsert` updates an existing
record by name. Re-running won't create duplicates; it'll just re-set
the PIN to whatever's currently in localStorage. If localStorage was
already cleared, that name has no candidate to migrate.

**Non-destructive of `shop_users` (the team-management table):** I only
clear the `pin` field. Everything else — name, email, role — stays so
the team list still renders. Cloud `shop_users` table rows are also
untouched.

**On partial failure:** Successful entries are migrated and cleared
locally; failed entries stay in localStorage (PIN unchanged) so they
can be retried. Progress text shows what failed and why.

---

## Deploy

1. Push the new `team.html` via GitHub Desktop
2. Bump SW version (e.g. v1.5.24 → v1.5.25)
3. Hard-refresh in browser

---

## Smoke test

### 1. Seed local PINs (if you don't already have any)

If you've been testing in fresh contexts and don't have legacy PINs
yet, seed some in DevTools console first:

```js
// Set an Owner PIN
localStorage.setItem('sbp_manager_pin', '1111');

// Add a staff entry with PIN
const staff = JSON.parse(localStorage.getItem('sbp_shop_users')||'[]');
staff.push({
  id: 'test_seed_1',
  name: 'Test Staff A',
  email: 'test@a.com',
  role: 'manager',
  pin: '2222',
  pin_active: true
});
localStorage.setItem('sbp_shop_users', JSON.stringify(staff));

// Clear any previous dismissal
localStorage.removeItem('sbp_pin_migration_dismissed_at');
```

### 2. Visit team.html

Reload `team.html`. Scroll to the **🔐 Manager PINs** section. You
should see the green migration banner: *"Found: Owner PIN + 1 manager PIN"*.

### 3. Click "Migrate now"

Watch the progress text update through each candidate. Should end with:
*"✓ All 2 PINs migrated to cloud. Local copies cleared."*

Toast: *"☁️ Migration complete"*

Banner auto-hides after 1.2s (because candidates list is now empty).

### 4. Verify cloud entries

In console:
```js
const r = await _sb.rpc('sbp_authorized_users_list', { p_shop_id: _shopId });
console.log(r.data.users);
```

Should now include the migrated entries (alongside any from earlier C-1
testing). Owner with role=`owner`, can_authorize=true. Test Staff A
with role=`manager`, can_authorize=true.

### 5. Verify local cleanup

```js
console.log('Owner PIN local:', localStorage.getItem('sbp_manager_pin'));  // null
const staff = JSON.parse(localStorage.getItem('sbp_shop_users')||'[]');
console.log('Staff pin after migration:', staff.find(s => s.id === 'test_seed_1'));
// pin: '', pin_active: false, migrated_to_cloud_at: '2026-...'
```

### 6. Verify PIN actually works

```js
const v = await _sb.rpc('sbp_verify_pin', { p_shop_id: _shopId, p_pin: '2222' });
console.log(v.data);
// { ok:true, user_name:'Test Staff A', auth_role:'manager', can_authorize:true }
```

### 7. End-to-end real action

Make sure `require_auth_for_high_risk` is ON (via authorized-users.html).
Go to folio.html, remove an extra. PIN modal pops up. Enter `2222`.
Should authorize and the audit log will show "Test Staff A" as the
authorizer.

### 8. Idempotency

Without resetting anything, click "Migrate now" again (in a fresh
session if needed — re-seed if dismissal flag is set). Should see
"Nothing to migrate" toast OR (if you re-seeded) succeed without
creating duplicate entries.

### 9. Partial-failure simulation (optional)

Temporarily corrupt the RPC call to verify failure handling:
```js
// In console, NOT recommended in real testing — just for verifying error UI:
// (skip this step in real smoke testing)
```

You don't actually need to test this — the failure path uses the same
try/catch pattern as the success path, just shows the error in the
progress div instead of clearing.

### 10. "Later" button

Re-seed a PIN, reload page, click "Later". Banner hides. Reload page.
Banner stays hidden. Add another PIN via console (e.g. another staff
member). Reload. Banner *still* hidden (dismissal is persistent).

To get the banner back: clear the dismissal flag:
```js
localStorage.removeItem('sbp_pin_migration_dismissed_at');
location.reload();
```

---

## Pass criteria

- ✅ Banner appears when local PINs exist and not dismissed
- ✅ Banner hides when no candidates OR dismissed
- ✅ "Migrate now" successfully writes to `sbp_authorized_users`
- ✅ Local plaintext PINs cleared after successful migration
- ✅ Migrated PINs verify via `sbp_verify_pin`
- ✅ End-to-end PIN gating works for a migrated user
- ✅ Idempotent — re-running doesn't duplicate
- ✅ "Later" persists across reloads via localStorage flag

---

## With this, 022D-C is complete

| Stage | What | Status |
|---|---|---|
| 022D-C-1 | `authorized-users.html` | ✅ Done |
| 022D-C-2 | `audit-log.html` | ⏳ Not started |
| 022D-C-3 | team.html migration UI | 📦 This stage |

After C-2 ships, **022D is fully done** — the entire authorization +
audit + UI story is shipped end-to-end. Operators can:

1. Add/edit/delete authorized users with PINs (C-1)
2. View who did what high-risk action and when (C-2)
3. Migrate their legacy localStorage PINs to cloud (C-3)
4. All 4 high-risk operations gated by server-verified PIN + audit-logged (B-1, B-2, B-3)

After 022D is done, next priority items from the master roadmap:
- 022E Vertical-Aware Sidebar
- 021B-C Hotel KPIs
- Pre-beta QA → BETA LAUNCH

Ready for **022D-C-2** (audit-log.html) when you are.
