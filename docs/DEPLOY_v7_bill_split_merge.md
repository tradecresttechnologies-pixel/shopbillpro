# ShopBill Pro v7.0 — Bill Split + Table Merge

## What this ships

### Bill Split (3 modes, each = own bill with own invoice_no)
- **Equal split** — divide total into N equal bills. Last split absorbs paise round-off so SUM(splits) == original to the paise.
- **Custom amount split** — staff types each person's amount. Validation: amounts must sum to bill total. GST allocated proportionally.
- **By-item split** — assign each item to a person. Each person's bill shows their actual items (real itemization).

Every split bill gets its own `invoice_no`. All siblings of one split share a `split_session_id` (audit lineage). Original running order closes, table goes free.

### Table Merge
- **Merge ALL into target table** — moves all items from current RO into another table's RO. Current table becomes free.
- **Move SOME items** — pick items via checkbox + pick target table. Both tables stay open. Granular use case.

## DEPLOY PATHS

| Source in zip | Target in repo | Action |
|---|---|---|
| `db/migrations/100_bill_split_merge.sql` | `db/migrations/100_bill_split_merge.sql` | NEW — run in SQL editor |
| `running-order.html` | `running-order.html` | REPLACE |

**Two files. One SQL, one HTML. No Edge Function changes.**

## DEPLOY ORDER

```
1. Run SQL: db/migrations/100_bill_split_merge.sql
2. Replace running-order.html
3. Push via GitHub Desktop → Vercel auto-deploys
4. Hard-refresh on a running order page (Ctrl+Shift+R)
5. Test
```

## What the SQL does

**Adds 4 columns to `bills` table:**
- `split_kind` — NULL for normal bills, 'equal'/'custom'/'item' for splits
- `split_index` — 1-based position among siblings
- `split_total_ways` — how many splits total
- `split_session_id` — uuid grouping all siblings of one split

**Adds 7 new RPCs:**
- `_sbp_ro_compute_totals(items jsonb)` — helper, derives subtotal+GST+grand from RO items
- `_sbp_alloc_invoice_no(shop_id)` — helper, wraps existing `next_invoice_no` for cleaner use
- `sbp_ro_split_equal(order_id, n_ways, payment_mode)`
- `sbp_ro_split_custom(order_id, amounts jsonb, payment_mode)`
- `sbp_ro_split_by_item(order_id, groups jsonb, payment_mode)`
- `sbp_ro_merge_into(source_order_id, dest_order_id)`
- `sbp_ro_move_item(source_order_id, dest_order_id, item_id)`
- `sbp_ro_list_open(shop_id)` — for the merge picker UI

**Schema safety:** Defensive checks at top of migration — fails fast if bills/bill_items/sbp_running_orders/next_invoice_no don't exist.

## What the HTML adds

**Two new buttons on running-order.html:**
- `✂️ Split Bill` (rail + mobile) — disabled until order has items, enabled same time as Generate Bill
- `🔀 Merge / Move` (rail + mobile) — always enabled when an order exists

**Two new modals:**
- Split modal with 3-mode picker + per-mode UI
- Merge modal with 2-mode picker (all / some items)

**Total: +27.8KB to running-order.html. 7 inline scripts, all node-validated.**

## TEST PLAN

### Test 1 — Migration deploys cleanly
After running `100_bill_split_merge.sql`:
```sql
-- All 8 RPCs registered?
SELECT proname FROM pg_proc WHERE proname IN (
  '_sbp_ro_compute_totals', '_sbp_alloc_invoice_no',
  'sbp_ro_split_equal', 'sbp_ro_split_custom', 'sbp_ro_split_by_item',
  'sbp_ro_merge_into', 'sbp_ro_move_item', 'sbp_ro_list_open'
);
-- Expected: 8 rows

-- New columns on bills?
SELECT split_kind, split_index, split_total_ways, split_session_id
FROM bills LIMIT 1;
-- Expected: query runs (returns NULL values for existing bills)
```

### Test 2 — Split Equal (the main path)
1. Open T5 (Indian Curry test shop), add some items (₹100 + ₹200 + ₹300 = ₹600 + GST)
2. Send KOT (so items get `item_id` stamped)
3. Tap **Split Bill** button
4. Click "Equal" mode
5. Enter 3 people
6. Preview should show "Each person pays approximately ₹X"
7. Tap "Split Bill"
8. Should redirect to tables.html, T5 should be FREE
9. Open bills.html → 3 new bills with consecutive invoice_no, each ~₹200 (with GST), all dated today
10. **Reconciliation:** SUM of the 3 grand_totals should equal the original total to the paise

```sql
-- Check the reconciliation
SELECT split_session_id,
       SUM(grand_total) AS total_split,
       split_total_ways,
       MAX(created_at) AS when
FROM bills
WHERE split_session_id IS NOT NULL
GROUP BY split_session_id, split_total_ways
ORDER BY when DESC LIMIT 1;
-- total_split should be exactly the running-order total
```

### Test 3 — Split Custom
1. Open T5 again, add items totaling some amount (e.g. ₹500)
2. Tap Split Bill → Custom mode
3. Enter 2 people
4. Inputs default to ₹250/₹250
5. Try entering ₹150/₹300 → warning appears ("Difference: ₹50")
6. Fix to ₹200/₹300 → warning clears, confirm enabled
7. Tap Split → 2 bills created (₹200 and ₹300, GST allocated proportionally)

