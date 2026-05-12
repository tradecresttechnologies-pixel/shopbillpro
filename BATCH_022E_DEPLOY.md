# Batch 022E — Vertical-Aware Sidebar (role-gating + "More" overflow)

**Prerequisites:** 022D fully deployed (foundation, RPCs, frontend
wiring, link wiring).

**Scope:** Single file change. Two narrow additions to the sidebar
engine:

1. **Owner-only filtering** — security-sensitive menu items hidden
   from non-owner accounts (cashier / manager / viewer).
2. **"More ⚙️" collapsible group** — admin/config items tuck under
   a single expandable section in the desktop sidebar to keep the
   main nav tight.

---

## What's in this batch

**Files (1):**
```
lib/sidebar-engine.js   ← +74 lines
```

**No SQL.** Everything client-side.
**No HTML page changes.** All pages that load the sidebar engine pick
up the new behavior automatically.

---

## Behavior changes

### Owner-only filtering

Items now flagged `owner_only: true` in `MODULE_CATALOG`:
- 👨‍👩‍👧 **Team**
- 🔒 **Authorized Users**
- 📋 **Audit Log**
- 💎 **Plans**

For staff accounts (where `localStorage.sbp_is_staff === '1'`), these
four items are **filtered out** of the sidebar entirely. The pages
themselves remain reachable by URL (server-side RPCs enforce owner
checks and return Access Denied) — but a cashier never sees the menu
entries.

This addresses the role-gating TODO flagged at the end of 022D link
wiring.

### "More ⚙️" collapsible group

The same four items are also flagged `more_group: true`. In the
desktop sidebar, they're collapsed under a single expandable row:

```
🏠 Home
🧾 Bills
➕ New Bill   (FAB)
👥 Customers
📦 Stock
📊 Reports
🛒 POS Admin
🌐 Website
📢 Marketing
💬 WhatsApp
…
⚙️ Settings
⚙️ More ›       ← click to expand
   👨‍👩‍👧 Team
   🔒 Authorized Users
   📋 Audit Log
   💎 Plans
```

State persisted in `localStorage.sbp_sidebar_more_open`. The group
**auto-opens** if the current page is inside it (so navigating to
e.g. `audit-log.html` shows the expanded state on arrival, not a
collapsed sidebar with no apparent "active" item).

### What didn't change

- **Mobile bottom-nav** — unchanged (still the 5-slot picker)
- **Mobile drawer** — unchanged (full list, no overflow)
- **Universal core** — never gated, never tucked into More
- **Server profile fetch** — same RPC, same cache
- **CSS in your existing pages** — no changes; new CSS is injected at
  runtime via `_injectStyles()` (same pattern as bilingual rules)

---

## Edge cases handled

| Case | Behavior |
|---|---|
| Staff account viewing the sidebar | More group is empty → group hidden entirely |
| `localStorage.sbp_is_staff` undefined or throws | Defaults to owner (safer; server-side still enforces) |
| Current page is in More group | Group auto-opens on render |
| User toggles More open / nav to another page | State persists via localStorage |
| `_isOwner()` returns wrong value | Server RPCs still gate access (no privacy leak) |

---

## Deploy

1. Push `lib/sidebar-engine.js` via GitHub Desktop
2. Bump SW version (e.g. `v1.5.26` → `v1.5.27`) so PWA clients re-fetch
3. Hard-refresh

No backend changes needed.

---

## Smoke test

### 1. As owner — More group visible & functional

Sign in as the shop owner (the default — `sbp_is_staff` not set).
Open any page with the sidebar (e.g. `dashboard.html`).

Expected: scroll to the bottom of the sidebar. You should see:
- Normal universal items (Home, Bills, Customers, Stock, Reports, ...)
- Settings (the universal-core ⚙️)
- **A new "⚙️ More ›" row** below Settings
- Click it → arrow rotates 90°, four items slide in: Team, Authorized
  Users, Audit Log, Plans

Click any of the four → navigates correctly. Return to dashboard,
sidebar should still have More open (state persisted).

### 2. As owner — More group auto-opens when on a "More" page

In another tab, navigate directly to `audit-log.html`. The sidebar
should render with the More group **already expanded** (and Audit
Log highlighted as active).

### 3. As staff — owner-only items hidden

In DevTools console:
```js
localStorage.setItem('sbp_is_staff', '1');
location.reload();
```

Expected: the More group is now **not visible** at all (no items =
no group). All four owner-only items are gone. The rest of the
sidebar is unchanged (Marketing, WhatsApp, Cash Register, Supplier,
etc. still there).

Try navigating to `/audit-log.html` directly — the page itself shows
"Access denied" because the server-side RPC enforces ownership.

### 4. Reset

```js
localStorage.removeItem('sbp_is_staff');
location.reload();
```

Sidebar returns to owner view with the More group.

### 5. State persistence

As owner:
- Click More → it opens
- Navigate to another page (e.g. click Reports)
- Sidebar renders with More **still open**
- Click More again → it closes
- Navigate elsewhere → still closed

### 6. Test harness (optional, for local verification)

The zip includes `test-harness.html` — a standalone page that
demonstrates the role gating and More toggle without needing
Supabase auth or a real shop. Open it as a file (or serve via
`python3 -m http.server`) to verify the lib in isolation.

---

## Pass criteria

- ✅ Owner sidebar shows the More ⚙️ row with 4 items inside
- ✅ Clicking More toggles the items open/closed with arrow rotation
- ✅ State persists across page navigation
- ✅ When on a More page, the group auto-opens
- ✅ Staff (`sbp_is_staff=1`) sees no More group, no Team/Auth/Audit/Plans
- ✅ Mobile drawer and bnav unaffected
- ✅ No errors in console

---

## What this closes

After this lands, the sidebar story from 022D is fully tied off:
- Authorized Users + Audit Log reachable from Settings, Reports, and
  the global sidebar (links wired in 022D link wiring batch)
- Cashier/manager accounts no longer see owner-only menu entries
- Sidebar stays uncluttered via the More overflow
- Server-side RPCs continue to enforce ownership regardless of UI

---

## Next priorities from master roadmap

- **021B-C** Hotel KPIs (occupancy / ADR / RevPAR) — ~2h
- **028A** App-wide print stylesheet audit — ~2-3h
- Vertical polishing (Salon stylists, Restaurant tables, Pharmacy, etc.)
- Pre-beta QA → **BETA LAUNCH** 🚀

Ready for whichever you want next.
