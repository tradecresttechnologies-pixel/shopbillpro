# Batch 022D-B Stage 1 — Deploy & Smoke Test

**Scope:** SQL only. Adds PIN-authorization + audit-log to:
- `sbp_bookings_cancel` (extended)
- `sbp_booking_extras_remove` (extended)
- `sbp_bill_void` (new)

**Safety:** With `shops.require_auth_for_high_risk = false` (default),
existing call sites that don't pass `p_auth_pin` continue to work
unchanged. Audit log entries get auth_method='none' but no other
behavior change.

`sbp_folio_payment_void` is **deferred to Stage B-2** — need to see its
live signature first since the migration that created it isn't in the
local repo.

---

## 1. Deploy

### 1a. Run migration in Supabase SQL Editor

Paste the entire `db/migrations/032_high_risk_auth_wiring.sql` and Run.

**Expected:** "Success" with no errors. No rows returned (function defs).

If you see `function "sbp_check_hospitality_owner" does not exist` →
migration 015 wasn't run first (unlikely given hospitality is live, but
worth checking).

### 1b. Verify the functions are in place

In SQL Editor:

```sql
SELECT
  p.proname AS function_name,
  pg_get_function_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'sbp_bookings_cancel',
    'sbp_booking_extras_remove',
    'sbp_bill_void',
    '_sbp_verify_auth_for_high_risk',
    '_sbp_actor_name'
  )
ORDER BY p.proname;
```

**Expected 5 rows.** Each should show 4-arg signatures for the three
RPCs (`p_shop_id, p_X_id, p_reason DEFAULT NULL, p_auth_pin DEFAULT NULL`).

---

## 2. Smoke test (browser console — must be logged in)

Open `app.shopbillpro.in/folio.html`, F12 → Console.

### 2a. Confirm shop auth flag defaults to false

```js
const r = await _sb.from('shops').select('id,name,require_auth_for_high_risk').eq('id',_shopId).single();
console.table([r.data]);
```

`require_auth_for_high_risk` should be `false` (or null, which is treated
as false). If it's already true and you don't have an authorized user
yet, you'd be locked out — go to Supabase Table Editor and set it back
to false before smoke testing.

### 2b. Test sbp_bill_void with require_auth=false (no PIN needed)

Find a finalized bill that's NOT voided. Pick any old one for testing.
Skip this step if you don't have a test bill you're OK voiding.

```js
// 1. Find a voidable bill
const bills = (await _sb.from('bills')
  .select('id,invoice_no,grand_total,status,voided_at')
  .eq('shop_id',_shopId)
  .is('voided_at',null)
  .neq('status','voided')
  .limit(3)).data;
console.table(bills);
```

Pick a `bills[0].id` you can safely void. Then:

```js
// 2. Void it (no PIN, since require_auth=false)
const result = await _sb.rpc('sbp_bill_void', {
  p_shop_id: _shopId,
  p_bill_id: bills[0].id,
  p_reason: 'Smoke test 022D-B-1'
});
console.log('Result:', result.data);
```

**Expected:** `{ ok: true, voided_at: '<timestamp>' }`

```js
// 3. Try again — should be idempotent / rejected as already_voided
const r2 = await _sb.rpc('sbp_bill_void', {
  p_shop_id: _shopId,
  p_bill_id: bills[0].id,
  p_reason: 'Should fail'
});
console.log('Second call:', r2.data);
```

**Expected:** `{ ok: false, error: 'already_voided', voided_at: '...' }`

### 2c. Verify the audit log captured it

```js
const audit = await _sb.rpc('sbp_audit_log_query', {
  p_shop_id: _shopId,
  p_action_code: 'bill.void'
});
console.log('Audit entries for bill.void:', audit.data);
```

**Expected:** at least 1 entry with:
- `action_code: 'bill.void'`
- `target_table: 'bills'`
- `target_id: <the bill id>`
- `auth_method: 'none'` (since require_auth was off)
- `actor_name: <your name or email>`
- `before_json.status: <previous status>`
- `after_json.status: 'voided'`
- `reason: 'Smoke test 022D-B-1'`

### 2d. Turn on require_auth and test PIN gate

```js
// Enable PIN requirement
await _sb.from('shops').update({require_auth_for_high_risk: true}).eq('id',_shopId);
console.log('PIN auth now required.');
```

Now find another voidable bill and try without a PIN:

```js
const r3 = await _sb.rpc('sbp_bill_void', {
  p_shop_id: _shopId,
  p_bill_id: bills[1].id,
  p_reason: 'Try without PIN'
});
console.log('Should fail with requires_authorization:', r3.data);
```

**Expected:** `{ ok: false, error: 'requires_authorization', action_code: 'bill.void' }`

Now with the wrong PIN:

```js
const r4 = await _sb.rpc('sbp_bill_void', {
  p_shop_id: _shopId,
  p_bill_id: bills[1].id,
  p_reason: 'Try with wrong PIN',
  p_auth_pin: '9999'
});
console.log('Should fail with invalid_pin:', r4.data);
```

**Expected:** `{ ok: false, error: 'invalid_pin', action_code: 'bill.void' }`

Now with the right PIN (`1234` for Test Manager from 022D-A smoke test):

```js
const r5 = await _sb.rpc('sbp_bill_void', {
  p_shop_id: _shopId,
  p_bill_id: bills[1].id,
  p_reason: 'Properly authorized void',
  p_auth_pin: '1234'
});
console.log('Should succeed:', r5.data);
```

**Expected:** `{ ok: true, voided_at: '...' }`

### 2e. Verify audit log shows the PIN-authorized entry

```js
const audit2 = await _sb.rpc('sbp_audit_log_query', {
  p_shop_id: _shopId,
  p_action_code: 'bill.void'
});
console.log(audit2.data.entries[0]);  // most recent first
```

**Expected:** the latest entry has:
- `auth_method: 'pin'`
- `authorized_by_name: 'Test Manager'`
- `authorized_by_user_id: <uuid>`

### 2f. Turn require_auth back off (so existing flows aren't broken)

```js
await _sb.from('shops').update({require_auth_for_high_risk: false}).eq('id',_shopId);
console.log('Reset to default.');
```

---

## 3. Pass criteria

All these should be true:
- ✅ Migration ran with no errors
- ✅ 5 functions visible in pg_proc
- ✅ Void without PIN works when require_auth=false
- ✅ Idempotency: second void on same bill → `already_voided`
- ✅ Audit log records every action (auth_method='none' or 'pin')
- ✅ With require_auth=true, no PIN → `requires_authorization`
- ✅ With require_auth=true, wrong PIN → `invalid_pin`
- ✅ With require_auth=true, right PIN → succeeds, audit shows `auth_method='pin'`
- ✅ `require_auth_for_high_risk` reset to false at end

---

## 4. After this passes — next stages

- **Stage B-2:** Paste signature of `sbp_folio_payment_void` from your
  live DB. Run this in SQL Editor and share the output:
  ```sql
  SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='sbp_folio_payment_void';
  ```
  Then I write its extension.

- **Stage B-3:** Frontend wiring. Upload latest `folio.html` so I can
  wrap `removeExtra()` and `voidPayment()` in `SBPAuth.requirePIN`.
  Will also rewrite `bills.html voidBill()` to use the new RPC instead
  of direct UPDATE, and `bookings.html doCancel()` similarly.
