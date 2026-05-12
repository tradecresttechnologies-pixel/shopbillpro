# Batch 022D-B Stage 3a — folio.html PIN wiring

**Prerequisites:** Migrations 031, 032, 033 must already be deployed
and smoke-tested. (i.e. 022D-A, 022D-B-1, 022D-B-2 are done.)

**Scope:** Frontend only. Wires `SBPAuth.requirePIN` into folio.html's
two high-risk buttons:
- × Remove extra (`removeExtra(id)`)
- × Void payment (`voidPayment(id)`)

**Files (3):**
```
lib/auth-pin.js     ← v5 final (included in case yours is older)
lib/hospitality.js  ← v1.1 — passes reason+authPin through to RPCs
folio.html          ← refactored removeExtra() + voidPayment()
```

**Bookings.html cancel button + bills.html void button** are not
in this stage. Upload your current `bookings.html` and `bills.html`
and I'll ship them as Stage B-3b.

---

## What changes in the UX

### When `shops.require_auth_for_high_risk = false` (default):

- Click × on an extra → confirm dialog → action happens immediately.
  **No new behavior.** Existing flow preserved.
- Click × on a payment → confirm dialog → action happens immediately.
  Previously prompted for an optional reason; that prompt is removed
  to match the other 3 high-risk actions. Reason is captured via the
  PIN modal when auth is enabled.

### When `shops.require_auth_for_high_risk = true`:

- Click × on an extra → confirm dialog → first RPC call returns
  `requires_authorization` → PIN modal slides up → operator enters
  PIN + reason → retry succeeds.
- Same for payment void.
- Wrong PIN → modal stays open with "Incorrect PIN" message, up to
  3 tries → then auto-dismisses with "Too many wrong attempts" toast.
- Cancel modal → operation aborted silently, no toast.

---

## How the wiring works internally

A new `_callWithAuth(meta, caller)` helper was added to folio.html
(near the other utility functions). It implements the
**optimistic-retry-with-PIN** pattern:

1. Call the RPC without a PIN
2. If the RPC returns `{ok:false, error:'requires_authorization'}`,
   show the SBPAuth modal
3. Retry the RPC with the PIN + reason from the modal
4. Return final result for the caller to handle

This means:
- When auth is OFF: zero extra UX (no modal, no checks)
- When auth is ON: modal only appears for actions that need it,
  triggered by the server's response, not pre-emptively

---

## Deploy

1. Push all 3 files via GitHub Desktop:
   - `lib/auth-pin.js`
   - `lib/hospitality.js`
   - `folio.html`
2. Bump SW version in `sw.js` (e.g. v1.5.21 → v1.5.22)
3. Hard-refresh in browser

## Smoke test

### Test 1 — auth OFF, extras remove (existing behavior)

```js
// Make sure auth is off
await _sb.from('shops').update({require_auth_for_high_risk: false}).eq('id', _shopId);
```

Open any folio with an extras line. Click ×. Confirm. Should remove
with toast `✓ Removed`. No PIN modal.

### Test 2 — auth OFF, payment void

Add a payment to a folio, then click × on it. Confirm. Should void
with toast `✓ Payment voided`. No PIN modal, no reason prompt
(this is the small UX change — see deploy notes above).

### Test 3 — Turn auth ON

```js
await _sb.from('shops').update({require_auth_for_high_risk: true}).eq('id', _shopId);
```

Reload folio.html. Click × on an extra → confirm → **PIN modal slides
up**. Enter `1234` (Test Manager PIN from 022D-A smoke test). Optionally
add a reason like "duplicate charge". Click Authorize.

Should succeed with toast `✓ Removed`. Verify in audit log:

```js
const a = await _sb.rpc('sbp_audit_log_query', {
  p_shop_id: _shopId,
  p_action_code: 'extras.remove'
});
console.log(a.data.entries[0]);
// Should show auth_method:'pin', authorized_by_name:'Test Manager',
// reason:'duplicate charge'
```

### Test 4 — Wrong PIN

Click × on another extra → confirm → PIN modal → enter `9999` →
Authorize. Should show "Incorrect PIN" and stay open.

Try `9999` two more times → modal auto-closes, toast: "Too many wrong
PIN attempts".

### Test 5 — Cancel modal

Click × → confirm → PIN modal → click Cancel. Modal closes, nothing
else happens (no toast, no action).

### Test 6 — Reset

```js
await _sb.from('shops').update({require_auth_for_high_risk: false}).eq('id', _shopId);
```

## Pass criteria

- ✅ Extra/payment remove still works when auth=false (no regression)
- ✅ With auth=true: PIN modal appears, accepts correct PIN, retries succeed
- ✅ Wrong PIN shows error inline, max 3 attempts
- ✅ Cancel modal aborts silently
- ✅ Audit log shows `auth_method:'pin'` + correct authorized_by_name
- ✅ Reason from modal captured in audit log

---

## What's left (Stage B-3b)

Once this passes, upload:
- `bookings.html` (current) — to wire `doCancel()` button
- `bills.html` (current) — to replace `voidBill()` with `sbp_bill_void` RPC

Then 022D-B is done end-to-end — all 4 high-risk actions PIN-gated +
audit-logged from button to database.

After that: 022D-C (Settings → Authorized Users page, Reports → Audit
Log viewer, localStorage PIN migration).
