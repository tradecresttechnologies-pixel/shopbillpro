# Batch 022D-F — Legacy PIN code cleanup

**Scope:** Pure cleanup. Removes ~143 lines of orphaned client-side
PIN code from `bills.html` that became dead after 022D-D + 022D-E
migrated all 6 sensitive actions to server RPCs. Zero functional
change — only deletion.

## What was removed

### HTML
- `<div class="pin-overlay" id="pin-modal">` (the entire modal block)

### CSS
- `.pin-overlay`, `.pin-overlay.open`
- `.pin-box`
- `.pin-title`, `.pin-sub`
- `.pin-input`, `.pin-input:focus`
- `.pin-error`
- `.pin-btns`

### JS — 7 dead functions
- `requirePIN(action, callback)` — old gate (now `SBPAuth.requirePIN`)
- `verifyPIN()` — old client-side PIN compare
- `closePINModal()`
- `getManagerPINs()` — read PINs from localStorage in plaintext
- `getPinUser()`
- `logAudit(action, details)` — old client-side audit writer (now `sbp_audit_log_write` server-side)
- `recalcBillTotals(b)` — was zero callers even before this batch

### JS — state
- `let _pinCallback = null`
- `let _pinAttempts = 0`
- `let _lastPinUser = null`

## Pre-cleanup audit (confirmed all orphan)

Before deleting anything, ran a full caller audit:

| Identifier | Callers outside the dead block |
|---|---|
| requirePIN | 0 (`SBPAuth.requirePIN` is a different function in lib) |
| verifyPIN | 0 (only HTML onclick in `#pin-modal` which is also removed) |
| closePINModal | 0 (only HTML onclick in `#pin-modal`) |
| getManagerPINs | 0 (only called by `requirePIN` / `verifyPIN`) |
| getPinUser | 0 (only called by `logAudit`) |
| logAudit | 0 (only called by `verifyPIN`) |
| recalcBillTotals | 0 (no callers anywhere) |

All identifiers were self-referentially dead — safe to remove.

## Files

```
bills.html   ← 1569 → 1426 lines (-143)
```

No SQL. No new JS. No new CSS.

## Deploy

1. Push `bills.html`
2. Bump SW v1.5.35 → v1.5.36
3. Hard-refresh

## Smoke tests

This batch is functionally identical to 022D-E. Re-run the existing
smoke tests to confirm nothing broke:

1. **Open the Bills page** — should render normally, sidebar visible, bills list loads
2. **Open a bill preview** — preview modal opens with action buttons
3. **Try each of the 6 PIN-gated actions:**
   - Edit Bill → PIN modal (from auth-pin.js) opens → server verifies → opens editor
   - Reopen Bill → PIN modal → server reopens
   - Delete Bill → PIN modal → server deletes
   - Void Bill → PIN modal → server soft-voids
   - Void Item (from preview) → PIN modal → server voids item
   - Delete Item (from preview) → PIN modal → server deletes item
4. **Verify the old PIN modal is gone:**
   - Inspect element on the page — `#pin-modal` should not exist
   - DevTools console: `typeof requirePIN` → `'undefined'`
   - DevTools console: `typeof logAudit` → `'undefined'`

If anything functionally regresses (action stops working, button breaks),
that means a caller was missed. Roll back to 022D-E `bills.html` and tell me.

## File size comparison (across the 022D-X arc)

| Version | bills.html lines | What changed |
|---|---|---|
| Pre-022D | 1566 | Original — 5 client-side PIN-gated actions, insecure |
| 022D-D | 1616 (+50) | 5 actions migrated to server RPCs |
| 022D-E | 1569 (-47) | voidBill (6th action) migrated |
| **022D-F** | **1426 (-143)** | **Legacy PIN code removed** |

Net change from pre-022D → 022D-F: **-140 lines, +full security**.

## What's left in bills.html

After this cleanup:
- ✅ 6 server-RPC-backed bill actions
- ✅ Single PIN gate via `SBPAuth.requirePIN()` (from lib/auth-pin.js)
- ✅ Single audit write path via `sbp_audit_log_write` (server-side)
- ✅ No client-side PIN code anywhere
- ✅ No reads of `localStorage.sbp_manager_pin` (the legacy PIN store)

## Next priorities

- **028A** Print stylesheet audit (~2-3h) — highest-value pre-beta
- Vertical polish round
- Pre-beta QA → **BETA LAUNCH** 🚀
