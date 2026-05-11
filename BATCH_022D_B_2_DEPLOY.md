# Batch 022D-B Stage 2 — sbp_folio_payment_void

**Prerequisite:** Stage 1 (migration 032) must already be deployed and
verified. This stage uses the helpers from 032
(`_sbp_verify_auth_for_high_risk`, `_sbp_actor_name`,
`sbp_audit_log_write`).

**Scope:** SQL only. Extends `sbp_folio_payment_void` with PIN gating
and audit logging. Same pattern as the three RPCs in B-1.

---

## 1. Deploy

Run `db/migrations/033_payment_void_auth_wiring.sql` in Supabase SQL
Editor. Expected: "Success", no rows.

Verify:
```sql
SELECT pg_get_function_arguments(p.oid) AS args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname = 'sbp_folio_payment_void';
```

Expected:
```
p_shop_id uuid, p_payment_id uuid,
p_reason text DEFAULT NULL::text, p_auth_pin text DEFAULT NULL::text
```

---

## 2. Smoke test (browser console at app.shopbillpro.in/folio.html)

### 2a. Backward compatibility — 3-arg call still works

If you have a folio with a non-voided payment, find a payment id:

```js
const pays = (await _sb.from('sbp_folio_payments')
  .select('id, booking_id, amount, payment_mode, is_voided')
  .eq('shop_id', _shopId)
  .eq('is_voided', false)
  .limit(3)).data;
console.table(pays);
```

If you have one you can safely void for testing, pick `pays[0].id` and:

```js
// Call with the OLD 3-arg signature — no PIN, like before
const r = await _sb.rpc('sbp_folio_payment_void', {
  p_shop_id: _shopId,
  p_payment_id: pays[0].id,
  p_reason: 'Stage B-2 smoke test'
});
console.log('Result:', r.data);
```

Expected (when shop's `require_auth_for_high_risk = false`):
```
{ ok: true, voided: 1 }
```

### 2b. Idempotency

```js
// Same call again — should now report already_voided
const r2 = await _sb.rpc('sbp_folio_payment_void', {
  p_shop_id: _shopId,
  p_payment_id: pays[0].id,
  p_reason: 'Should fail'
});
console.log('Should be already_voided:', r2.data);
```

Expected: `{ ok: false, error: 'already_voided', voided_at: '<ts>' }`

### 2c. Audit log captured the void

```js
const audit = await _sb.rpc('sbp_audit_log_query', {
  p_shop_id: _shopId,
  p_action_code: 'payment.void'
});
console.log(audit.data.entries[0]);
```

Expected most-recent entry:
- `action_code: 'payment.void'`
- `target_table: 'sbp_folio_payments'`
- `target_id: <the payment id>`
- `auth_method: 'none'`
- `before_json.is_voided: false`
- `after_json.is_voided: true`
- `actor_name: <your name>`
- `reason: 'Stage B-2 smoke test'`

### 2d. PIN gate (turn on require_auth)

```js
await _sb.from('shops').update({require_auth_for_high_risk: true}).eq('id', _shopId);
```

Pick another voidable payment `pays[1].id`:

```js
// No PIN
const r3 = await _sb.rpc('sbp_folio_payment_void', {
  p_shop_id: _shopId,
  p_payment_id: pays[1].id,
  p_reason: 'Try without PIN'
});
console.log(r3.data); // { ok:false, error:'requires_authorization', action_code:'payment.void' }

// Wrong PIN
const r4 = await _sb.rpc('sbp_folio_payment_void', {
  p_shop_id: _shopId,
  p_payment_id: pays[1].id,
  p_reason: 'Try with wrong PIN',
  p_auth_pin: '9999'
});
console.log(r4.data); // { ok:false, error:'invalid_pin', action_code:'payment.void' }

// Right PIN
const r5 = await _sb.rpc('sbp_folio_payment_void', {
  p_shop_id: _shopId,
  p_payment_id: pays[1].id,
  p_reason: 'Authorized void',
  p_auth_pin: '1234'
});
console.log(r5.data); // { ok:true, voided:1 }

// Audit
const audit2 = await _sb.rpc('sbp_audit_log_query', {
  p_shop_id: _shopId,
  p_action_code: 'payment.void'
});
console.log(audit2.data.entries[0]);
// Should show auth_method:'pin', authorized_by_name:'Test Manager'
```

### 2e. Reset

```js
await _sb.from('shops').update({require_auth_for_high_risk: false}).eq('id', _shopId);
```

---

## 3. Pass criteria

- ✅ Function signature now has 4 args
- ✅ 3-arg call still works (backward compat)
- ✅ Idempotency: second void → `already_voided`
- ✅ Audit log records every void with proper before/after
- ✅ With `require_auth=true`: no PIN → `requires_authorization`
- ✅ With `require_auth=true`: wrong PIN → `invalid_pin`
- ✅ With `require_auth=true`: right PIN → succeeds, audit shows `auth_method='pin'`

---

## 4. Next: Stage B-3 (frontend wiring)

After B-1 + B-2 both pass, all 4 high-risk RPCs are PIN-gated server-side.
Stage B-3 wires the PIN modal into the UI buttons that call them:

| Page | Function/Button | RPC | Required uploads |
|---|---|---|---|
| folio.html | extras × delete | `sbp_booking_extras_remove` | Need latest folio.html |
| folio.html | payment × void | `sbp_folio_payment_void` | (same) |
| bookings.html | Cancel Booking button | `sbp_bookings_cancel` | Have it (line 686, 690, 787) |
| bills.html | Void Bill button | `sbp_bill_void` (new) | Have it (line 1151) — also drops localStorage `requirePIN` shim |

Upload latest folio.html when ready and I'll do B-3 in one shot.
