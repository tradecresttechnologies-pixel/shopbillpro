# Batch 067 — Restaurant Vertical Fixes (+ POS UX overhaul)

## Deploy paths

```
NEW      db/migrations/067_restaurant_fixes.sql
REPLACE  lib/sidebar-engine.js
REPLACE  dashboard.html
REPLACE  menu.html                                  ← sidebar bootstrap
REPLACE  tables.html                                ← sidebar bootstrap
REPLACE  kitchen.html                               ← sidebar bootstrap
REPLACE  running-order.html                         ← sidebar bootstrap + POS UX overhaul
REPLACE  billing.html
```

Drop each file into the matching path in your repo, push, Vercel deploys.

## Deploy order

**SQL FIRST.** Run `db/migrations/067_restaurant_fixes.sql` in Supabase SQL
Editor *before* shipping the HTML/JS changes, or the new UI will hit
"function does not exist" errors.

```
Supabase Dashboard → SQL Editor → paste 067_restaurant_fixes.sql → Run
                  ↓
GitHub Desktop → commit + push 7 HTML/JS files → Vercel auto-deploys
```

---

## What's in this batch

### 🔥 The 3 issues you reported

| # | Problem | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | "Generate Bill redirects to POS but nothing appears, menu items don't auto-fetch" | `running-order.html` was forcing `?mode=pos` on the URL. `mode=pos` swaps billing.html's DOM to the POS-cart view — but the prefill code writes into manual mode's `#items-wrap` via `addItem()`. The items were being written to a DOM that wasn't visible. | **Removed `mode=pos`.** Billing page now stays in default (manual) mode where prefill works. Items show in the editable bill grid with name + qty + price + GST per row. |
| 2 | "Void/delete works without manager PIN" | `voidOrder()` was a plain `confirm()` followed by RPC call — no PIN check anywhere. | Now uses `SBPAuth.requirePIN({ action: 'restaurant.void_running_order', detail: 'Void Table T3 · 2 KOTs · 5 items', reason_hint: 'Why...' })` — same modal pattern as bills.html / bookings.html / folio.html. Server re-verifies via `sbp_verify_pin`. If `lib/auth-pin.js` fails to load, falls back to confirm() with a console warning — operator is never locked out. |
| 3 | "POS display needs proper categories + selection" | The page was a vertical list grouped by category header — fine for catalog browsing, terrible for fast tap-tap-tap order-taking. | **Category chips at the top** (scrollable horizontally, with per-category counts and an "All" chip) + **grid of tappable cards** below (entire card is the hit target, no separate "+" button). Custom item form is now collapsed by default — saves vertical space, click to expand. |

### 12 audit defects closed (from the prior batch — unchanged)

| Sev | Code | Defect |
|-----|------|--------|
| 🔥 | S1 | menu CRUD calls non-existent `sbp_services_upsert` (SQL §1) |
| 🔥 | S2 | bills show 0% GST because public RPC strips `gst_rate` (SQL §2 + UI) |
| 🔥 | S3 | order pane `display:none` on phones — waiters blocked (tabbed switcher) |
| ⛔ | P1 | void left pending KOTs cooking in KDS (SQL §3) |
| ⛔ | P2 | strand — closing billing tab left table occupied (SQL §4 + UI) |
| ⛔ | P3 | bill save created duplicate ghost KDS row |
| ⛔ | P5 | bills had no FK back to their table (SQL §5 + billing) |
| ⚠️ | W1 | sidebar Tables link was dead |
| ⚠️ | W2 | dashboard food: Tables coming-soon stub, no Menu |
| ⚠️ | W3 | wrong sbp_module_profiles rows for food/subscription (SQL §6) |
| ⚠️ | W4 | double banner on RO → billing redirect |
| ⚠️ | W6 | duplicate KOT button on RO-sourced bills |
| ⚠️ | W8 | addItem prefill key mismatch — items had no name/qty/price |
| 🩹 | HF | restaurant pages blinked/showed Loading on navigation (sidebar bootstrap on menu/tables/kitchen/running-order) |

---

## What the new running-order screen looks like

```
┌──────────────────────────────────────────────────────┐
│ Table T1   🟢 Open   00:12     ← Tables              │
├──────────────────────────────────────────────────────┤
│ [📋 Menu]  [🛒 Order · 5]      (mobile-only tabs)    │
├──────────────────────────────────────────────────────┤
│ MENU PANE                      │  ORDER PANE         │
│ ┌────────────────────────────┐ │                     │
│ │ [All·24] [Starters·6]      │ │ 🍽️ Current Round   │
│ │ [Mains·10] [Drinks·5] →    │ │ ┌─────────────────┐ │
│ └────────────────────────────┘ │ │ Paneer Tikka  2 │ │
│ ┌─ search menu items ────────┐ │ │ Butter Naan   3 │ │
│ │ 🔍                         │ │ └─────────────────┘ │
│ └────────────────────────────┘ │  Note: extra spicy  │
│ ┌──────┐ ┌──────┐ ┌──────┐    │  [🍳 Send to Kitchen]│
│ │Paneer│ │Butter│ │ Dal  │    │                     │
│ │Tikka │ │ Naan │ │Makh. │    │  PREVIOUS KOTS      │
│ │ ₹220 │ │ ₹40  │ │ ₹260 │    │  ┌─────────────────┐ │
│ │ +5%  │ │      │ │ +5%  │    │  │ Dosa     × 2    │ │
│ └──────┘ └──────┘ └──────┘    │  │ Coke     × 4    │ │
│ ┌──────┐ ┌──────┐ ┌──────┐    │  └─────────────────┘ │
│ │ Naan │ │Garlic│ │Coke  │    │                     │
│ │      │ │ Naan │ │ ZERO │    │  TOTAL    ₹1,420    │
│ │ ₹30  │ │ ₹50  │ │ ₹50  │    │                     │
│ └──────┘ └──────┘ └──────┘    │  [Void] [🧾 Generate│
│ + Custom Item (not on menu)▾  │              Bill] │
└────────────────────────────────────────────────────┘
```

