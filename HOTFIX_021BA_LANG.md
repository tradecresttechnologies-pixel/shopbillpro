# Hotfix 021B-A.1 — Bilingual EN/HI rendering

**Issue:** Both English and Hindi labels rendering simultaneously (concatenated)
on `front-desk.html` and `walk-in.html`. Visible as `TODAYआज`, `Walk-inवॉक-इन`,
`Bookingsबुकिंग`, etc.

**Root cause:** Both pages use the standard `<span class="lang-en">…</span>
<span class="lang-hi">…</span>` markup but were missing the 4 CSS toggle rules
that hide the wrong-language span based on `<html lang="…">` (which is set by
`lang.js` from `localStorage.sbp_lang`).

**Fix:** Added the 4-rule CSS block to both pages:

```css
.lang-hi{display:none!important}
.lang-en{display:inline!important}
html[lang="hi"] .lang-hi{display:inline!important}
html[lang="hi"] .lang-en{display:none!important}
```

(Same pattern used by stock.html, dashboard.html, customer-history.html, etc.)

**Files in this hotfix (2):**

```
front-desk.html       ← drop-in replace
walk-in.html          ← drop-in replace
```

The SQL migration 026 and sidebar-engine.js from the v1 zip are unchanged —
no need to re-deploy those.

**Deploy:** GitHub Desktop → replace these 2 files → push → hard-refresh PWA.
