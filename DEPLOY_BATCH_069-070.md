# Batch 069 + 070 — Table Occupancy & Session Timer Fixes

Folder paths below are **repo-relative**. Drop each file at the same path
inside your ShopBill Pro repo, then deploy in the order shown.

```
ShopBillPro_Batch069-070/
├── DEPLOY_BATCH_069-070.md                     (this file — do NOT deploy)
├── db/
│   └── migrations/
│       ├── 069_table_occupancy_sync.sql        → repo: db/migrations/069_table_occupancy_sync.sql   [NEW]
│       └── 070_table_free_closes_ro.sql        → repo: db/migrations/070_table_free_closes_ro.sql   [NEW]
├── tables.html                                 → repo: tables.html                                   [REPLACE]
└── qr-menu.html                                → repo: qr-menu.html                                  [REPLACE — carry-forward]
```

---

## DEPLOY ORDER (SQL FIRST, in sequence, then HTML — locked rule)

### Step 1 — SQL  (Supabase → SQL Editor → run IN THIS ORDER)
```
1) db/migrations/069_table_occupancy_sync.sql
2) db/migrations/070_table_free_closes_ro.sql
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
tables.html        REPLACE  (repo root)
qr-menu.html       REPLACE  (repo root) — only if prior cart/redesign
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
