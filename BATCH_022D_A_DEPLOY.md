# Batch 022D-A — Authorization + Audit Log Foundation

**Status:** Foundation only. No production code wires through this yet.
That's 022D-B (next sub-batch). Deploy this, smoke-test it in isolation,
then 022D-B turns on enforcement for the high-risk RPCs.

---

## What ships

### `db/migrations/031_auth_and_audit_foundation.sql`

**Tables:**

| Table | Purpose |
|---|---|
| `sbp_authorized_users` | Per-shop list of users who can authorize high-risk ops. Each has: `user_name`, `auth_role` (owner/manager/supervisor/cashier), `pin_hash` (bcrypt via pgcrypto), `can_authorize` flag, `active` flag, `last_used_at`. Unique on `(shop_id, user_name)`. RLS: only the shop owner can see/modify. |
| `sbp_audit_log` | Append-only audit trail. Captures actor, action_code, target table/id, before_json, after_json, reason, authorizer info, auth_method, recorded_at. RLS: owner can SELECT; nothing can directly INSERT/UPDATE/DELETE — only via the `sbp_audit_log_write` SECURITY DEFINER function. |

**Settings flag:**

`shops.require_auth_for_high_risk` (boolean, default `false`) — per-shop
toggle. Off by default so existing flows continue working. Owner enables
once they've added authorized users.

**RPCs (9 total):**

| RPC | Owner-only? | Purpose |
|---|---|---|
| `sbp_check_shop_owner(shop_id)` | (helper) | Generic ownership check (mirrors `sbp_check_hospitality_owner`). |
| `sbp_verify_pin(shop_id, pin)` | yes | Returns user info on match. Iterates active users + bcrypt-verifies each. Updates `last_used_at`. |
| `sbp_authorized_users_list(shop_id)` | yes | List users (no `pin_hash` returned). |
| `sbp_authorized_users_upsert(shop_id, name, role, pin?, can_authorize, active, notes)` | yes | Create new or update existing. PIN required for new users. |
| `sbp_authorized_users_set_pin(shop_id, user_id, new_pin)` | yes | Update PIN only. |
| `sbp_authorized_users_set_active(shop_id, user_id, active)` | yes | Soft-disable. |
| `sbp_authorized_users_delete(shop_id, user_id)` | yes | Hard delete. Audit log rows referencing this user retain `authorized_by_name` (denormalized). |
| `sbp_audit_log_write(...)` | (internal) | Helper for high-risk RPCs in 022D-B. Bypasses RLS via SECURITY DEFINER. |
| `sbp_audit_log_query(shop_id, action?, target_table?, target_id?, from?, to?, limit?, offset?)` | yes | Owner reads their audit log. Supports filters + pagination. Capped at 500 rows per call. |

**Security model:**

- PINs are bcrypt-hashed (10 rounds) via pgcrypto `crypt(pin, gen_salt('bf', 10))`
- Verification uses `crypt(input_pin, stored_hash) = stored_hash` (constant-time per row)
- PIN length: 4-12 digits (enforced both in upsert and verify)
- Plaintext PINs **never** stored anywhere server-side
- `pin_hash` column **never** returned in any RPC response
- Audit log is append-only (RLS blocks UPDATE/DELETE for all clients)
- Direct INSERTs into audit_log are blocked too — only `sbp_audit_log_write` (SECURITY DEFINER) can write, and that function is only meaningful when called from another SECURITY DEFINER RPC that has done its own ownership check

### `lib/auth-pin.js`

Global `window.SBPAuth` with two methods:

```js
// The main one — opens the modal, returns when authorized
const { pin, reason, user } = await SBPAuth.requirePIN({
  action:      'extras.remove',
  detail:      'Remove charge: Lunch ₹699',
  reason_hint: 'Why is this being removed?'  // optional
});
// Caller then passes `pin` to the high-risk RPC as p_auth_pin.
// Server re-verifies + writes audit log.

// Direct verify (no modal) — for ad-hoc checks
const res = await SBPAuth.verifyPIN(pin);
```

**Modal UX:**

- Centered bottom-sheet style (mobile-friendly)
- 🔒 icon, title, detail line, big password-mode PIN input
- On-screen numeric keypad with `⌫` clear and `←` backspace (no native keyboard required on mobile)
- Reason text field (optional)
- 3-attempt limit, then auto-closes
- ESC / overlay-click / Cancel button all dismiss cleanly
- Enter key submits
- Themable via CSS variables (`--surf`, `--text`, `--acc`, etc.)
- Dark mode support via `[data-theme="dark"]`
- Self-contained: only depends on `window._sb` and `window._shopId`/localStorage

Rejects with `Error('cancelled')` on dismiss, `Error('too_many_attempts')` after 3 wrong PINs.

---

## Deploy

1. **SQL** — Supabase SQL Editor → run `031_auth_and_audit_foundation.sql`
2. **Frontend** — copy `lib/auth-pin.js` into your repo's `lib/` folder. Push via GitHub Desktop.
3. **No wiring yet** — no pages need updating. The file just needs to be present so 022D-B can `<script src="lib/auth-pin.js">` it in.

---

## Smoke test (before 022D-B)

Run these in Supabase SQL Editor with your shop_id:

