# Hotfix — compliance.html print mode

**Issue:** After the v2 sidebar hotfix, clicking Print on compliance.html
included the sidebar (#dsb), drawer, overlay, AND the desktop margin-left:220px
shift in the printout. So you got the sidebar shoved into the left margin
instead of a clean full-width A4 report.

**Root cause:** The page had a proper `@media print` stylesheet from the start
(hides .topbar / .tabs / .toolbar etc., switches to A4 landscape, paints a
print-only letterhead + signature block at bottom). But when I added the
sidebar markup in the v2 hotfix, I forgot to extend the print rules to
also hide #dsb / .bnav-drawer / .bnav-overlay AND reset #app margins.

**Fix (one-line CSS change):**

```css
/* Before */
.topbar,.tabs,.toolbar,...,.bnav,.btn-pri,.btn-sec{display:none!important}
#app{max-width:100%;padding:0;margin:0}

/* After */
.topbar,.tabs,.toolbar,...,.bnav,.bnav-drawer,.bnav-overlay,#dsb,.btn-pri,.btn-sec{display:none!important}
#app,#app *{box-shadow:none!important}
#app{max-width:100%!important;width:100%!important;padding:0!important;margin:0!important;min-height:0!important}
```

Added `!important` so the print rule wins against the `@media(min-width:1024px)`
desktop-shift rule (which uses `!important` on `margin-left:220px`).

**Files in this hotfix (1):**

```
compliance.html       ← drop-in replace
```

**Deploy:** GitHub Desktop → replace this file → push → hard-refresh.

**What you should see when clicking Print now:**
- Browser's print preview opens A4 landscape
- White background, black ink
- Clean letterhead at top: shop name + address + GSTIN + period + total + timestamp
- The data table fills the full page width (no sidebar pushing it)
- Signature block at bottom: Manager / Owner / Date+Stamp lines
- All app chrome (sidebar, topbar, tabs, toolbar, status bar, action buttons) hidden
