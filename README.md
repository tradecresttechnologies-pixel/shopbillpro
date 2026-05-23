# ShopBillPro · v7.0.1 Hotfix — Split bill customer fields + proportional covers

**Bundle:** `ShopBillPro_v7.0.1_hotfix_customer_and_covers.zip`
**Date:** 23-May-2026
**Severity:** P1 — Splits work but bills look unprofessional (wrong customer name, duplicated covers)
**Scope:** 1 NEW migration + 1 source-replacement for hygiene. No client changes.

---

## DEPLOY PATHS

| Action  | Path                                                  | Where to deploy |
|---------|-------------------------------------------------------|-----------------|
| NEW     | `db/migrations/103_split_customer_and_covers.sql`     | **Supabase SQL Editor — run now.** Also commit to GitHub. |
| REPLACE | `db/migrations/100_bill_split_merge.sql`              | GitHub only — source hygiene. **Don't re-run in Supabase**, 103 already updates the live RPCs. |

No HTML, no JS, no `lib/`.

---

## What this fixes

### 1. Customer name slot was showing the share label

Before: split bills printed "Equal share (1 of 2)" in the customer name field. The actual customer name, phone, and customer_id from the running order were dropped on the floor.

After: split bills carry forward `v_ro.cust_name` → `customer_name`, `v_ro.cust_phone` → `customer_wa`, `v_ro.customer_id` → `customer_id`. The share label ("Equal share (1 of 2)") still appears as the line-item description on each bill — that's the right place for it, since it explains what the customer is being charged for. Audit trail ("Split-equal from T30") is still in the bill `notes` field unchanged.

If the running order had no customer attached (the usual walk-in case), the fields are NULL — same as any walk-in bill. The bill viewer shows "—" for empty customer info; no more share-label-as-name confusion.

### 2. Covers were duplicated across every split

Before: a 4-person table split 2 ways printed "Covers: 4" on both bills. Per-cover revenue reports would have double-counted.

After: covers are apportioned the same way grand_total is — `floor(v_ro.covers / N)` for the first N-1 splits, with the last split absorbing the remainder. So 4 covers split 2 ways = (2, 2). 5 covers split 2 ways = (2, 3). NULL stays NULL. Applies to all three modes (Equal, Custom, By-Item).

---

## What's NOT fixed in this hotfix (still v7.1)

- **`payment_mode`** is still hardcoded to whatever the client passes (currently `'cash'` from the modal). The split modal has no per-split payment picker yet.
- **`status`** is still `'Paid'` — same reason, auto-settled.
- **Per-split customer name/phone capture** in the split modal — needs UI work.

Per the v7.1 plan in memory, these all land together when the picker UI ships.

---

## Root cause (audited)

Migration 076 added `cust_name`, `cust_phone`, `customer_id` to `sbp_running_orders` precisely so dine-in sessions could carry customer info from the moment the order opens through to the bill. Migration 074 added `covers` to both `sbp_running_orders` and `bills` with apportionment in mind. When I wrote migration 100 for v7 bill split, I:

1. Put the share label (`v_label`) directly into `customer_name`, treating it as a billing label rather than a customer name. The right slot for that string is the line-item description (`bill_items.item_name`), which it already populates.
2. Copied `v_ro.covers` verbatim into every split's `bills.covers`. Same thinko as the would-have-been-`items_count` bug — I knew totals needed apportionment but forgot covers did too.

Both bugs are in the same 3 RPCs (`sbp_ro_split_equal`, `sbp_ro_split_custom`, `sbp_ro_split_by_item`), in the `INSERT INTO bills` block of each.

---

## The fix — exact diff against v7b's mig 100