```sql
-- 1. Verify extension + tables exist
SELECT extname FROM pg_extension WHERE extname='pgcrypto';
SELECT table_name FROM information_schema.tables
 WHERE table_schema='public'
   AND table_name IN ('sbp_authorized_users','sbp_audit_log');
-- Expected: pgcrypto row + both tables listed

-- 2. Add an authorized user (replace shop_id + use a real PIN)
SELECT public.sbp_authorized_users_upsert(
  '<your-shop-id>'::uuid,   -- p_shop_id
  'Test Manager',           -- p_user_name
  'manager',                -- p_auth_role
  '1234',                   -- p_pin
  true,                     -- p_can_authorize
  true,                     -- p_active
  'Smoke test user'         -- p_notes
);
-- Expected: { "ok": true, "user_id": "...", "created": true }

-- 3. List users
SELECT public.sbp_authorized_users_list('<your-shop-id>'::uuid);
-- Expected: { "ok": true, "users": [...] } with pin_set=true, no pin_hash field

-- 4. Verify the PIN
SELECT public.sbp_verify_pin('<your-shop-id>'::uuid, '1234');
-- Expected: { "ok": true, "user_id": "...", "user_name": "Test Manager", "auth_role": "manager", "can_authorize": true }

-- 5. Verify a wrong PIN
SELECT public.sbp_verify_pin('<your-shop-id>'::uuid, '9999');
-- Expected: { "ok": false, "error": "invalid_pin" }

-- 6. Write an audit log entry (simulates what a high-risk RPC will do)
SELECT public.sbp_audit_log_write(
  '<your-shop-id>'::uuid,
  'test.smoke',
  NULL, NULL,
  '{"before": "value"}'::jsonb,
  '{"after": "value"}'::jsonb,
  'Smoke test from SQL editor',
  NULL, 'Owner (SQL editor)', 'owner_session',
  'SQL Editor'
);
-- Expected: bigint id returned

-- 7. Query the audit log
SELECT public.sbp_audit_log_query('<your-shop-id>'::uuid);
-- Expected: { "ok": true, "entries": [...], "total": 1, "limit": 100, "offset": 0 }

-- 8. Verify PIN updated last_used_at
SELECT user_name, last_used_at FROM public.sbp_authorized_users
 WHERE shop_id = '<your-shop-id>'::uuid;
-- Expected: last_used_at populated for Test Manager

-- 9. Cleanup
SELECT public.sbp_authorized_users_delete('<your-shop-id>'::uuid, '<user-id-from-step-2>');
DELETE FROM public.sbp_audit_log WHERE action_code = 'test.smoke';
-- (The DELETE on audit_log is allowed only because we're in the SQL editor
--  as table owner. For RLS clients this would fail.)
```

## Frontend smoke test

After pushing `lib/auth-pin.js`, open any page that has `_sb` defined
(e.g. folio.html in browser DevTools console):

```js
// Add a test user first if not done in SQL
await _sb.rpc('sbp_authorized_users_upsert', {
  p_shop_id: _shopId,
  p_user_name: 'JS Test',
  p_auth_role: 'manager',
  p_pin: '5678'
});

// Then load auth-pin.js manually:
const s = document.createElement('script');
s.src = 'lib/auth-pin.js';
document.head.appendChild(s);

// After it loads, try the modal:
SBPAuth.requirePIN({
  action: 'test.console',
  detail: 'Just testing the modal',
  reason_hint: 'Type any reason'
}).then(r => console.log('Got:', r))
  .catch(e => console.log('Cancelled:', e.message));

// Modal opens. Enter "5678". Should resolve with the user info.
```

---

## What 022D-B will add

Once 022D-A is verified working:

1. Replace 4 high-risk RPCs to accept `p_auth_pin` parameter:
   - `sbp_bookings_cancel` (already exists, add param)
   - `sbp_booking_extras_remove` (already exists, add param)
   - `sbp_folio_payment_void` (already exists, add param)
   - `sbp_bill_void` (new RPC for voiding finalized bills)
   - Each verifies PIN (when `shops.require_auth_for_high_risk=true`)
   - Each captures before-state, performs action, writes audit log

2. Update frontend high-risk buttons to:
   - Call `SBPAuth.requirePIN({...})` first
   - Pass returned PIN to RPC as `p_auth_pin`
   - Show audit log entry in toast on success

3. Add `<script src="lib/auth-pin.js"></script>` to: folio.html, bookings.html, billing.html, bills.html

## What 022D-C will add

1. **Settings → Authorized Users** page — CRUD interface for owner to manage who can authorize. Replaces the existing localStorage `sbp_shop_users` PIN management in team.html (with a migration prompt that moves any existing PINs to the new server table).
2. **Reports → Audit Log** viewer — searchable table of every high-risk action with before/after diff. Filter by action_code, date range, target.

---

## Honest preview of risks I'm watching for in 022D-B

- **Backwards compat:** `require_auth_for_high_risk` defaults to false so nothing breaks. Owner has to enable + add users first.
- **Owner-without-PIN escape hatch:** when the shop owner (verified via `auth.uid() = shops.owner_id`) calls a high-risk RPC, we treat the auth session itself as authorization (audit_method='owner_session'). They don't need a PIN. This is critical for first-time use before any authorized users are set up.
- **`sbp_booking_extras_remove` is called via folio.html quick-add delete (the × button on each line item).** That UI fires today without any prompt. 022D-B will gate it behind the modal but only when `require_auth_for_high_risk=true`.
- **The bills.html localStorage PIN system stays alive in parallel** until 022D-C ships the migration UI. Both systems can coexist briefly; users won't lose functionality.

---

— TradeCrest Technologies Pvt. Ltd. · CIN U62099UP2026PTC247501
