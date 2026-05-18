# ════════════════════════════════════════════════════════════
#  RESTAURANT REPORTS SIDEBAR — ROOT CAUSE FOUND & FIXED
# ════════════════════════════════════════════════════════════
# Live DB proved: restaurant_reports was registered for NO profile
# (rr_registered_for = NULL) — migration 075 had not been run.
# Shop resolves to profile 'restaurant'; 'tables' is registered for
# 'food, restaurant' which is why Tables shows and RR did not.
#
# THE ONE THING THAT FIXES IT:
#   Run  db/migrations/078_fix_restaurant_reports_registration.sql
#   in Supabase SQL Editor.  (Idempotent, data-derived, safe.)
#   Then hard-refresh the app (Ctrl+Shift+R) — lib/sidebar-engine.js
#   is cached and must also be the pushed/updated copy.
#
# VERIFY immediately after running 078:
#   SELECT profile, module_code, status FROM sbp_module_profiles
#   WHERE module_code='restaurant_reports';
#   -> MUST include  ('restaurant','restaurant_reports','active')
#   If that row exists and link still missing -> hard-refresh /
#   confirm lib/sidebar-engine.js (with the restaurant_reports
#   catalog entry) is the deployed copy.
# ════════════════════════════════════════════════════════════

# ⚠️ READ FIRST — why the two issues you saw happen

## "Restaurant Reports not in sidebar"
The sidebar needs BOTH, and BOTH must be deployed:
  1. db/migrations/075_register_restaurant_reports_module.sql  → RUN IN SUPABASE
  2. lib/sidebar-engine.js                                     → PUSH (overwrites old)
If either is missing the link will NOT appear. Verify after deploy:
  SELECT profile, module_code, status FROM sbp_module_profiles
  WHERE module_code='restaurant_reports';   -- must return active rows
Hard-refresh the app (Ctrl+Shift+R) — sidebar-engine.js is cached.

## "Whole page blinking"
Cause: tables.html called SBPSidebar.render() AFTER `await reloadAll()`,
so the page painted with an empty 220px sidebar gap until the network
finished. FIXED: tables.html now renders the sidebar synchronously
BEFORE the await. Other restaurant pages already did this (verified) —
the blink was specific to tables.html. Re-push tables.html.

CAPTURE VERIFIED: bill at 02:04 shows covers=1, server_name=Owner,
customer_id set. Phase A + 076 confirmed working end to end.

────────────────────────────────────────────────────────────────────

# Batch 069 + 070 + 071 — Table Occupancy & Session Timer Fixes

Folder paths below are **repo-relative**. Drop each file at the same path
inside your ShopBill Pro repo, then deploy in the order shown.

```
ShopBillPro_Batch069-071/
├── DEPLOY_BATCH_069-071.md                     (this file — do NOT deploy)
├── db/
│   └── migrations/
│       ├── 069_table_occupancy_sync.sql        → repo: db/migrations/069_table_occupancy_sync.sql   [NEW]
│       ├── 070_table_free_closes_ro.sql        → repo: db/migrations/070_table_free_closes_ro.sql   [NEW]
│       └── 071_guest_accept_selfcontained.sql  → repo: db/migrations/071_guest_accept_selfcontained.sql [NEW]
├── tables.html                                 → repo: tables.html                                   [REPLACE]
└── qr-menu.html                                → repo: qr-menu.html                                  [REPLACE — carry-forward]
```

---

## DEPLOY ORDER (SQL FIRST, in sequence, then HTML — locked rule)

### Step 1 — SQL  (Supabase → SQL Editor → run IN THIS ORDER)
```
1) db/migrations/069_table_occupancy_sync.sql
2) db/migrations/070_table_free_closes_ro.sql
3) db/migrations/071_guest_accept_selfcontained.sql
```
FUNCTION definitions only. 069 never writes the status column; 070
closes open running orders when a table is freed. Each ends with
`NOTIFY pgrst, 'reload schema';`.

Verify:
```sql
-- 069: table with >=1 punched item → occupied + order object;
--      empty RO shell → no order, keeps stored flag.
SELECT (sbp_tables_list('<shop_uuid>') -> 'tables');

-- 070: freeing a table reports how many open orders it closed.
SELECT sbp_tables_free('<shop_uuid>','<table_uuid>');
-- → { "ok": true, "orders_closed": 1 }
```