Key design choices:
- **Card is the entire tap target.** No tiny "+" button to miss — the whole card adds the item. Repeated taps stack the quantity in the order pane (existing behaviour, just easier to trigger).
- **Categories are chips, not headers.** Filtering by category is one tap; scanning categories doesn't require scrolling through hundreds of items.
- **86'd items dim with a "86'd" badge.** Tapping them shows a toast instead of adding to the order.
- **Mobile drops to 2-col grid.** Cards 68px tall instead of 78px, larger thumbnails of menu structure visible at once.
- **GST rate shown inline** under the price (e.g. `₹220 +5%`). Visible to the waiter, so they can answer customer "is GST included?" questions without leaving the screen.
- **Custom item collapsed.** Most orders use the menu; rare off-menu items click to expand the form.

---

## Test plan

### Critical-path (do these first)

1. **SQL verify** — run the verify block at the bottom of `067_restaurant_fixes.sql`.
2. **End-to-end dine-in:**
   - Add 3-4 menu items in `menu.html` across 2-3 categories (e.g. Starters, Mains, Drinks)
   - Go to `tables.html` → tap T1 → running-order opens
   - **Confirm category chips appear at the top** with the right counts and an "All" chip
   - **Tap a category chip** — only that category's items render
   - **Tap "All"** — all items return
   - **Search "pan"** (or part of any item name) — chips remain, list filters
   - Tap 2 menu cards (different items) → they appear in Current Round on the right
   - Tap the same card twice more — quantity in Current Round goes to 3
   - Click `🍳 Send to Kitchen (KOT)` → confirm KOT slip printed AND kitchen.html shows the order
   - Tap 1 more card → Send KOT again — 2 separate KOT rounds in kitchen
   - Click `🧾 Generate Bill`
   - **Confirm billing.html opens in MANUAL mode (not POS), green banner at top, all items pre-filled with correct prices and GST rates in the item grid**
   - Save the bill → kitchen does NOT get a duplicate aggregate order → table frees
3. **Void with PIN:**
   - Open a table → send 1 KOT → click `Void`
   - **Confirm the manager PIN modal appears** (not a plain confirm() dialog)
   - Enter the wrong PIN — modal stays open, attempt counter shows
   - Enter the correct PIN — RO voids, kitchen row flips to `cancelled`, table frees
4. **Strand recovery** — Generate Bill → close billing tab → re-tap table. Same RO resumes with all prior items intact.
5. **Mobile (≤767px viewport):**
   - Open running-order on phone-sized window
   - Confirm Menu/Order tabs at top
   - Confirm 2-col grid of cards
   - Confirm category chips scroll horizontally
   - Confirm Order tab badge updates with item count

### Should also work (regression)

6. Sidebar Tables link from anywhere lands on tables.html
7. Dashboard food shop shows Tables (real link) and Menu in Quick Actions
8. Menu CRUD: add/edit/delete/toggle is_available all save
9. bills.table_number persisted: `SELECT * FROM bills WHERE table_number IS NOT NULL ORDER BY created_at DESC LIMIT 5`
10. No more page-blink when navigating to menu/tables/kitchen/running-order from any sidebar item

---

## Rollback

- **SQL:** drop the 4 new/patched RPCs and revert `sbp_ro_void` + `sbp_ro_generate_bill` to their 065 versions. bills column additions are NULL-able — safe to leave behind. module_profile DELETEs are harmless to leave.
- **UI:** `git revert` the commit and push.

## Notes

- The UX overhaul is self-contained in `running-order.html`. If anything in the new grid layout misbehaves, only that file needs to be reverted — the SQL + every other file in the batch stays valid.
- `lib/auth-pin.js` was added to running-order.html's `<head>` so the PIN modal works. The lib was already deployed (used by bills/bookings/folio), so no additional rollout needed.
- Service worker is disabled in PWA — no SW bump needed.
- Old cached `running-order.html` pages still work — the patched `sbp_ro_generate_bill` has `p_bill_id DEFAULT NULL`, so the legacy 2-arg form resolves correctly. Strand bug persists for stale caches until they refresh, then it's gone.

## Deferred (next batch)

- P4 edit-after-KOT (needs KOT-amendment UX)
- P6 split bill / merge tables / transfer table
- P7 waiter / kitchen_staff roles
- W5 name-only aggregation for custom items (partial fix already shipped via service_id)
- W7 unified `lib/kot-print.js` (two implementations exist, output is identical)
