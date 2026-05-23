# ShopBillPro · v7b Hotfix — Split Bill `items_count` column error

**Bundle:** `ShopBillPro_v7b_hotfix_split_items_count.zip`
**Date:** 23-May-2026
**Severity:** P0 — Split Bill (all 3 modes) fails with PostgreSQL error
**Scope:** 1 SQL hotfix (run in Supabase) + 1 source-of-truth replacement. No JS/HTML changes.

---

## DEPLOY PATHS

| Action  | Path                                            | Notes |
|---------|-------------------------------------------------|-------|
| NEW     | `db/migrations/101_split_items_count_fix.sql`   | **Run this in Supabase SQL Editor NOW.** Drops + recreates the 3 split RPCs with the bogus column reference removed. Idempotent. |
| REPLACE | `db/migrations/100_bill_split_merge.sql`        | Source-of-truth correction so future cold-deploys won't reintroduce the bug. **Do not re-run in Supabase** — running 101 is enough to fix the live DB. |

No HTML changes. No `lib/` changes. The v7a `running-order.html` hotfix from the previous bundle stays in place.

---

## Live error you saw

```
Split failed: column "items_count" of relation "bills" does not exist
```

Same error fires from all three split modes (Equal / Custom / By Item).

---

## Root cause (audited, not guessed)

Migration 100 was authored with five references to a `bills.items_count` column:

| Line | RPC                    | Context                       |
|------|------------------------|-------------------------------|
| 288  | `sbp_ro_split_equal`   | INSERT column list            |
| 298  | `sbp_ro_split_equal`   | INSERT VALUES (`v_label, 1,`) |
| 472  | `sbp_ro_split_custom`  | INSERT column list            |
| 482  | `sbp_ro_split_custom`  | INSERT VALUES (`v_label, 1,`) |
| 646  | `sbp_ro_split_by_item` | INSERT column list            |
| 656  | `sbp_ro_split_by_item` | INSERT VALUES (`v_label, 0,`) |
| 705  | `sbp_ro_split_by_item` | UPDATE bills SET `items_count = v_grp_count` |

**The column doesn't exist** and never has. Verified across the entire repo:

```bash
$ grep -rn "ALTER TABLE bills ADD COLUMN" db/
db/migrations/009_loyalty.sql:34: loyalty_redemption_amount numeric DEFAULT 0
db/migrations/009_loyalty.sql:35: loyalty_points_redeemed   int DEFAULT 0
db/migrations/009_loyalty.sql:36: loyalty_points_earned     int DEFAULT 0
db/migrations/100_bill_split_merge.sql:86-89: split_kind, split_index, split_total_ways, split_session_id
```

No `items_count` anywhere. Item counts are always computed on read:

```sql
(SELECT COUNT(*)::int FROM bill_items bi WHERE bi.bill_id = b.id) AS items_count
```

This pattern appears in `013_customer_history.sql:146`, `017_customer_history_name_fallback.sql:128`, `018_batch017_bugfixes.sql:293`. No code path reads a stored `bills.items_count` value.

## The fix

Removing the 5 references (no schema change). Cleaner than adding a denormalized column that would require maintenance triggers on every `bill_items` insert/delete. The 3 INSERTs now have 23 columns and 23 values each — verified column/value alignment in both the new 101 and the replacement 100.

---

## Deploy steps

### Step 1 — Live DB (Supabase SQL Editor)

1. Open Supabase → SQL Editor.
2. Paste the contents of `db/migrations/101_split_items_count_fix.sql`.
3. Run.
4. Expected output: 3 `CREATE FUNCTION` and 3 `GRANT` notices, plus `NOTIFY pgrst, 'reload schema'`.
5. Verify the functions are in place:
   ```sql
   SELECT proname FROM pg_proc
   WHERE proname IN ('sbp_ro_split_equal','sbp_ro_split_custom','sbp_ro_split_by_item');
   ```
   Expected: 3 rows.

### Step 2 — Source-of-truth (GitHub)

1. Replace `db/migrations/100_bill_split_merge.sql` with the file in this bundle.
2. Commit + push. (Vercel auto-deploy is a no-op — no client code touched.)
3. This keeps the repo source consistent so anyone re-running 100 from scratch won't reintroduce the bug.

---

## Verification (after deploy)

1. Refresh the running-order page for table T30.
2. Tap **Split Bill** in the right action rail.
3. Pick **Equal**, split into 2 → tap Split.
4. Expected: success toast, the running order closes, 2 bills appear under Bills with `Split-equal from T30` notes and consecutive invoice numbers.
5. Repeat for Custom split (enter amounts that sum to ₹1411.20).
6. Repeat for By-Item (assign items to 2 persons in your screenshot, tap Split).

If you get a different error after this fix (e.g. a different missing column or constraint violation), file separately — that's a different bug and means I missed something else in the audit.

---

## What changed in the patched 100 (full diff)

```diff
--- 100_bill_split_merge.sql  (original)
+++ 100_bill_split_merge.sql  (patched)
@@ Line 288 — sbp_ro_split_equal INSERT cols
-      customer_name, items_count,
+      customer_name,
@@ Line 298 — sbp_ro_split_equal INSERT vals
-      v_label, 1,
+      v_label,
@@ Line 472 — sbp_ro_split_custom INSERT cols
-      customer_name, items_count,
+      customer_name,
@@ Line 482 — sbp_ro_split_custom INSERT vals
-      v_label, 1,
+      v_label,
@@ Line 646 — sbp_ro_split_by_item INSERT cols
-      customer_name, items_count,
+      customer_name,
@@ Line 656 — sbp_ro_split_by_item INSERT vals
-      v_label, 0,  -- items_count updated after item inserts
+      v_label,
@@ Line 704 — sbp_ro_split_by_item UPDATE bills SET
-      items_count = v_grp_count,
       subtotal    = ROUND(v_grp_subtotal, 2),
```

7 line removals total. Nothing added.

---

## Rollback

If anything breaks worse after running 101, revert by re-running 100 from the repo (which will reintroduce the items_count bug but restore the prior state). You almost never want to do this.