### Step 2 — HTML  (commit + push, Vercel auto-deploys)
```
tables.html          REPLACE  (repo root)
running-order.html   REPLACE  (repo root)
qr-menu.html         REPLACE  (repo root) — only if prior cart/redesign
                               batch not yet pushed
```

---

## WHAT THESE BATCHES DO

### 069 — occupancy is the open check WITH items, not a flag
- `sbp_tables_list` LEFT JOINs the latest open `sbp_running_orders`.
  Occupied ONLY when that order has >= 1 active (non-voided) item.
  Empty RO shell does NOT occupy — stored flag stands, table stays
  freely changeable.
- Tile shows total (per-line GST, net of voided), items, KOT, time —
  only when items > 0. Self-heals drift each load.
- Action sheet: items punched → status changes BLOCKED, only
  "Resume Order" + locked notice (settle or void to free). Zero items
  → status freely changeable.

### 070 — freeing a table closes its running order (timer reset)
- Settling frees the table; previously the running order could stay
  `open` (local/offline bill id, or RO flag unset), so reopening
  RESUMED the old session and the timer never reset.
- Now `sbp_tables_free` and `sbp_tables_set_status(... 'free')` close
  any open running order (status → 'billed', billed_at stamped),
  server-side and unconditional. Next open creates a FRESH running
  order with new `opened_at` → "time on table" restarts from reopen
  (both the tables tile and the running-order header read opened_at).
- bill_id untouched so a later sbp_ro_generate_bill can still stamp
  the real id. Idempotent; empty RO shells also closed.

## ROLLBACK
- 069: re-run `sbp_tables_list` from
  `db/migrations/062_restaurant_tables.sql` (section 1).
- 070: re-run `sbp_tables_free` + `sbp_tables_set_status` from
  `db/migrations/062_restaurant_tables.sql` (sections 5 & 6).
- HTML: git revert the two files.
All rollbacks are plain CREATE OR REPLACE, no data touched.

## NOT IN THESE BATCHES
- `sbp_running_orders` has no guest-name column; tile guest label is
  blank for staff-punched orders (total/items/time are exact).
- No change to the locked QR rule or Batch 068.

---

## HTML FIXES IN THIS DROP (no SQL needed for these two)

### running-order.html — Accept failure now diagnosable
"Accept & Send KOT" silently showed a blank ❌. The client discarded
`data.detail` from sbp_guest_order_accept. It now surfaces the real
server code + detail (e.g. `ro_open_failed`, `kot_failed`,
`not_authorized`) in the toast AND console. If accept still fails after
this, the toast tells you exactly why — most likely cause is the known
deploy-order dependency: 068's accept calls `sbp_ro_add_items` /
`sbp_ro_open`; if Batch 067/065 RPCs aren't deployed, accept fails.
Deploy 067 (and 065) before relying on guest-order accept.

### tables.html — Floor-screen guest-order alert
Guest orders previously only surfaced inside running-order.html. Now the
Tables screen:
- Fetches `sbp_guest_order_pending_list` on load and subscribes to
  realtime on `sbp_guest_orders` (INSERT/UPDATE, this shop).
- On a new order: vibrates, plays a short WebAudio chime, shows a toast,
  a top orange alert bar, and a pulsing 🔔 badge on the exact table card.
- Tapping the highlighted card opens the table → Resume Order →
  running-order to Accept. Cleared automatically when accepted/rejected.

---

## 071 — guest accept made self-contained + crash-proof (THE accept fix)

**Symptom:** `sbp_guest_order_accept` returned HTTP **400** (not 404) on
every click — function runs but raises internally. Root cause: 068's
accept called `sbp_ro_open()` / `sbp_ro_add_items()` (Batches 065/067);
if a nested RPC is missing/erroring on this DB, Postgres raises and
PostgREST emits a raw 400 that bypasses the {ok:false} envelope, so even
the client patch couldn't show why. Accept never finished → guest order
stayed 'pending' → floor notification never cleared.

**071 does:**
- Replaces `sbp_guest_order_accept` with a SELF-CONTAINED version:
  resolves/opens the running order INLINE and appends the KOT round
  INLINE (exact 067 stamping: round + item_id + voided:false; IST
  sent_at). No `sbp_ro_open` / `sbp_ro_add_items` dependency → the most
  likely 400 cause is gone.
- KDS mirror is best-effort in its own sub-block — a KDS issue can no
  longer fail the accept.
