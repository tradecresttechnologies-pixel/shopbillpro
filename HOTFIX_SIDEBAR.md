# Hotfix — Sidebar wiring on 3 new pages

**Issue:** `front-desk.html`, `walk-in.html`, and `compliance.html` rendered
without the global sidebar. They appeared as full-width, standalone pages
instead of slotting into the app shell like rooms.html, bookings.html etc.

**Root cause:** I included `<script src="lib/sidebar-engine.js"></script>` at
the top of each new page but forgot to actually call `SBPSidebar.render(...)`
in the page's `init()`, AND forgot to add the 3 DOM placeholders the engine
renders into:

```html
<div class="bnav"></div>             <!-- mobile bottom nav target -->
<div class="bnav-overlay" onclick="…"></div>   <!-- drawer backdrop -->
<div class="bnav-drawer"></div>      <!-- mobile slide-out drawer -->
```

The engine auto-creates `#dsb` (the desktop fixed-left sidebar) when needed,
so no placeholder is required for that one.

**Fix on each page (3 things):**

1. CSS — desktop layout shift block, mirroring rooms.html / bookings.html:
   ```css
   @media (min-width:1024px){
     #app{margin-left:220px!important;
          max-width:calc(100vw - 220px)!important;
          width:calc(100vw - 220px)!important}
     .bnav{display:none!important}
   }
   ```
   (walk-in.html also gets `.sticky-bar{left:220px!important}` so its bottom
   CTA bar doesn't sit underneath the sidebar.)

2. DOM — added the 3 placeholder divs near the bottom of each page.

3. JS — added 3 render calls at the top of each page's `init()`:
   ```js
   if(window.SBPSidebar){
     SBPSidebar.render({currentPage:'<page>', layout:'desktop'});
     SBPSidebar.render({currentPage:'<page>', layout:'mobile-bottom',  container:'.bnav'});
     SBPSidebar.render({currentPage:'<page>', layout:'mobile-drawer', container:'.bnav-drawer'});
   }
   ```
   currentPage = `front_desk` / `walk_in` / `compliance` respectively
   (matches the catalog keys in `lib/sidebar-engine.js`).

   Also removed front-desk.html's hardcoded `<nav class="bnav">…</nav>` —
   the engine now populates `<div class="bnav"></div>` from the catalog.

---

## Files in this hotfix (3)

```
front-desk.html       ← drop-in replace
walk-in.html          ← drop-in replace
compliance.html       ← drop-in replace
```

No SQL changes, no sidebar-engine.js changes, no other file changes.

## Deploy

GitHub Desktop → replace these 3 files → push → hard-refresh PWA
(or bump SW cache version).

## What you should see after deploy

- Sidebar appears on left of all 3 pages on desktop ≥1024px (same 220px wide
  panel as rooms.html / bookings.html), with `Front Desk`, `Walk-in`,
  `Compliance` entries highlighted when on those respective pages.
- On mobile, the global bottom nav appears at the bottom of the screen
  (not the hardcoded one I had on front-desk.html — the proper engine one
  with all hospitality items).
- Tapping the "More" item in mobile bottom nav opens the slide-out drawer
  with the full menu.
