# Batch 022D-B Stage 3b — bookings.html + bills.html PIN wiring

**Prerequisites:**
- 022D-A (foundation) deployed
- 022D-B-1 (migration 032) deployed
- 022D-B-2 (migration 033) deployed
- 022D-B-3a (folio.html + hospitality.js v1.1) deployed
- Test Manager PIN '1234' exists in `sbp_authorized_users` from 022D-A smoke test

**Scope:** Wires `SBPAuth.requirePIN` into the last two pages that
have high-risk action buttons:

- `bookings.html` → `doCancel()` (Cancel Booking button)
- `bills.html` → `voidBill()` (🚫 Void Bill button)

After this, **all 4 high-risk operations are PIN-gated end-to-end:**

| Action | Page | Handler | RPC |
|---|---|---|---|
| Extras remove | folio.html | `removeExtra()` | `sbp_booking_extras_remove` |
| Payment void | folio.html | `voidPayment()` | `sbp_folio_payment_void` |
| Booking cancel | bookings.html | `doCancel()` | `sbp_bookings_cancel` |
| Bill void | bills.html | `voidBill()` | `sbp_bill_void` |

---

## What's included

**Files (3):**
```
lib/auth-pin.js   ← v5 final (included for completeness)
bookings.html     ← _callWithAuth helper + refactored doCancel()
bills.html        ← _callWithAuth helper + refactored voidBill() with
                    offline fallback to _doVoidBillLegacy()
```

---

## bookings.html changes

Same pattern as folio.html:

1. Added `<script src="lib/auth-pin.js">`
2. Added `_callWithAuth(meta, caller)` helper near `tomorrowISO()`
3. Refactored `doCancel()`:
   - Removed inline `prompt('Reason for cancellation')` — replaced
     with `confirm('Cancel this booking?')` + reason captured in
     PIN modal if auth is required
   - Wrapped RPC call in `_callWithAuth` (optimistic-retry-with-PIN)
   - Handles 'cancelled' / 'too_many_attempts' errors gracefully

**UX:**
- Auth OFF: simple confirm → cancel happens
- Auth ON: confirm → PIN modal slides up → Manager PIN + reason → cancel

---

## bills.html changes (more involved)

