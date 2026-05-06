# Customer History — Bug fix #3 (6 May 2026)

**Triggered by:** Vinay confirmed migration 013 is deployed (`SELECT proname FROM pg_proc WHERE proname = 'sbp_get_customer_timeline'` returns 1 row), but stats still show all zeros for Jyoti who has 6 bills totaling ₹4,497.

---

## Root cause

The 013 RPC queries bills strictly by `customer_id`:

```sql
WHERE b.customer_id = p_customer_id
```

But Jyoti's old bills almost certainly have **`customer_id IS NULL`** with only `customer_name = 'Jyoti'` set. Why? Because ShopBill Pro started name-based and added `customer_id` linkage later (this matches a known note in our codebase: *"Supabase billing data joins customer by ID, not name"* — that fix introduced ID-linking but didn't backfill old bills).

So the RPC sees zero bills for Jyoti even though the data exists.

---

## The fix — 1 file, no client changes

**`db/migrations/017_customer_history_name_fallback.sql`** updates the RPC body so it matches bills by EITHER `customer_id` OR (when id is NULL) by `customer_name`:

```sql
WHERE b.shop_id = v_shop_id
  AND (
    b.customer_id = p_customer_id
    OR (b.customer_id IS NULL AND v_cust_name IS NOT NULL
        AND b.customer_name = v_cust_name)
  )
```

Applied in TWO places — the bill_stats CTE (for the stats grid) and the bill_events CTE (for the timeline list).

Appointments and loyalty queries unchanged — those are newer and always use customer_id.

---

## Deploy (1 file, ~30 sec)

```
1. Open Supabase → SQL Editor → New query
2. Paste contents of:
     db/migrations/017_customer_history_name_fallback.sql
3. Hit Run
4. Hard-refresh phone, tap Jyoti in History
```

**No client-side changes needed.** The hotfix v2 customer-history.html stays as is.

---

## Smoke test

After deploying:

```sql
-- Replace with Jyoti's real UUID (you can get it from the customers picker
-- by inspecting the URL after tapping her, or run:
--   SELECT id, name FROM customers WHERE name = 'Jyoti';
SELECT sbp_get_customer_timeline('<jyoti-uuid>');
```

Expected output:
```json
{
  "ok": true,
  "stats": {
    "total_bills": 6,
    "total_spent": 4497,
    "balance_due": 3401,
    ...
  },
  "timeline": [ ... 6+ events ... ]
}
```

In the app:
- BILLS card: "6" with "active" subtitle
- TOTAL SPENT: ₹4,497 (avg ₹749/bill)
- DUE card: ₹3,401 — unpaid balance
- Timeline list: 6 bills with dates, amounts, status

---

## Going forward

For NEW bills created after this fix: customer_id will be populated as before (no change in billing.html). Old bills get matched by name as a graceful fallback. Both work.

If you ever do a backfill (set `bills.customer_id` from `customer_name` lookups), the name-fallback becomes a no-op but stays harmless.

---

*Customer History bug fix #3 — RPC name-fallback · 6 May 2026*
