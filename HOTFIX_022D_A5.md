# Hotfix 022D-A.5 — keypad clicks not registering

**Symptom:** typing in the PIN field via keypad — nothing appears. PIN
input stays empty no matter how many digits you click.

**Root cause:** in v3 I added a `mousedown` handler with `preventDefault()`
on the keypad to prevent focus loss. In Chrome's Responsive Mode (touch
emulation), `mousedown.preventDefault()` SUPPRESSES the subsequent
`click` event entirely. So my click handler — which appends the digit
and updates the input value — was never firing.

**Fix:** removed the mousedown handler. The flicker we were worried
about (border-color transition on focus loss/regain) is irrelevant now
because v3 also removed the `transition` rule from the CSS — border
changes are instant either way.

**Files (1):**
```
lib/auth-pin.js   ← drop-in replace
```

**Deploy:**
1. Push `lib/auth-pin.js`
2. Bump SW (v1.5.20 → v1.5.21)
3. Hard-refresh + test typing

After this, the modal should fully work: type via keypad → dots appear
→ Authorize button verifies via RPC → resolves with user info. No
flicker, no broken input.
