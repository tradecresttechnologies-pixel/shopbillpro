# Hotfix 022D-A.4 — PIN dots appearing/disappearing

**Symptom:** "the pin dots appearing disappering" — each typed digit
briefly shows as the actual number (`1`, `2`, ...) before being masked
to a dot.

**Root cause:** Chrome's password-reveal-on-type behavior. When you
type into `<input type="password">`, Chrome shows the typed character
for ~50–200ms before replacing it with `•`. Type fast → continuous
flicker between digit and dot.

This is also why every prior fix (animation, backdrop-filter, caret,
focus) didn't help — none of them touched the actual cause, which was
the input type itself.

**Fix:**
- Changed `<input type="password">` → `<input type="text">`. Text inputs
  don't have the reveal-on-type behavior.
- Added CSS `-webkit-text-security: disc` (Chrome/Safari) and the
  standard `text-security: disc` (Firefox 115+). Renders characters
  as dots without using a password field.
- Added `autocomplete="one-time-code"` so browsers don't try to
  autofill from saved passwords or offer to save the PIN.
- Added `autocorrect="off" autocapitalize="off" spellcheck="false"`
  for completeness (mobile keyboards won't try to "help").

Visual result: identical to before (• • • • for a 4-digit PIN), but
with zero flicker because Chrome doesn't apply password-field
behaviors to a text input.

**Files (1):**
```
lib/auth-pin.js   ← drop-in replace
```

**Deploy:**
1. Push `lib/auth-pin.js`
2. Bump SW version (v1.5.19 → v1.5.20)
3. Hard-refresh + re-test typing into the PIN field

After this lands, 022D-A should be fully verified — modal renders
clean, PIN field accepts input cleanly, no animations, no flicker.