1. Added `<script src="lib/auth-pin.js">`
2. Added `_callWithAuth(meta, caller)` helper near `toast()`
3. **Replaced** `voidBill()` + `_doVoidBill()`:
   - Drops the old `requirePIN('void_bill', ...)` localStorage wrapper
   - Now calls `sbp_bill_void` RPC first (atomic: PIN gate + audit log
     + DB update on server)
   - Stock-restore + customer-ledger-reversal still happen client-side,
     but **only after** the server confirms the void (so cancelling
     the PIN modal doesn't restore stock prematurely)
   - Server-side audit log entry now captures: action_code='bill.void',
     before/after snapshots, authorized_by_name, reason
4. **Added** `_doVoidBillLegacy(billId)` as offline fallback:
   - Used when `_callWithAuth` throws a non-cancellation error (server
     unreachable, network failure)
   - Used when RPC returns `bill_not_found` (i.e. bill is a local-only
     stub not synced to server, identified by `local_` prefix on id)
   - Preserves the pre-022D-B behavior end-to-end: legacy PIN modal,
     direct `_sb.from('bills').update()`, local audit only
   - Audit log entry tagged with `offline_fallback: true` so the
     mismatch with server audit log is auditable later

**The 5 OTHER PIN-gated actions in bills.html still use the legacy
localStorage PIN system** (intentional — server-side RPCs don't exist
for them yet):

- `edit_bill` (line ~975)
- `reopen_bill` (line ~1069)
- `delete_bill` (line ~1390)
- `void_item` (line ~1414)
- `delete_item` (line ~1459)

These get migrated when their RPCs are added in a future batch
(likely 022D-D, after the audit viewer + settings page in 022D-C).

---

## Deploy

1. Push all 3 files via GitHub Desktop:
   - `lib/auth-pin.js`
   - `bookings.html`
   - `bills.html`
2. Bump SW version (e.g. v1.5.22 → v1.5.23)
3. Hard-refresh

---

## Smoke test

### Test 1 — bookings.html cancel, auth OFF

```js
// Ensure auth off
await _sb.from('shops').update({require_auth_for_high_risk: false}).eq('id', _shopId);
```

Go to `bookings.html`. Find a non-cancelled booking, click "Cancel
Booking". Confirm dialog. Should succeed with toast `❌ Cancelled`.
No PIN modal.

### Test 2 — bookings.html cancel, auth ON

```js
await _sb.from('shops').update({require_auth_for_high_risk: true}).eq('id', _shopId);
```

Reload. Try canceling another booking. Should pop SBPAuth modal.
Enter `1234` + reason → succeeds. Verify audit:

```js
const a = await _sb.rpc('sbp_audit_log_query', {
  p_shop_id: _shopId,
  p_action_code: 'booking.cancel'
});
console.log(a.data.entries[0]);
// auth_method:'pin', authorized_by_name:'Test Manager', reason set
```

### Test 3 — bills.html void, auth OFF

Reset:
```js
await _sb.from('shops').update({require_auth_for_high_risk: false}).eq('id', _shopId);
```

Find a non-voided bill in bills.html, click 🚫 Void Bill. Confirm.
Should void with toast `🚫 Bill voided — stock restored`. No PIN
modal. Verify in audit log: `auth_method:'none'`.

### Test 4 — bills.html void, auth ON

```js
await _sb.from('shops').update({require_auth_for_high_risk: true}).eq('id', _shopId);
```

Try voiding another bill. SBPAuth modal pops. Enter `1234` + reason.
Succeeds. Verify:

```js
const a = await _sb.rpc('sbp_audit_log_query', {
  p_shop_id: _shopId,
  p_action_code: 'bill.void'
});
console.log(a.data.entries[0]);
// Should show authorized_by_name:'Test Manager'
```

### Test 5 — Idempotency

Try voiding the SAME bill again from Test 4. Should show toast
`This bill was already voided` and not re-run side effects.

### Test 6 — Cancel PIN modal

With auth ON, start voiding a bill → PIN modal pops → click Cancel.
Modal closes, nothing happens. No stock restored, no DB change.

### Test 7 — Wrong PIN x3

With auth ON, start voiding → enter `9999` three times → modal
auto-closes with "Too many wrong PIN attempts" toast. No void.

### Test 8 — Reset

```js
await _sb.from('shops').update({require_auth_for_high_risk: false}).eq('id', _shopId);
```

---

## Pass criteria

- ✅ Cancel booking works auth-off (existing behavior)
- ✅ Cancel booking with auth-on → PIN modal → succeeds with audit
- ✅ Void bill works auth-off (legacy stock-restore + ledger flow preserved)
- ✅ Void bill with auth-on → PIN modal → succeeds, server-side
  audit shows `auth_method:'pin'`
- ✅ Idempotency: re-voiding same bill returns `already_voided`
- ✅ Cancel modal → no side effects
- ✅ Wrong PIN x3 → no side effects, clear error

---

## 022D-B is now complete

After this passes, every server-side high-risk operation is:
- **Authorized** by a PIN (when shop requires it) — bcrypt-verified
  by `sbp_authorized_users.pin_hash`
- **Audited** to `sbp_audit_log` with before/after, reason, actor
- **Backward compatible** when auth is off (current default)

### Next: 022D-C

The infrastructure works but isn't exposed to operators yet. 022D-C
adds the user-facing pieces:

1. **Settings → Authorized Users** page (CRUD for owner)
2. **Reports → Audit Log viewer** (searchable, with before/after diff)
3. **Migration UI** in team.html to convert the existing legacy
   `localStorage.sbp_shop_users` PINs to bcrypt-hashed entries in
   `sbp_authorized_users`, then clear them from localStorage.

Ready to spec 022D-C when you are.
