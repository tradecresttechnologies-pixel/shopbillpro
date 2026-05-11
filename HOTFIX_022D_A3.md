# Hotfix 022D-A.3 — PIN field flicker

**Symptom:** After A.2 fixed the modal-wide blink, the PIN entry field
itself appeared to be flickering.

**Two causes (often combined):**
1. **Caret blink** — every browser <input> has a built-in cursor that
   blinks at ~1Hz. With `letter-spacing: 8px` between password dots,
   the caret line is very visible between them, reading as "blink".
2. **Focus-loss flicker on keypad press** — clicking a keypad button
   was momentarily transferring focus from the PIN input to the button
   itself, then my click handler refocused it. Combined with the
   `transition: border-color .15s` rule on the input, every keypad
   press fired a 0.3s border-color animation. Rapid typing = constant
   border pulse.

**Fix:**
- Added `caret-color: transparent` to the PIN input. Removes the
  blinking text cursor. PIN dots already give visual feedback that
  typing is registering — the caret was redundant + distracting.
- Added a `mousedown` handler on the keypad with `preventDefault()`.
  Stops the button from receiving focus on press, so the PIN input
  never loses focus, so the border-color transition never re-fires.
- Removed the `transition: border-color` rule (was making the issue
  visible if focus ever did shift; now it's a snap with no animation).

**Files (1):**
```
lib/auth-pin.js   ← drop-in replace
```

**Deploy:**
1. Push `lib/auth-pin.js`
2. Bump SW version (e.g. v1.5.18 → v1.5.19)
3. Hard-refresh + re-test
