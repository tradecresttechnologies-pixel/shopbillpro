# Batch 022D-C App Shell Integration

Wraps `authorized-users.html` and `audit-log.html` in the standard app
shell (left sidebar + mobile bnav + mobile drawer) so they integrate
visually with the rest of the app instead of opening as standalone
pages.

**Trigger:** Screenshots showed both pages rendering without the left
sidebar — operators lost their navigation context when visiting them.
"Page broken means page opens separately out of app, no sidebar
showing. The pages should open how other pages are opening."

**Pattern copied from:** `compliance.html` (which was identified as a
reference and uploaded). Same script load order, same CSS shell block,
same DOM placeholders, same 3 `SBPSidebar.render()` calls in init().

---

## What changed in each file

**Both `authorized-users.html` and `audit-log.html` got:**

1. **One new script tag** in head:
   ```html
   <script src="lib/sidebar-engine.js"></script>
   ```

2. **45-line CSS shell block** appended after the existing `#app` rule.
   Defines `#dsb` (desktop sidebar), `.bnav`/`.ni`/`.nav-fab` (mobile bottom
   nav), `.bnav-overlay` + `.bnav-drawer` + `.drawer-*` (mobile slide-out
   drawer), and the responsive media queries that hide/show each layer
   at the appropriate breakpoint (`#app{margin-left:220px}` ≥1024px,
   `#dsb{display:none}` <1024px, etc.).

3. **3 new DOM elements** after `</div>` closing `#app`:
   ```html
   <div class="bnav"></div>
   <div class="bnav-overlay" onclick="if(window.SBPSidebar)SBPSidebar._closeDrawer()"></div>
   <div class="bnav-drawer"></div>
   ```

4. **3 new `SBPSidebar.render()` calls** at the top of `init()`:
   ```js
   SBPSidebar.render({currentPage:'authorized_users', layout:'desktop'});
   SBPSidebar.render({currentPage:'authorized_users', layout:'mobile-bottom',  container:'.bnav'});
   SBPSidebar.render({currentPage:'authorized_users', layout:'mobile-drawer', container:'.bnav-drawer'});
   ```

   For audit-log.html, `currentPage:'audit_log'` (underscore — matches
   the MODULE_CATALOG code, which is what the `.active` highlight check
   uses).

---

## Files in this batch

```
authorized-users.html   ← 757 → 815 lines (+58)
audit-log.html          ← 686 → 745 lines (+59)
```

No SQL, no new files, no library changes. Just two HTML files getting
shell-wrapped.

---

## Deploy

1. Push both files via GitHub Desktop
2. Bump SW version (e.g. v1.5.28 → v1.5.29)
3. Hard-refresh

---

## Smoke test

### 1. Desktop ≥1024px

Open `authorized-users.html` on a wide screen. Expected:
- Left rail: ShopBill Pro logo, full navigation (Home, Bills, New Bill,
  Customers, Stock, Reports, POS Admin, Marketing, WhatsApp, ...,
  Settings, **More ⚙️** → expanded by default since current page is
  inside it, with **🔒 Authorized Users** highlighted in orange)
- Main content area to the right with the Authorized Users page
- Logout button + version at bottom of rail

Click any other sidebar item (e.g. Bills, Customers, Settings) →
navigates to that page, sidebar persists.

Repeat for `audit-log.html` — same shell, with **📋 Audit Log**
highlighted.

### 2. Sidebar "More" toggle

Click "More ⚙️" in the sidebar to collapse it → Authorized Users
and Audit Log items hide. Click again to expand. State persists across
page navigation (it's saved in `localStorage.sbp_sidebar_more_open`).

### 3. Mobile <1024px

Open the same pages on a phone-width viewport. Expected:
- Bottom nav with 5 items (Home, Bills, +New Bill, Marketing, More ☰)
- Top of content shows the page's own topbar (Authorized Users / Audit Log)
- Tap "More ☰" in bnav → slide-out drawer from right side shows full
  menu including Authorized Users + Audit Log
- Tap any drawer item → drawer closes, navigation happens

### 4. Hindi toggle still works

Click the `अ` button in the page topbar → all labels switch to Hindi,
including the sidebar items (Team → टीम, Authorized Users → अधिकृत
उपयोगकर्ता, etc.). The sidebar engine has the bilingual rules baked in.

### 5. Theme toggle

Click 🌙/☀️ in page topbar → theme switches across the entire shell
(including sidebar). Persisted in `localStorage.sbp_theme`.

### 6. Active highlighting

When viewing `authorized-users.html`, the sidebar entry "🔒 Authorized
Users" should show with the orange `.active` background. Same for
`audit-log.html` with "📋 Audit Log".

If neither shows as active, check:
- `lib/sidebar-engine.js` is loaded (Network tab in DevTools)
- Migration 034 from 022D Link Wiring batch was run (the entries need
  to be in `sbp_module_profiles` for the user's shop type)

---

## Pass criteria

- ✅ Both pages show the left sidebar on desktop (≥1024px)
- ✅ Both pages show bottom nav + drawer on mobile (<1024px)
- ✅ The current page is highlighted as active in the sidebar
- ✅ "More ⚙️" group auto-expanded when on a More-group page
- ✅ Navigation between pages keeps sidebar persistent
- ✅ Hindi / theme / lang toggles work normally
- ✅ No JS errors in console
- ✅ Existing page features (Add User, filters, modals, etc.) work
  unchanged — shell integration is purely additive

---

## Notes

**Why `currentPage:'authorized_users'` (underscore) and not
`'authorized-users'` (hyphen)?**

`MODULE_CATALOG` keys use underscores (`authorized_users`, `audit_log`).
The active-state check is `m.module_code === currentPage`, so the
string passed to render() must match the catalog key exactly. If the
filename is hyphen and we let the engine auto-derive `currentPage`
from the URL, we'd get `'authorized-users'` (hyphen) and the active
class would never fire. Passing the underscore form explicitly fixes
that.

**Why is this batch separate from 022D Link Wiring?**

The link-wiring batch added entries to other pages' menus (Settings,
Reports, sidebar catalog). This batch adds the app shell INTO the new
pages themselves. Two different directions. Should have been combined
originally — flagged for future planning.

---

## After this lands

The 022D + 022E + Link Wiring story is fully complete and visually
consistent across the app. Operators can:

- Navigate to Authorized Users / Audit Log from sidebar, Settings menu,
  or Reports topbar
- Stay inside the app shell with consistent navigation chrome
- Toggle theme/language as on any other page

Next from the master roadmap:
- 021B-C Hotel KPIs (~2h)
- 028A Print stylesheet audit (~2-3h)
- Vertical polishing (Salon stylists, Restaurant tables, Pharmacy, etc.)
- Pre-beta QA → BETA LAUNCH 🚀