```diff
@@ All 3 INSERT INTO bills column lists @@
       shop_id, invoice_no, invoice_date,
-      customer_name,
+      customer_name, customer_wa, customer_id,
       subtotal, gst_amount, discount, grand_total,

@@ All 3 INSERT INTO bills VALUES blocks — customer slot @@
       v_shop_id, v_inv_no, CURRENT_DATE,
-      v_label,
+      v_ro.cust_name, v_ro.cust_phone, v_ro.customer_id,

@@ Equal split covers @@
       'equal', i, p_n_ways, v_session_id,
-      v_ro.covers, v_ro.server_user_id, v_ro.server_name,
+      CASE WHEN v_ro.covers IS NULL THEN NULL
+           WHEN i = p_n_ways THEN v_ro.covers - (v_ro.covers / p_n_ways) * (p_n_ways - 1)
+           ELSE v_ro.covers / p_n_ways
+      END,
+      v_ro.server_user_id, v_ro.server_name,

@@ Custom split covers @@
       'custom', i+1, v_n, v_session_id,
-      v_ro.covers, v_ro.server_user_id, v_ro.server_name,
+      CASE WHEN v_ro.covers IS NULL THEN NULL
+           WHEN i = v_n - 1 THEN v_ro.covers - (v_ro.covers / v_n) * (v_n - 1)
+           ELSE v_ro.covers / v_n
+      END,
+      v_ro.server_user_id, v_ro.server_name,

@@ By-Item split covers @@
       'item', i+1, v_n, v_session_id,
-      v_ro.covers, v_ro.server_user_id, v_ro.server_name,
+      CASE WHEN v_ro.covers IS NULL THEN NULL
+           WHEN i = v_n - 1 THEN v_ro.covers - (v_ro.covers / v_n) * (v_n - 1)
+           ELSE v_ro.covers / v_n
+      END,
+      v_ro.server_user_id, v_ro.server_name,
```

7 edits total. Column / value counts re-verified: all 3 INSERTs now have 25 columns and 25 values (paren-aware count, accounting for CASE-with-commas).

---

## Deploy steps

1. Open Supabase → SQL Editor.
2. Paste `db/migrations/103_split_customer_and_covers.sql`. Run.
3. Expected: 3 × `DROP`, 3 × `CREATE FUNCTION`, 3 × `GRANT`, 1 × `NOTIFY`.
4. Replace `db/migrations/100_bill_split_merge.sql` in GitHub. Commit + push.

---

## Verify

### Quick sanity in SQL editor

```sql
-- Check that all 3 functions point to the new column set
SELECT proname,
       (SELECT string_agg(p.parameter_name, ', ')
        FROM information_schema.parameters p
        WHERE p.specific_schema = 'public'
          AND p.specific_name = pg_get_function_identity_arguments(pp.oid))
FROM pg_proc pp
WHERE proname IN ('sbp_ro_split_equal','sbp_ro_split_custom','sbp_ro_split_by_item');
```

### End-to-end

1. **Walk-in scenario** (no customer attached to RO):
   - Open a table, send a KOT, tap Split Bill → Equal → 2.
   - Expected: bills show blank/`—` for customer name (not "Equal share (1 of 2)"), covers split as 2 and 2 (or 2 and 3 for an odd cover count).

2. **Named-customer scenario**:
   - Open a table, attach customer via the customer picker on the running-order page, send a KOT.
   - Tap Split Bill → Equal → 2.
   - Expected: both bills show the customer's name and phone in the customer slot. Customer history page should show both split bills under that customer.

3. **Covers apportionment**:
   - 5-cover table split 2 ways → bills should show 2 and 3 (last absorbs).
   - 4-cover table split 2 ways → 2 and 2.
   - 6-cover table split 3 ways → 2, 2, 2.

---

## Rollback

If anything looks worse, revert by re-running migration 100 (the v7b corrected version) in Supabase SQL Editor — that puts the old RPCs back. You'll lose this hotfix's improvements but won't lose any data.

---

## Pattern note (for me)

Fourth bug in the v7 chain, fourth time the same lesson — write new code without checking what already exists in the schema, ship a bug. Already counted three in v7a/b/c; this is the fourth. From here on, before writing any INSERT or RPC body that touches an existing table, I will:

1. `grep -rn "ALTER TABLE <table>" db/migrations/` — see every column that exists
2. `grep -rn "FUNCTION <related_function>" db/migrations/` — read the existing canonical RPC for the same table
3. Cross-reference any column not added by me against the constraint list

It costs ~10 seconds and would have caught all four bugs.
