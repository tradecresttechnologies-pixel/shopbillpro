# Batch 069 — Table Occupancy Sync + Order-aware Tables UI

Folder paths below are **repo-relative**. Drop each file at the same path
inside your ShopBill Pro repo, then deploy in the order shown.

```
ShopBillPro_Batch069/
├── DEPLOY_BATCH_069.md                         (this file — do NOT deploy)
├── db/
│   └── migrations/
│       └── 069_table_occupancy_sync.sql        → repo: db/migrations/069_table_occupancy_sync.sql   [NEW]
├── tables.html                                 → repo: tables.html                                   [REPLACE]
└── qr-menu.html                                → repo: qr-menu.html                                  [REPLACE — carry-forward]
```

---

## DEPLOY ORDER (SQL FIRST, then HTML — locked rule)

### Step 1 — SQL  (Supabase → SQL Editor → run)
```
db/migrations/069_table_occupancy_sync.sql
```
Replaces `sbp_tables_list`. Read-time derivation only — it does NOT write
the stored status column, so nothing is wiped and every existing flow
keeps working. Ends with `NOTIFY pgrst, 'reload schema';`.

Verify after running:
```sql
SELECT (sbp_tables_list('<your_shop_uuid>') -> 'tables');
-- any table with an open running order should now show
-- "status":"occupied" plus a populated "order" object.
```

### Step 2 — HTML  (commit + push, Vercel auto-deploys)
```
tables.html        REPLACE  (repo root)
qr-menu.html       REPLACE  (repo root) — only if Batch from prior session
                             (cart-visibility + redesign) is not yet pushed
```

---

## WHAT THIS BATCH DOES

1. **Occupancy is the open check WITH items — not a manual flag.**
   `sbp_tables_list` LEFT JOINs the latest open `sbp_running_orders`
   per table. The table is `occupied` ONLY when that order has >= 1
   active (non-voided) item. An empty running-order shell (opened,
   nothing punched) does NOT occupy — the table keeps its stored flag
   and stays freely changeable. Self-heals on every load.

2. **Order summary on the tile** — total (per-line GST, net of voided
   qty), item count, KOT count, time-on-table. Only when items > 0.

3. **Status changes are blocked once items are punched.** If even one
   item is on the order, the action sheet shows ONLY "Resume Order"
   plus a locked notice — no Free/Reserve/Cleaning. The only way to
   free the table is to settle the bill or void the order (both via
   Resume Order, both already free the table server-side). Tables with
   zero punched items (incl. seated-but-not-ordered) remain freely
   changeable, exactly as expected.

## ROLLBACK

SQL: re-run the previous `sbp_tables_list` definition from
`db/migrations/062_restaurant_tables.sql` (section 1). It is a plain
`CREATE OR REPLACE`, fully reversible, no data touched.
HTML: revert the two files via git.

## NOT IN THIS BATCH

- `sbp_running_orders` has no guest-name column; tile guest label stays
  blank for staff-punched orders (total/items/time are exact).
- No change to the locked QR business rule (guest must be seated before
  sending) or to 068.
