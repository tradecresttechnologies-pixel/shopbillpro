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

1. **Occupancy is now derived from the open check, not a manual flag.**
   `sbp_tables_list` LEFT JOINs the latest open `sbp_running_orders` per
   table. An open order forces effective `status = 'occupied'`,
   overriding any drifted stored flag. Self-heals on every load
   (retroactively fixes T10 and any other drifted table).

2. **Order summary on the tile** — total (per-line GST, net of voided
   qty), item count, KOT count, time-on-table. Big-brand POS behaviour.

3. **Order-aware action sheet** — leads with "Resume Order — ₹X so far",
   shows a red summary card, and guards Free/Reserve/Cleaning behind a
   two-tap confirm when a live order is on the table (order is never
   voided by a status change — guard is anti-fat-finger only).

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
