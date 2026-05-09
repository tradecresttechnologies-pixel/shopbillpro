# Hotfix v2 — Sidebar styling on 3 new pages

**Issue (you reported):** After v1 hotfix, sidebar items rendered but
unstyled — flowing inline as plain underlined links across the top of
front-desk.html, walk-in.html, compliance.html. Other pages (rooms,
bookings, customers) rendered the sidebar correctly.

**Root cause:** The `lib/sidebar-engine.js` library outputs the sidebar
HTML markup (the `<a class="dsb-item">…</a>` items, drawer skeleton, etc.)
but does NOT inject the CSS that *positions* and *styles* them. Each page
that uses the sidebar must include its own copy of the styling block
(`#dsb { position:fixed; left:0; … }`, `.dsb-item { display:flex; … }`,
`.bnav-drawer`, `.drawer-item`, etc.).

That's the convention rooms.html / bookings.html / customers.html follow,
but I missed it in v1 — I only added the layout-shift `#app` margins, not
the actual sidebar/bnav/drawer styles.

**Fix:** Lifted the full ~45-line sidebar styling block verbatim from
rooms.html (lines 117-163) and inserted it into all 3 pages, replacing
my partial layout-shift block. Now they have:

- `#dsb` fixed left, 220px wide, hidden on screens <1024px
- `.dsb-item` flex layout, hover state, active state, FAB variant
- `.bnav` mobile bottom nav with active indicator dash
- `.bnav-drawer` slide-out drawer with overlay backdrop
- `.drawer-item` styled drawer entries
- All responsive breakpoints (mobile / tablet / desktop)
- walk-in.html ALSO gets `.sticky-bar{left:220px!important}` on desktop
  so the bottom CTA bar sits to the right of the sidebar

**Files in this hotfix (3):**

```
front-desk.html       ← drop-in replace
walk-in.html          ← drop-in replace
compliance.html       ← drop-in replace
```

No SQL changes, no sidebar-engine.js changes.

**Deploy:** GitHub Desktop → replace these 3 files → push → hard-refresh.

**What you should see:**
- Sidebar appears on left ≥1024px, identical styling to rooms.html
- Active page highlighted in amber (Front Desk / Walk-in / Compliance)
- On mobile (<1024px), sidebar hidden, bottom bar visible
- Tap bottom bar's "More" → slide-out drawer with full menu

If anything still looks off, send a screenshot.
