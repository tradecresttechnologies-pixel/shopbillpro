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
