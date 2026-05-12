# Hotfix: Sidebar scroll consistency on More-group navigation

**Trigger:** "from more section few sidebar stable few moving upward when
clicking on that need to fix"

**Root cause:** The existing BATCH 013 scroll-persist hotfix saves &
restores sessionStorage scroll position on every render. But:

1. User is on a tall-sidebar page (hotel = ~16 items in primary list)
2. Their saved scroll position is 0 (they didn't scroll on that page)
3. They click "More ⚙️" → it expands, revealing items BELOW the visible area
4. They click one of those More items (say Plans)
5. New page loads. Saved scroll = 0 gets restored.
6. Plans is highlighted at the bottom of the sidebar — **below the visible area**
7. User sees a sidebar that looks like it "jumped upward" away from where they clicked

**Fix:** After restoring the saved scroll, check if `.dsb-item.active`
is actually in view. If not, `scrollIntoView({ block: 'nearest', behavior: 'auto' })`
to bring it into view. Already-visible items don't trigger any scroll
change. No animation (would be jarring on every page load).

**Files changed (1):**
```
lib/sidebar-engine.js   ← +30 lines (one comment block + an rAF check inside _wireScrollPersist)
```

No SQL. No HTML changes. Purely augments the existing scroll-persist function.

---

## How it behaves now

| Scenario | Before | After |
|---|---|---|
| Click Home (primary, top) | ✅ Sidebar stable | ✅ Sidebar stable |
| Click Bills (primary, top) | ✅ Sidebar stable | ✅ Sidebar stable |
| Click Reports (mid) | ✅ Sidebar stable (already visible) | ✅ Sidebar stable |
| Click Plans (More group, bottom) — saved scroll=0 | ❌ Plans below the fold, sidebar looks "stuck at top" | ✅ Auto-scrolled down so Plans is visible |
| Click Plans → then click Home | ❌ Home above the fold, sidebar still scrolled down | ✅ Auto-scrolled up so Home is visible |
| Click Audit Log (More group) | ❌ Below the fold | ✅ Visible |
| Navigate within already-visible primary nav | ✅ Sidebar stable | ✅ Sidebar stable (rAF detects "already visible" and skips) |

The key change: **after every page navigation, the active item is
always in view.** No more "where did my sidebar go?" feeling.

---

## Deploy

1. Push `lib/sidebar-engine.js`
2. Bump SW version (e.g. v1.5.30 → v1.5.31)
3. Hard-refresh

---

## Smoke test

### 1. The fix in action

a) Open `dashboard.html` (or any non-More page). Don't scroll.
b) Click "More ⚙️" to expand it.
c) Click "Plans" (or any More-group item).
d) After the page loads, look at the sidebar — **the active item
   should be visible**, not below the fold.

### 2. Reverse direction

a) From Plans, scroll the sidebar down if needed to see "Home" at top.
b) Click Home.
c) The sidebar should auto-scroll up so Home is visible. (Without the
   fix, the sidebar would remain scrolled down because that's where
   sessionStorage said to be.)

### 3. Hopping around between primary items

a) On dashboard.html, sidebar at top, click Bills.
b) Bills page loads, Bills is highlighted, sidebar still at top.
c) Click Customers.
d) Customers page loads, Customers is highlighted, sidebar still at
   top. (No spurious scrolling for items that were already visible.)

### 4. No animation, no flicker

The scroll-into-view uses `behavior: 'auto'` so it happens instantly.
You shouldn't see any "scroll animation" on page navigation — just
the sidebar appearing at the right position immediately.

---

## Pass criteria

- ✅ Active item visible after every navigation (primary OR more-group)
- ✅ No spurious scroll for items already in view
- ✅ No visible scroll animation on page load (instant scroll)
- ✅ Existing BATCH 013 scroll-persist behavior still works (scroll
  position remembered when you navigate to & back)
- ✅ No JS errors

---

## What's NOT in this fix

- **Toggle behavior:** clicking "More ⚙️" to open/close on the SAME
  page doesn't trigger scrollIntoView. That's by design — toggling on
  the current page is a user interaction, not a navigation. Auto-scrolling
  would feel intrusive.
- **Mobile drawer:** the drawer opens fresh each time and is already
  full-height scrollable; no scroll-position issue. The fix is desktop-only.
- **Mobile bnav:** fixed-position 5-slot picker; no scrolling at all.

---

## Next priorities

Sidebar UX now feels consistent. Roadmap next-ups remain:
- 021B-C Hotel KPIs (~2h)
- 028A Print stylesheet audit (~2-3h)
- Pre-beta QA → BETA LAUNCH 🚀
