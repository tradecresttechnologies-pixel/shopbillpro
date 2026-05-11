# Hotfix 022D-A.1 — auth-pin.js stacked-modal flicker

**Bug:** Loading `lib/auth-pin.js` multiple times creates stacked overlay
DOM elements, all animating simultaneously → rapid blink.

**Cause:** The IIFE was creating fresh `style` + `overlay` elements on
every script execution. Dev workflows that cache-bust the script (or
accidental double `<script src>` includes in HTML) would each get their
own DOM. Class-toggling .open on multiple stacked overlays = visual
glitch.

**Fix:** At top of IIFE, remove any previous `.sbp-auth-overlay` and
`style[data-sbp-auth-pin]` elements. Mark the style tag with a data
attribute so cleanup can find it. New load → clean slate.

**Files (1):**
```
lib/auth-pin.js   ← drop-in replace
```

**Deploy:**
1. Push `lib/auth-pin.js` via GitHub Desktop
2. **Hard-refresh** the test page (Ctrl+Shift+R) to drop all stacked instances
3. Re-test the modal — should slide up cleanly with no flicker