- Whole body wrapped in `EXCEPTION WHEN OTHERS` → returns
  `{ok:false, error:'exception', detail:{sqlstate,message}}`. No more
  opaque 400s; if anything ever fails, the running-order toast (already
  surfaces error+detail) shows the exact Postgres error.

After 071: clicking **Accept & Send KOT** appends the round to the
running order, fires the KOT, marks the guest order accepted, and the
realtime UPDATE clears the floor notification automatically.

**Rollback:** re-run the `sbp_guest_order_accept` body from
`db/migrations/068_qr_guest_orders.sql` (section 6).

## Note on "notification still showing"
The badge persists until the order is accepted/rejected — that is
correct (it's still pending). It clears the instant accept succeeds.
Because accept was failing (the 400), it never cleared. 071 fixes the
accept, which fixes the lingering notification.

---

## qr-menu.html — UPDATE (cart persistence + live seating)

Two guest-side bugs fixed (HTML only, no SQL):

1. **Cart survived nothing.** A reload / back-swipe / tab reclaim wiped
   the whole selection. Cart now persists in sessionStorage keyed by
   slug+table: restored on load (re-validated against the live menu,
   prices refreshed), saved after every add/remove/qty/note change,
   and cleared only on successful order or explicit reset.
2. **Seating didn't activate the open page.** The guest page only read
   table status at load, so "Seat Guests" left them stuck on
   "Waiting to be seated" until manual refresh. It now subscribes to
   realtime UPDATE on sbp_restaurant_tables (filter id=eq.table) and
   re-skins the gated UI in place the instant staff seats them
   ("✅ Your table is ready"). 20s public-RPC poll fallback covers
   flaky restaurant wifi where realtime drops.

Deploy: replace qr-menu.html at repo root (no SQL).

---

## FOUC / blink fix — ALL restaurant + hospitality pages (HTML only)

**Symptom:** every restaurant-based sidebar page blinked on open —
blank flash + raw bilingual title ("Tablesटेबल", both EN+HI spans
visible) before content appeared.

**Cause:** these pages were missing the lang-span CSS that dashboard.html
has, AND had no pre-paint language script. The .lang-en/.lang-hi spans
had default display until lang.js ran *after* paint → flash. Content
also waited behind async init's network call.

**Fix applied to 12 pages** (tables, rooms, bookings, running-order,
walk-in, folio, housekeeping, kitchen, menu, services, appointments,
compliance):
1. 4-line lang-span CSS injected as the first rule in <style> so the
   correct language shows at PARSE time (zero flash) — identical to the
   canonical dashboard.html rule.
2. Pre-paint `<script>` added in <head> right after the existing theme
   pre-paint: sets `document.documentElement.lang` from
   localStorage.sbp_lang synchronously BEFORE first paint.

This is the documented project FOUC pattern (pre-paint inline script +
parse-time CSS), now extended to the restaurant pages it was never
applied to. Idempotent: pages that already had the CSS only received the
pre-paint, no duplication. All 12 main scripts re-validated post-patch.

**Deploy:** replace all 12 .html files at repo root. No SQL.

---

## 072 — THE actual Accept fix (column 42703)

Captured from the live app console at last:
`{"sqlstate":"42703","message":"column \"name\" does not exist"}`

071's "who accepted" lookup referenced columns that don't exist:
- `sbp_authorized_users.name`  → real column is `user_name`
- `sbp_authorized_users.user_id` → real key is `created_by`
- `shops.name` → no such column (shops predates migrations; working
  RPCs only ever touch shops via owner_id)

→ 42703 thrown at first row fetch → 071's wrapper returned
`{ok:false,error:'exception'}` → accept failed every time. This was
never auth or nested RPCs; it was one bad column name in a cosmetic
"who accepted this" label.

072 recreates sbp_guest_order_accept identical to 071 EXCEPT the actor
block: now a self-contained, exception-safe sub-block using the correct
`user_name` column and `created_by = auth.uid()` key, defaulting to
'staff' on any miss. accepted_by_name is a display label only — the KOT
and running order never depended on it.

**Deploy:** run `db/migrations/072_guest_accept_actor_fix.sql` in
Supabase (after 069/070/071, or standalone — it fully supersedes 071's
accept function). Then click Accept & Send KOT — it will now succeed.

Rollback: re-run 071's accept body.

---

## 073 — Modify no longer rejects the order (correctness fix)

**Bug:** the Modify button called sbp_guest_order_reject just to clear
the order from the queue → every modified order was permanently marked
'rejected', corrupting all reporting (this is why your test orders all
showed 'rejected').

**Fix:** new RPC `sbp_guest_order_mark_modified` marks the order
'accepted' (it WAS accepted — staff took it and is editing it) with
accepted_kot_no = NULL (= "accepted via Modify, KOT sent manually after
editing"). running-order.html Modify repointed reject → mark_modified.
Send Waiter (reject) unchanged — still legitimately rejects.

Reporting can now distinguish: accepted+kot_no = direct accept;
accepted+null = modified; rejected = genuinely refused.

**Deploy:** run `073_guest_order_mark_modified.sql` in Supabase, then
push running-order.html. No constraint change (stays within existing
status CHECK).

---

## RESTAURANT_REPORTS_SPEC.md — research deliverable (NOT code)

Full research of restaurant reporting done BEFORE building, so no
section is missed. Maps 23 standard restaurant reports to the data we
actually have, flags 4 data gaps, proposes a 3-phase API-first build.
**Needs 3 decisions from you (placement / v1 gap scope / tier gating)
before R1 build starts — see section 5 of the spec.**

---

## 074 — Restaurant Reports PHASE A: covers + server capture

Reports can't aggregate data never recorded. Decisions locked with
Vinay: covers set at Seat Guests + editable at billing; server = auto
logged-in staff; staff list = sbp_authorized_users.

**074 SQL:**
- sbp_running_orders & bills += covers, server_user_id, server_name (idempotent)
- NEW _sbp_actor_name(shop_id) — correct user_name lookup (072 pattern)
- sbp_ro_open → auto-stamps server on NEW session (signature unchanged)
- NEW sbp_ro_set_covers(shop_id, order_id, covers)
- sbp_ro_generate_bill → returns covers+server, backfills server at bill

**HTML:**
- tables.html: Seat Guests prompts party size → stashed → applied to
  session after sbp_ro_open
- running-order.html: 👥 covers chip in header (tap to set/edit any
  time = "editable at billing"); covers+server written onto the
  dine-in bill at settle

**Deploy:** run 074 in Supabase, push tables.html + running-order.html.
After this, every new dine-in bill carries covers + server → Phase B
report RPC will have complete data (no empty sections).

NEXT: Phase B = sbp_restaurant_report RPC + dedicated
restaurant-reports.html (Business-gated, all 23 sections). Build starts
once Phase A is deployed & confirmed capturing.

---

## 075 + sidebar-engine.js — restaurant reports sidebar registration

"Deployed but not in sidebar": the sidebar is data-driven — needs a
CATALOG entry in lib/sidebar-engine.js AND a sbp_module_profiles row.
Neither existed (074 was data-capture only).

- lib/sidebar-engine.js: NEW 'restaurant_reports' catalog entry
  (href restaurant-reports.html, food order 30, hospitality 80)
- 075: registers restaurant_reports = active for all food + hotel
  profiles (idempotent ON CONFLICT)

⚠️ IMPORTANT: the link will 404 until Phase B ships restaurant-reports
.html. Two options:
  (a) deploy 075 + sidebar-engine.js now (link visible, 404s till
      Phase B) — OR
  (b) HOLD these two files and deploy them WITH the Phase B page next
      batch (recommended — no broken link).

Vinay to choose. Files included so they're ready either way.

## STATUS / NEXT
- Phase A (074) deployed by Vinay — needs capture verification:
  seat → bill → check bills.covers / bills.server_name populated.
- Phase B (sbp_restaurant_report RPC + restaurant-reports.html, all 23
  sections from RESTAURANT_REPORTS_SPEC.md, Business-gated) = next
  dedicated batch, built once Phase A capture is CONFIRMED working so
  every report section has real data.


---

## 074 follow-up — covers asked on ANY table-open path

Original 074 prompted covers only in Seat Guests. But staff often open
a table via "Take Order"/"Resume" which skipped the prompt → covers
stayed null (this is why the verification bills showed null — they were
also pre-deploy, but the path gap was real).

FIX (running-order.html): on a FRESH session (sbp_ro_open resumed=
false) with covers still unset, prompt for guest count right on the
running-order page. Now covers is captured "when the table is opened"
regardless of which button started it. Seat Guests prompt remains as
an optional early shortcut; 👥 header chip still edits anytime.

Re-push running-order.html (already in this zip, updated).


---

## Covers UX fix — native picker, no browser prompt

The window.prompt() dialog was jarring/out-of-flow. Replaced on BOTH
pages with native styled pickers matching the app:
- tables.html: Seat Guests swaps the action sheet to an in-sheet
  guest-count step (quick-pick 1-8, 9+ custom, Skip).
- running-order.html: native cv-modal (quick-pick grid + custom input)
  used for both fresh-open auto-prompt AND the 👥 chip edit. Zero
  window.prompt remaining.
Re-push tables.html + running-order.html (in this zip, updated).

---

## 076 — Dine-in customer capture (name + mobile)

Locked: capture at Seat Guests AND auto-carry QR guest details to the
bill; save as customer record (history/loyalty/WhatsApp).

REUSES existing sbp_resolve_customer_for_booking (024) — proven
phone-first dedupe + find-or-create. No parallel logic.

GUARDRAILS (protect the customer DB):
- Saved customer created ONLY when a valid mobile is present
  (name-only = bill label, no record — can't dedupe/WhatsApp it).
- Phone-first match → a repeat diner is REUSED, not duplicated.
  (Also fixes a pre-existing defect: the old bill-wizard new-customer
  path did a blind INSERT with no dedupe → duplicate per visit.)

076 SQL:
- sbp_running_orders += cust_name, cust_phone, customer_id
- NEW sbp_ro_set_customer(shop,order,name,phone) → stores label always,
  resolves+stamps customer_id only with valid mobile, exception-safe
- sbp_ro_generate_bill → returns cust fields for the bill write

HTML:
- tables.html: Seat Guests = 2-step native sheet (covers → optional
  name/mobile, "Skip — walk-in" prominent). No browser prompt.
- running-order.html: applies seat-captured customer after sbp_ro_open;
  auto-carries QR guest_name/guest_phone on accept; prefills the bill
  wizard from the session so staff never re-types.

Deploy: run 076 in Supabase (after 074), push tables.html +
running-order.html.

---

## PHASE B — Restaurant Reports engine (077 + restaurant-reports.html)

The full report engine, all 23 spec sections, Business-gated.

077 SQL: ONE RPC sbp_restaurant_report(shop_id, from, to) → single
jsonb with 23 sections: sales summary, daily trend, day-part, payment
split, discounts, tax, per-table, per-section, turnaround, utilisation,
server performance, top/bottom items, category mix, voids, KOT
analysis, QR funnel, QR reject reasons, day-close, open tables.
Server-side aggregation, owner-checked, read-only, exception-safe
envelope, IST day-part/day-close. Reuses confirmed bill/bill_items/
running_orders/guest_orders columns + 074 covers/server + 076 customer.

restaurant-reports.html: dedicated page, Business gate (isBiz else
upgrade lock), date presets (today/7d/30d/90d/custom), print CSS,
sidebar via SBPSidebar.render('restaurant_reports'), lang+theme
prepaint (no FOUC), skeleton loader, graceful error surfacing
(shows RPC sqlstate/message if it ever fails).

### FULL DEPLOY ORDER (all SQL, in sequence, in Supabase)
069 → 070 → 071 → 072 → 073 → 074 → 075 → 076 → 077
Then push ALL html + lib/sidebar-engine.js. The sidebar link
(075 + sidebar-engine.js) now has its page (restaurant-reports.html)
so it no longer 404s — ship them together.

### VERIFY
1. SQL: select sbp_restaurant_report('<shop>', null, null);  → {ok:true,...}
2. App: restaurant sidebar → Restaurant Reports → loads, all sections,
   date presets work. Non-Business sees the upgrade lock.
3. Numbers reconcile against a known day's bills.


---

## 077 FIX — "aggregate functions are not allowed in GROUP BY"

Sidebar link now works (078 done). The RPC threw because 4 sections
(day_part, per_section, server_performance, category_mix) did
SELECT jsonb_build_object(...COUNT/SUM...) ... GROUP BY 1 — GROUP BY 1
pointed at the whole jsonb object which CONTAINS the aggregates.

FIX: each rewritten to aggregate in an inner query grouped by the
plain dimension (part/section/server/category), then wrap in
jsonb_build_object in the outer query (no GROUP BY there). Pattern now
matches the already-working sections (daily_trend/payment_split use
GROUP BY <plain col>). per_table/top_items/qr_reject were already
correct (GROUP BY plain column / plain expression).

RE-RUN db/migrations/077_restaurant_report.sql in Supabase (it is
CREATE OR REPLACE — just run the updated file again). No other change.


---

## 077 FIX #2 — opened_at GROUP BY error

Next error surfaced: sbp_running_orders.opened_at must appear in
GROUP BY. Cause: table_utilisation did SELECT jsonb_build_object(
...AVG(billed_at-opened_at)...) FROM rs GROUP BY table_number — the
deeply nested aggregate inside jsonb_build_object under GROUP BY
trips Postgres parser strictness. Also open_tables had a query-level
ORDER BY opened_at outside jsonb_agg.

FIX: table_utilisation + table_turnaround rewritten to the safe
pattern (aggregate in inner subquery, jsonb built in outer query);
open_tables ORDER BY moved INSIDE jsonb_agg(). Full file audited —
the 7 pure-aggregate sections (sales_summary, discounts, tax_summary,
kot_analysis, qr_funnel, day_close, voids) are valid as-is (aggregate
only, no non-agg column, no GROUP BY needed).

RE-RUN db/migrations/077_restaurant_report.sql in Supabase again
(CREATE OR REPLACE, just run the updated file). Nothing else changed.


---

## 079 — Drill filters + Void/Delete audit report

(1) FILTERS on the report page: Category / Item / Table dropdowns
(date range already existed). Options come from filter_options the
RPC returns (real distinct values, whole-period). Selecting one
reloads with p_category/p_item/p_table → item/category/table-scoped
sections drill; sales_summary reflects the filtered scope; an orange
banner shows the active filter. Clear-filters button.
sbp_restaurant_report is now 6-arg (old 3-arg dropped; new args
DEFAULT NULL so behaviour identical when unfiltered). This version
ALSO rebuilds every section with the safe inner-aggregate/outer-json
pattern — no GROUP BY / ORDER-BY-outside-jsonb_agg pitfalls.

(2) sbp_restaurant_void_report — NEW RPC reading the REAL
sbp_audit_log trail. Covers bill.void, bill.void_item (KOT cancel /
in-service), bill.delete, bill.delete_item, payment.void. Returns
summary KPIs + by-staff + by-reason + full line-by-line trail (who,
when, amount, reason, authorized-by + method, cap 500). before_json
shapes verified from migrations 032/038. Shown as a printable
'Void & Delete Audit' section on the report page.

DEPLOY: run db/migrations/079_void_delete_report_and_filters.sql in
Supabase (after 077). Push restaurant-reports.html. Hard-refresh.
The page calls both RPCs in parallel; if the void RPC errors the
main report still renders (void section just omitted).


---

## 079 UPDATE — filter scoping made consistent across ALL sections

"Put all reports in drill": the filterable sections (sales, trend,
day-part, payments, discounts, tax, per-table, per-section, items,
category-mix, server) ALREADY re-scope to Category/Item/Table — they
read the rb/ri CTEs which carry the filter. This update makes the
WHOLE page consistent and honest:

- Sections that CANNOT be meaningfully scoped per item/category
  (Table Turnaround, KOT Analysis — session-level; QR Funnel, QR
  Rejections — whole period; Day-Close — today snapshot) now show a
  small grey note in their header ("not affected by item/category
  filter" / "whole period — not filtered" / "today's snapshot")
  so a filtered page never shows a misleading unscoped number next to
  scoped ones.
- SQL: 079 now returns filters.item_or_cat_active so the UI knows
  exactly when to show that note.

Rationale: forcing a category filter onto a QR funnel or a day-close
would produce numbers that look filtered but aren't — worse than
labelling them. Every section that CAN drill, does; the few that
structurally can't are clearly marked.

RE-RUN db/migrations/079... in Supabase (CREATE OR REPLACE) + push
restaurant-reports.html + hard-refresh.


---

## 080 — Click-through DRILL (sections unchanged, rows clickable)

Locked: keep existing sections; rows drill DOWN 3 levels.
  Section row → Level 2: bills for that row → Level 3: bill items.

080 SQL: NEW sbp_restaurant_drill(shop,mode,dim,val,bill_id,from,to)
  mode='bills' + dim ∈ {table,server,payment,day,item,category} →
    bills matching that clicked row
  mode='items' + bill_id → that one bill header + line items
  Owner-checked, read-only, exception-safe, IST. Columns verified
  (bills.invoice_no/grand_total/created_at/payment_mode/server_name/
  cust_name/covers; bill_items.item_name/qty/rate/line_total/
  gst_amount/kind).

restaurant-reports.html: tableEl/barList gain an optional drill cfg →
rows get a ' ›' affordance + click. 7 drillable sections wired
(Daily Trend→day, Payment→payment, Per-Table→table, Server→server,
Top Items→item, Slowest→item, Category Mix→category). Click opens a
modal: Level-2 bills list (each bill row itself clickable) → Level-3
full bill (header KPIs + line items). Back + close. Sections that
aren't bill-decomposable (per-section bar, turnaround/KOT, QR, day-
close, void-audit) intentionally NOT drillable — drilling them to
'bills' would be meaningless.

DEPLOY: run db/migrations/080_restaurant_drill.sql in Supabase
(after 079) + push restaurant-reports.html + hard-refresh.
Test: tap a Table row → its bills → tap a bill → its items.


---

## 081 — REPORT PICKER redesign (research-first; spec included)

Research doc: REPORT_PICKER_REDESIGN_SPEC.md (benchmarked vs Petpooja/
Posist/Toast/Square/IDS). Decisions locked by Vinay: grouped dropdown;
select+Run (no auto-run); print only; itemised=flat list; keep Show
Everything.

081 SQL — wrapper, engine UNTOUCHED (zero risk to working 079 RPC):
  NEW sbp_restaurant_report_one(shop,report,from,to,cat,item,table):
   - calls existing sbp_restaurant_report once, returns ONLY the
     picked section + meta (range/filters/filter_options)
   - report='all' → full passthrough (Show Everything)
   - report IN ('void'...) → returns use_rpc marker (UI calls
     sbp_restaurant_void_report)
   - NEW 'discount_detail' per-bill list for Discount Report (only
     genuinely new compute; engine not modified)

restaurant-reports.html — picker model:
  - Persistent picker bar (grouped <optgroup> dropdown of 17 reports
    + Show Everything; date presets/custom; cat/item/table filters;
    ▶ Run Report). Nothing computes until Run.
  - render() split into keyed builders R{}; emits ONLY the picked
    report (or all). Drill-through retained inside each.
  - Scoped print: #print-area only → 'Print this report' prints just
    the chosen report with a header (name + range), not page chrome.
  - Business gate / prepaint / sidebar unchanged.

DEPLOY: run db/migrations/081_report_picker.sql in Supabase (AFTER
079; 080 too). Push restaurant-reports.html. Hard-refresh.
Test: pick 'Itemised Sales' → 7 days → Run → only that report +
Print; pick 'Show Everything' → all sections; pick 'Void & Delete'
→ audit via its RPC.


---

## PLAN GATE AUDIT — restaurant/hotel = Business (revenue fix)

Research: PLAN_GATE_AUDIT.md (audited live gates vs locked pricing).

KEY FINDING: restaurant/hotel pages were UNDER-gated — a PRO (₹99)
shop could use the full Business (₹499) restaurant suite. ~₹400/mo
leak per restaurant on Pro. rooms/bookings even showed a wrong
"Upgrade to Pro ₹99" upsell for a Business feature.

TRIAL SAFETY VERIFIED: 60-day trial sets plan=business + expiry, so
isBiz() is TRUE during trial. Gating to isBiz() does NOT lock out
trial users; expiry correctly flips them to the lock screen.

FIXED (9 pages → Business gate + correct "Upgrade to Business"
messaging):
  tables, running-order, kitchen, menu, rooms, bookings, folio,
  walk-in, housekeeping (housekeeping uses a self-contained inline
  check — page had no shared plan helpers).
UNCHANGED (correct): restaurant-reports (already Business);
  qr-menu (anon customer page — stays public, 0 gates).

SCOPE NOTE: this is UI-layer plan enforcement. Server RPCs are
owner-checked but NOT plan-checked — a determined user could call
RPCs directly. Server-side plan enforcement is logged as future
hardening (out of scope for this UI audit unless requested).

DEPLOY: push the 9 HTML files. No SQL. Hard-refresh. Test: a Pro
(or Free) account opening tables/kitchen/rooms/etc. now sees the
Business upgrade lock; a Business (or trial) account works normally.
