# Batch 067 — Restaurant Vertical Fixes (+ sidebar-blink hotfix)

## Deploy paths (the file tree mirrors the live repo)

```
NEW      db/migrations/067_restaurant_fixes.sql
REPLACE  lib/sidebar-engine.js
REPLACE  dashboard.html
REPLACE  menu.html              ← 067-hotfix: sidebar bootstrap
REPLACE  tables.html            ← 067-hotfix: sidebar bootstrap
REPLACE  kitchen.html           ← 067-hotfix: sidebar bootstrap
REPLACE  running-order.html
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

## What this closes (12 audit defects + 1 hotfix)

| Sev | Code | Defect | Where it lives now |
|-----|------|--------|---------------------|
| 🔥 | S1 | menu CRUD calls non-existent `sbp_services_upsert` | SQL §1 (new RPC) |
| 🔥 | S2 | bills show 0% GST because public RPC strips `gst_rate` | SQL §2 (new RPC) + running-order + billing |
| 🔥 | S3 | order pane `display:none` on phones — waiters blocked | running-order CSS+JS (tabbed switcher) |
| ⛔ | P1 | void left pending KOTs cooking in KDS | SQL §3 (patched `sbp_ro_void`) |
| ⛔ | P2 | strand — closing billing tab left table occupied forever | SQL §4 (patched `sbp_ro_generate_bill`) + running-order + billing |
| ⛔ | P3 | bill save created duplicate ghost KDS row | billing (cameFromRO guard) |
| ⛔ | P5 | bills had no FK back to their table | SQL §5 (columns + indexes) + billing (billData) |
| ⚠️ | W1 | sidebar Tables link was dead | lib/sidebar-engine.js (`href`) |
| ⚠️ | W2 | dashboard food: Tables coming-soon stub, no Menu | dashboard (Quick Actions) |
| ⚠️ | W3 | wrong sbp_module_profiles rows for food/subscription | SQL §6 (cleanup + proper inserts) |
| ⚠️ | W4 | double banner on RO → billing redirect | billing (`!_roIdEarly` guard) |
| ⚠️ | W6 | duplicate KOT button on RO-sourced bills | billing (`renderPrinterButtons`) |
| ⚠️ | W8 | addItem prefill key mismatch — items had no name/qty/price | billing (correct keys) |
| 🩹 | HF | restaurant pages blinked/showed "Loading…" on navigation | menu/tables/kitchen/running-order (sidebar bootstrap) |

### About the hotfix

The 4 restaurant pages (menu, tables, kitchen, running-order) were calling
`SBPSidebar.render(...)` only *inside* `render()`, which fires AFTER
`await loadX()` resolves. During that 200–500ms Supabase round-trip the
sidebar didn't exist yet — the page rendered empty, then the sidebar
popped in alongside the content. That's the "blink + loading" you saw.

Canonical pages (dashboard, bills, customers, settings) render the
sidebar synchronously at parse time via a tiny IIFE, before any await.
This hotfix adds the same IIFE to the 4 restaurant pages. The existing
in-`render()` calls remain — they're now idempotent re-renders.

Net effect: clicking Menu / Tables / Kitchen / a running order from
any sidebar item now feels the same as clicking Customers or Bills.

Deferred (next batch): P4 edit-after-KOT · P6 split/merge/transfer · P7
roles · W5 name-only aggregation for custom items · W7 unified KOT print lib

## Test plan (in order)

1. **SQL verify** — run the verify block at the bottom of
   `067_restaurant_fixes.sql`. Expect: 4 RPCs / 2 bills columns / 4 food
   rows + 1 subscription row + 4 restaurant rows / 0 orphan rows.
2. **No more blink** — from dashboard.html, click Menu in the sidebar.
   The destination should show its sidebar instantly (no flash of empty
   page). Same for Tables, Kitchen. Repeat on mobile viewport.
3. **Sidebar Tables link** — open `running-order.html`, tap Tables in
   sidebar → navigates to `tables.html`.
4. **Dashboard food** — confirm Quick Actions shows Tables (real link)
   and Menu (new), no "coming soon" stub.
5. **Menu CRUD** — `menu.html`: add a dish with name/price/GST 5%/HSN.
   Save. Confirm row appears. Edit, toggle is_available, delete.
6. **End-to-end dine-in (must do on a phone screen ≤767px too):**
   - `tables.html` → tap T1 → running-order opens
   - On mobile: confirm Menu/Order tabs work and the badge updates
   - Add 2 items → Send KOT → kitchen shows them with correct GST
   - Add 1 more → Send another KOT → kitchen shows separate round
   - Click Generate Bill → billing loads with ONE green banner, items
     pre-filled with real prices and real GST percentages, KOT button HIDDEN
   - Save bill → no duplicate aggregate row in kitchen → table frees →
     `sbp_running_orders.bill_id` is set
7. **Strand recovery** — Generate Bill → close billing tab → re-tap table.
   Same RO resumes with all prior items intact.
8. **Void with pending KOTs** — open table, send 1 KOT, void from
   running-order. Confirm the KDS row flipped to `cancelled` (was staying
   `pending` before).
9. **bills.table_number persisted** —
   ```sql
   SELECT id, table_number, table_session_id, grand_total
   FROM bills
   WHERE table_number IS NOT NULL
   ORDER BY created_at DESC LIMIT 5;
   ```
   Both columns should be populated for dine-in bills.

## Rollback

- **SQL:** run a small rollback script that drops the 4 new/patched RPCs
  and reverts `sbp_ro_void` + `sbp_ro_generate_bill` to their 065
  versions. The bills column additions are safe to leave behind
  (NULL-able, no constraints). The module_profile DELETEs are harmless
  to leave.
- **UI:** `git revert` the commit and push. The hotfix IIFEs are tiny
  and self-contained — easy to remove manually if you want to keep the
  rest of the batch.

## Notes

- Old cached `running-order.html` pages still work — patched
  `sbp_ro_generate_bill` has `p_bill_id DEFAULT NULL`, so the legacy
  2-arg form resolves correctly. Strand bug persists for those stale
  caches until they refresh, then it's gone.
- The hotfix's IIFE renders the sidebar BEFORE the page's main script
  runs. If `lib/sidebar-engine.js` itself ever throws on parse, the
  console.warn fallback fires and the page still loads (just without
  a sidebar). No hard dependency.
- Service worker is disabled in PWA (per 12-May setup) — no SW bump
  needed.
