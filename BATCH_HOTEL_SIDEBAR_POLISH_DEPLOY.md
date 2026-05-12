# Batch: Hotel Sidebar Polish (12 May 2026)

Triggered by screenshot review: the hotel sidebar had too much retail
flavor — POS Admin, Stock, Suppliers, Recurring, Bill Templates all
visible despite being irrelevant to a hotel's daily flow.

**Decision (Vinay):** safe/reversible path.
- Bill Templates removed from sidebar nav permanently (page file kept on disk)
- POS Admin / Stock / Recurring / Suppliers tucked into "More" group on hospitality verticals (still 1 click away, just collapsed)

**Files changed (2):**
```
lib/sidebar-engine.js     ← +20 lines (4 catalog flags + 1 helper + _buildItems augmentation)
settings.html             ← -7 lines (Bill Templates menu item + fallback nav entry removed)
```

No SQL. Purely client-side.

---

## What changed in `lib/sidebar-engine.js`

1. **Bill Templates removed from `UNIVERSAL_CORE`** — the entry is
   commented out, not deleted, so the change is auditable. The
   `bill-templates.html` page file stays on disk and is unreachable
   from any nav.

2. **`more_for_verticals` flag added to 4 items:**
   - `pos-admin` (UNIVERSAL_CORE)
   - `stock` (UNIVERSAL_CORE)
   - `recurring` (MODULE_CATALOG)
   - `supplier` (MODULE_CATALOG)
   
   Value: `['hotel','homestay','pg_hostel','banquet','hospitality','day_room']`

3. **`_buildItems` augmented** to read `shopType` from
   `localStorage.sbp_shop` and route flagged items into the "More"
   group when the current shop_type matches the list.

The existing 022E "More ⚙️" collapsible group already handles the
rendering — these items now just join it dynamically based on
vertical.

## What changed in `settings.html`

Two removals of `bill-templates.html` references:
- The visible menu item under "Business Tools" section
- The hardcoded entry in the inline-sidebar fallback nav (line 1628 in original)

Other items (POS Admin, Stock, etc.) intentionally **kept** in the
settings menu — they're still accessible to non-hospitality verticals
who hit settings.html.

---

## Behavior on different verticals

### Hotel / Homestay / PG-Hostel / Banquet / Day-room / Generic Hospitality

**Primary visible:**
- 🏠 Home
- 🧾 Bills
- ➕ New Bill (FAB)
- 👥 Customers
- 📊 Reports
- 🌐 Website (if profile enabled)
- 📢 Marketing (if profile enabled)
- 💬 WhatsApp (if profile enabled)
- 💵 Cash Register (if profile enabled)
- 🛎️ Front Desk
- 🚶 Walk-in
- 🛏️ Rooms
- 📋 Folio
- 📅 Bookings
- ⚖️ Compliance
- ⚙️ Settings

**In "More ⚙️" collapsible:**
- 🛒 POS Admin           (auto-routed via more_for_verticals)
- 📦 Stock               (auto-routed via more_for_verticals)
- 🔁 Recurring           (auto-routed via more_for_verticals)
- 🏭 Suppliers           (auto-routed via more_for_verticals)
- 👨‍👩‍👧 Team             (022E)
- 🔒 Authorized Users    (022E)
- 📋 Audit Log           (022E)
- 💎 Plans               (022E)

### All other verticals (kirana, retail, restaurant, salon, etc.)

Unchanged. They still see POS Admin / Stock / Recurring / Suppliers
in their normal positions. Bill Templates is gone from everyone (it
was the universal removal).

---

## Deploy

1. Push `lib/sidebar-engine.js` + `settings.html` via GitHub Desktop
2. Bump SW version (e.g. v1.5.29 → v1.5.30)
3. Hard-refresh

---

## Smoke test

### 1. As a hotel shop (e.g. Glitz & Glam, shop_type=day_room)

Open dashboard.html. Expected:
- Sidebar primary list has ~16 items (no more POS Admin / Stock /
  Recurring / Suppliers near the top)
- Click "More ⚙️" → expands → shows POS Admin, Stock, Recurring,
  Suppliers (4 hotel-routed items) + Team, Authorized Users, Audit
  Log, Plans (4 owner-only items) = 8 total
- Click each → navigates correctly

### 2. As a kirana/retail shop

Open dashboard.html. Expected:
- Sidebar shows POS Admin, Stock, Recurring, Suppliers in their
  normal positions (orders 55, 40, 90, 110)
- "More ⚙️" group only contains the 4 owner-only items (Team,
  Authorized Users, Audit Log, Plans)

### 3. Bill Templates is gone everywhere

Open settings.html. Scroll the Business Tools section. **No "Bill
Templates" menu item** anywhere.

Open the sidebar on any page. **No "🗂️ Templates" entry** in the
list.

Direct URL `/bill-templates.html` still loads if typed in (page
file kept on disk). This is the safe-path: undeleting later is
trivial (just put the catalog entry back).

### 4. Owner / Staff filtering still works

In console:
```js
localStorage.setItem('sbp_is_staff', '1');
location.reload();
```

The 4 owner-only items still disappear (Team, Authorized Users, Audit
Log, Plans). The "More" group, if now empty for a staff hotel session,
hides entirely.

```js
localStorage.removeItem('sbp_is_staff');
location.reload();
```

Owner view returns.

---

## Pass criteria

- ✅ Hotel sidebar primary list shows 16 items (down from ~20)
- ✅ More group on hotel has 8 items (4 hotel-routed + 4 owner-only)
- ✅ Bill Templates gone from settings page + sidebar everywhere
- ✅ Kirana/retail/etc. sidebars unchanged
- ✅ Owner/staff filtering still works
- ✅ No JS errors

---

## Reversibility

Both decisions can be undone trivially:

**To bring Bill Templates back:** uncomment the line in UNIVERSAL_CORE
and restore the menu item in settings.html. ~5 minutes.

**To move POS Admin / Stock / Recurring / Suppliers back to primary
on hotels:** delete the `more_for_verticals` arrays on those 4
catalog entries. ~2 minutes.

---

## Next priorities

Hotel UX cleanup batch done. Roadmap next-ups remain:
- 021B-C Hotel KPIs (occupancy / ADR / RevPAR) (~2h)
- 028A Print stylesheet audit (~2-3h)
- Vertical polishing (Salon stylists, Restaurant tables, Pharmacy)
- Pre-beta QA → BETA LAUNCH 🚀
