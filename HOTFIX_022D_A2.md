# Hotfix 022D-A.2 — modal blink fix (CSS-lite)

**Symptoms:** auth-pin modal showed ghosted/doubled buttons, visible
"blinking" when rendered in Chrome's Responsive Mode emulator. The
inline diagnostic modal in the same context rendered cleanly, which
narrowed it to my own CSS.

**Causes (two stacked):**
1. **`backdrop-filter: blur(6px)`** — Chrome's compositor in Responsive
   Mode can repaint backdrop-filter regions on every layout pass,
   creating sub-pixel jitter that reads as "blink".
2. **`animation: sbpAuthSlide .25s ease-out`** on `.sbp-auth-sheet` —
   browsers sometimes re-fire keyframe animations when the parent's
   `display` changes or layout reflows, producing repeated slide-ins.

**Fix:**
- Removed `backdrop-filter`. The dark `rgba(8,10,18,.72)` overlay alone
  is enough visual separation from background content.
- Removed the slide-in animation. Modal now just appears via
  `display:none → flex` toggle. Snappy, no GPU work.
- Reduced `box-shadow` size slightly (12px/36px vs 24px/60px) — visually
  similar, lighter on the compositor.
- Added defensive `ensureModal()`: if for any reason two overlays
  exist in the DOM, it now picks the first one and removes the rest,
  so we can never have stacked overlays simultaneously.

**Files (1):**
```
lib/auth-pin.js   ← drop-in replace
```

**Deploy:**
1. Push `lib/auth-pin.js`
2. Bump SW version (e.g. v1.5.17 → v1.5.18) so PWA clients re-fetch
3. Hard-refresh + re-test the modal

Modal should now slide in instantly (no animation), stay rock-steady,
work identically in Responsive Mode and full Chrome windows.

**Note:** the snappy reveal (no animation) is arguably nicer for a
high-frequency interaction like PIN entry — operators want to authorize
fast, not wait for a fade-in. Visual polish can return later as a
plain CSS `opacity` transition once we're confident the foundation is
stable.
