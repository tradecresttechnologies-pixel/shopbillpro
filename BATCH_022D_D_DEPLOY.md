# Batch 022D-D — Server-side PIN-gated bill actions (security)

**Scope:** Closes the security hole in `bills.html` where 5 sensitive
actions were gated only by a client-side PIN check (localStorage
plaintext comparison, bypassable in dev tools). All 5 now run through
server RPCs with proper PIN verification + audit logging.

## What changes

### The 5 actions migrated

| Action | Old (insecure) | New (server-verified) |
|---|---|---|
| Edit bill | `editBill()` → local PIN compare → redirect | `editBill()` → SBPAuth → `sbp_bill_edit_start` → server logs edit_start → redirect |
| Reopen bill | `reopenBill()` → local PIN → client mutations | `reopenBill()` → SBPAuth → `sbp_bill_reopen` (atomic: status + stock + ledger) |
| Delete bill | `deleteBill()` → local PIN → `_sb.from('bills').delete()` | `deleteBill()` → SBPAuth → `sbp_bill_delete` (atomic: bill + items + stock + ledger) |
| Void item | `voidItem()` → local PIN → mutate `bill_items` array | `voidItem()` → SBPAuth → `sbp_bill_void_item` (atomic: soft-void + stock + recompute) |
| Delete item | `deleteItem()` → local PIN → splice array | `deleteItem()` → SBPAuth → `sbp_bill_delete_item` (atomic: delete + stock + recompute) |

### The security improvement

**Before:** A user with browser dev tools could:
- Read `localStorage.sbp_manager_pin` (plaintext)
- Call `_doDeleteBill('any-id')` directly, bypassing the modal
- Modify the modal's PIN check return

**After:**
- PIN is verified server-side by `sbp_verify_pin` (bcrypt against
  `manager_pins.pin_hash` / `sbp_authorized_users.pin_hash`)
- The verified PIN is then re-checked inside the RPC before any
  mutation runs
- All mutations are atomic transactions
- Audit log is written server-side via `sbp_audit_log_write` —
  cannot be tampered with from the client

## Files

```
db/migrations/038_bill_pin_gated_actions.sql   ← 5 RPCs + 2 helpers (598 lines)
bills.html                                     ← +50 lines net (1566 → 1616)
lib/auth-pin.js                                ← unchanged (already shipped 022D-A)
```

## ⚠️ Deploy order

**1. Run SQL migration 038 in Supabase SQL Editor first.**

Verify after running:
```sql
SELECT proname FROM pg_proc
 WHERE proname LIKE 'sbp_bill_%'
 ORDER BY proname;
```
Should list: `sbp_bill_delete`, `sbp_bill_delete_item`,
`sbp_bill_edit_start`, `sbp_bill_reopen`, `sbp_bill_void_item`.

Plus the helpers: `_sbp_bill_recompute_totals`,
`_sbp_bill_restore_stock`.

**2. Push `bills.html`** (with the script tag for auth-pin.js)

**3. Make sure `lib/auth-pin.js` is already deployed** (it should be
from batch 022D-A — verify by `view-source` on the live URL)

**4. Bump SW** v1.5.33 → v1.5.34

**5. Hard-refresh** the app.

## Smoke tests

### 1. PIN verification works server-side
- Open Bills, click any bill, try "Delete Bill"
- Modal appears (from auth-pin.js, NOT the old `#pin-modal`)
- Enter the correct PIN → server verifies → bill deleted
- Enter wrong PIN 3 times → modal closes with "PIN invalid"

### 2. Old localStorage PIN no longer works
- Open dev tools, set `localStorage.setItem('sbp_manager_pin', '9999')`
- Try Delete Bill, enter `9999`
- ❌ Should be **rejected** with "PIN invalid (server check failed)"
- (Compare: before this batch, that would have succeeded)

### 3. Direct console bypass no longer works
- Open dev tools, type: `await editBill('some-bill-id')`
- Should still open the PIN modal (no client-side bypass)
- The old `_doDeleteBill` etc. helpers no longer exist

### 4. Atomic operations
- Delete a bill with stock-tracked products + outstanding balance
- Verify in Supabase:
  - Bill row gone (`SELECT * FROM bills WHERE id = ?`)
  - bill_items rows gone
  - Stock restored on `products.stock_qty` for each non-voided item
  - Customer ledger reversed by the outstanding balance
  - One audit_log entry with action=`bill.delete`

### 5. Last-active-item guard
- Open a bill with one active item (others voided)
- Try to void or delete the last active item
- Should be **rejected** with "Cannot void/delete the last active item"
- (Server enforces this — client also pre-checks for UX)

### 6. Offline behavior
- Disconnect from network
- Try any of the 5 actions
- Should toast "🌐 This action needs internet" without opening the modal
- (Security-critical actions don't run offline)

### 7. Audit log captures everything
- Do each of the 5 actions on different bills
- Navigate to Audit Log page
- Filter by action codes: `bill.edit_start`, `bill.reopen`,
  `bill.delete`, `bill.void_item`, `bill.delete_item`
- Each entry should have:
  - `recorded_at` set
  - `auth_method` = `pin`
  - `user_name` = the verified manager's name
  - `target_id` = the bill or item ID
  - `before_data` / `after_data` snapshots (for void/delete/reopen)

## ⚠️ Heads-up — `voidBill` is NOT in this batch

`bills.html` has 6 PIN-gated actions total, but memory specified 5:
edit_bill, reopen_bill, delete_bill, void_item, delete_item.

The 6th — **`voidBill`** (soft-delete a whole bill, status='voided')
— is still using the legacy client-side PIN compare. If you want it
migrated too, it's a quick follow-up (the RPC pattern is now
established). Suggested name: `sbp_bill_void` (status='voided' +
voided_at=now() + stock restore + ledger reversal).

Flag if you want it done; otherwise it stays as-is for now.

## Backward compatibility

The legacy PIN modal HTML (`#pin-modal`) and legacy functions
(`requirePIN`, `verifyPIN`, `closePINModal`, `getManagerPINs`,
`logAudit`) are **kept** in bills.html. They're still used by:
- `voidBill` / `_doVoidBill` (not in 022D-D scope)
- Some `logAudit` calls in legacy flows

This way nothing else in the file breaks, and we can clean these up
in a future batch once `voidBill` is also migrated.

## Known limitations (Phase 2 considerations)

1. **Edit security is partial.** `sbp_bill_edit_start` verifies the
   PIN + logs the start, but the actual edit happens via `billing.html`
   save (which relies on RLS for security). A full token-based edit
   flow with server-side validation of saves would be a Phase 2
   improvement.

2. **Sync prerequisite for items.** Voiding/deleting items needs
   `bill_items.id` (the server UUID). If a bill was created offline
   and hasn't synced yet, items have local IDs only, and the toast
   says "Item missing server ID — sync this bill first". This is
   correct behavior (you can't audit-log-protect what isn't on the
   server), but worth flagging to users via UX copy.

3. **Stock-restore is best-effort.** The server tries to update
   `products.stock_qty` but doesn't fail the void/delete if the
   product table or column doesn't exist (defensive `EXCEPTION`
   handler). This protects against schema-drift bugs but means a
   silent stock miss is possible. Audit log will still capture the
   action regardless.

## Next priorities (after this lands)

- **028A** Print stylesheet audit (~2-3h)
- **022D-E** (optional) Migrate `voidBill` to server RPC
- Vertical polish round
- Pre-beta QA → BETA LAUNCH 🚀