### Test 4 — Split by Item
1. Open T6, add: Samosa (₹50), Biryani (₹250), Lassi (₹100)
2. Send KOT (items get stable item_id)
3. Tap Split Bill → By Item mode
4. Enter 2 people
5. Each item has a P1/P2 dropdown — assign Samosa→P1, Biryani+Lassi→P2
6. Tap Split → 2 bills created:
   - P1's bill: just Samosa (₹50 + GST)
   - P2's bill: Biryani + Lassi (₹350 + GST)
7. Each bill shows the actual items in its bill_items

### Test 5 — Merge ALL into target
1. Open T1 with items A, B
2. Open T2 with items C, D
3. From T2's running order, tap **Merge / Move** → "Merge ALL into..."
4. Select target = T1 (from dropdown)
5. Tap Confirm
6. T2 should be FREE
7. T1's order now has items A, B, C, D

### Test 6 — Move SOME items
1. Open T3 with items X, Y, Z (sent to kitchen so they have item_ids)
2. Open T4 (empty or with other items)
3. From T3, tap Merge / Move → "Move SOME items"
4. Check items X, Y (leave Z)
5. Select target = T4
6. Tap Confirm
7. T3 still open with just Z
8. T4 has its original items + X, Y

### Test 7 — Audit lineage queries
```sql
-- Find all splits of one dining event
SELECT invoice_no, split_kind, split_index, split_total_ways, grand_total
FROM bills
WHERE split_session_id = '<id from test 2>'
ORDER BY split_index;

-- Find all splits from one running order
SELECT invoice_no, split_kind, grand_total
FROM bills
WHERE table_session_id = '<RO id>'
ORDER BY created_at;
```

## ROLLBACK

```sql
DROP FUNCTION IF EXISTS sbp_ro_split_equal(uuid, int, text);
DROP FUNCTION IF EXISTS sbp_ro_split_custom(uuid, jsonb, text);
DROP FUNCTION IF EXISTS sbp_ro_split_by_item(uuid, jsonb, text);
DROP FUNCTION IF EXISTS sbp_ro_merge_into(uuid, uuid);
DROP FUNCTION IF EXISTS sbp_ro_move_item(uuid, uuid, text);
DROP FUNCTION IF EXISTS sbp_ro_list_open(uuid);
DROP FUNCTION IF EXISTS _sbp_ro_compute_totals(jsonb);
DROP FUNCTION IF EXISTS _sbp_alloc_invoice_no(uuid);

ALTER TABLE bills
  DROP COLUMN IF EXISTS split_kind,
  DROP COLUMN IF EXISTS split_index,
  DROP COLUMN IF EXISTS split_total_ways,
  DROP COLUMN IF EXISTS split_session_id;
```

Then `git revert` running-order.html.

## HONEST FLAGS

1. **Items need `item_id` for By-Item split + Move-Some.** Items get a stable UUID only after being sent to kitchen (via `sbp_ro_add_items` per migration 067). Items in the current round before first KOT send don't have ids. If the user tries to split-by-item or move-some on those items, the UI shows "No item-id stamped items found. Send to kitchen at least once first." This is correct behavior, not a bug — but flag it for staff training.

2. **Payment mode defaults to 'cash'.** Split modal doesn't currently expose a payment-mode picker — all splits go through as `'cash'`. If staff need to record different payment modes per split (one paid by card, others cash), they need to manually edit each bill after split. Easy v7.1 addition: add a payment-mode dropdown per split row.

3. **Tax invoice fragmentation.** Per your locked decision, every split creates a separate GST invoice. This consumes your invoice_no sequence faster (4-way split = 4 invoice numbers used). For an audit-clean restaurant this is correct. If you ever want to switch to "payment splits only" (one invoice, multiple payments), the underlying schema supports both — just a different RPC.

4. **`sbp_ro_void` is NOT called on split.** When a split happens, the running order is marked 'billed' (with bill_id pointing to the first split). The original RO is NOT voided — it's a normal-state closed order. This is by design: voiding would re-open stock, which is wrong (the food was eaten, not returned).

5. **No undo for splits.** Once a split is created, you can't merge the bills back. Each split is an independent bill. If staff makes a mistake (wrong N, wrong amount), they need to void each split bill via the existing void flow and start over. Real CA-grade systems work this way.

6. **Round-off behavior.** For equal split, the LAST split absorbs the paise round-off. So splitting ₹100.01 three ways gives ₹33.33 + ₹33.33 + ₹33.35. The last person pays an extra paisa. This is deterministic and reconciles exactly to the original total.

7. **GST allocation in custom mode.** Each person's GST is proportional to their share of grand_total. Last split absorbs round-off on GST as well. Subtotal back-calculated from (amount - their_gst). This is honest — every person sees their actual GST on their bill.

8. **Mobile UI is functional but tight.** The split modal works on mobile but is denser. Designed for 768px+ primarily. Real-world mobile use should still work (tested viewBox math).

## AFTER DEPLOY

Run through the 7-test plan. The most critical test is **Test 2 reconciliation** — if SUM(splits) doesn't exactly equal original total, paise-level bug. Other tests are operational.

If anything fails:
- Migration error → schema mismatch (e.g. bills table missing a column I assumed). Paste the error.
- UI button missing → cache issue, hard refresh
- "No item-id stamped items" → working as designed, items not yet sent to kitchen
- Split succeeds but bills look wrong → most likely a GST allocation bug. Paste the SQL of one split bill, I'll diagnose.

## Cumulative session shipped

| Version | What it added |
|---|---|
| v5.0 | Single-page polished website (modal + motion) |
| v6.0–6.3 | Reservation polish (notify + blocking + settings + cron) |
| v7.0 | Bill split (3 modes) + table merge (all/some) ← THIS |

Next in queue: SEO + auto-indexing for shop websites. But first — verify v7.0 works.
