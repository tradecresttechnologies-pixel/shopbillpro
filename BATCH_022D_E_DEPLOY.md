# Batch 022D-E — Migrate `voidBill` to server RPC

**Scope:** The 6th and last PIN-gated bill action moves to server-side
verification. After this batch, **every** sensitive bill operation in
`bills.html` runs through the server-RPC + PIN-verify + audit-log path.
The client-side localStorage PIN compare is now completely orphaned.

## What changes

| Action | Before | After |
|---|---|---|
| Void bill | `voidBill()` → local PIN compare → client mutations | `voidBill()` → SBPAuth → `sbp_bill_void` (atomic: status='Voided' + stock + ledger + audit) |

Soft-delete behavior unchanged: bill row stays, `status='Voided'`,
`voided_at=now()`, `voided_by=<verified user name>`, stock restored,
customer ledger reversed if credit was outstanding.

## Files

```
db/migrations/039_bill_void_action.sql   ← 1 new RPC (133 lines)
bills.html                                ← -47 lines net (1616 → 1569)
```

Reuses `_sbp_bill_restore_stock(p_bill_id)` helper from migration 038.

## ⚠️ Deploy order

1. **Run SQL migration 039** in Supabase SQL Editor

   Verify:
   ```sql
   SELECT proname FROM pg_proc
    WHERE proname = 'sbp_bill_void';
   ```

2. **Push `bills.html`**

3. **Bump SW** v1.5.34 → v1.5.35

4. **Hard-refresh**

## Smoke tests

### 1. The exploit is now closed for ALL 6 actions
```js
// In dev tools:
localStorage.setItem('sbp_manager_pin', '9999');
// Now try Void Bill with PIN 9999
// ❌ Rejected — "PIN invalid (server check failed)"
```

### 2. Functional smoke
- Void a paid bill → status='Voided', stock restored, no ledger change
- Void a Credit/Partial bill → status='Voided', stock restored, **ledger reversed by `balance_due`**
- Try to void an already-voided bill → "Item already voided" error (server guard)
- Try to void without internet → "🌐 This action needs internet"

### 3. Audit log captures it
```sql
SELECT action, details, created_at
  FROM audit_log
 WHERE action = 'bill.void'
 ORDER BY created_at DESC LIMIT 5;
```
Each row should have `before_data` (pre-void bill state) and
`after_data` (post-void state with `status: 'Voided'`).

## Now fully server-side

All 6 PIN-gated bill actions:

```
sbp_bill_edit_start    (022D-D)
sbp_bill_reopen        (022D-D)
sbp_bill_delete        (022D-D)
sbp_bill_void_item     (022D-D)
sbp_bill_delete_item   (022D-D)
sbp_bill_void          (022D-E) ← this batch
```

## Legacy PIN code — now fully orphaned but kept

The old client-side PIN system in `bills.html` (`requirePIN`,
`verifyPIN`, `closePINModal`, `getManagerPINs`, `getPinUser`,
`logAudit`, `recalcBillTotals`, plus `#pin-modal` HTML + CSS) is
now **completely dead code** — no functional code path reaches it.

It's left in place for this batch to minimize blast radius. Removing
it is a pure cleanup batch with no security implication. If you want
it cleaned out, that's **022D-F** — roughly:
- Remove `#pin-modal` HTML block + associated CSS
- Remove the 7 dead functions listed above
- Remove `_pinCallback`, `_pinAttempts`, `_lastPinUser` state
- Net: ~150 lines removed, zero functional change

Tell me when you want 022D-F and I'll ship it.

## Pre-beta security checklist — bills.html

- ✅ All bill mutations server-verified
- ✅ All bill mutations atomic
- ✅ All bill mutations audit-logged
- ✅ PIN never compared client-side
- ✅ PIN never stored as plaintext (server hash via bcrypt)
- ✅ Last-active-item guard server-enforced
- ✅ Stock restoration server-side (best-effort with exception handler)
- ✅ Customer ledger reversal server-side
- ✅ Offline = action refused with clear message

## Next priorities (unchanged)

- **028A** Print stylesheet audit (~2-3h)
- **022D-F** (optional) Legacy PIN cleanup
- Vertical polish round
- Pre-beta QA → **BETA LAUNCH** 🚀
