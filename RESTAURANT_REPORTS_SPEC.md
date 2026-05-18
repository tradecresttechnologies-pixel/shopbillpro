# Restaurant Reports — Research & Build Spec

**Status:** Research complete. No report code written yet. This locks
scope before building so no section is missed.

---

## 1. What data we actually have (audited from migrations)

| Source | Holds | Reporting value |
|---|---|---|
| `bills` (+ `table_number`, `table_session_id` from 067) | Final settled restaurant bills: grand_total, paid_amount, balance_due, payment_mode, GST, discount, voided_at, created_at, bill_items | **Primary revenue source.** Authoritative money. |
| `sbp_running_orders` | Live + billed sessions: items[] (qty, price, round, voided_qty), kots[], kot_count, opened_at, billed_at, status | Table turn time, KOT counts, item-level mix, course timing |
| `sbp_restaurant_tables` | Tables: number, section, capacity, status | Per-table / per-section revenue, occupancy |
| `sbp_guest_orders` | QR orders: items, status (pending/accepted/rejected), accepted_at, accepted_kot_no, rejected_reason | QR channel performance, accept vs reject vs modify |
| `sbp_restaurant_orders` (KDS) | Kitchen tickets mirror | Kitchen throughput (optional) |

**Key joins available:** bill → session via `bills.table_session_id`;
bill → table via `bills.table_number`; session → table via
`sbp_running_orders.table_id`. All indexed (067).

---

## 2. Standard restaurant reports — full checklist

Benchmarked against what Petpooja / Posist / Toast / Square expose, so
nothing is missed. Marked: ✅ buildable now / ⚠️ partial / ❌ needs data.

### A. Sales & Revenue
1. ✅ **Sales summary** — gross, net, discount, GST, voids, by date range
2. ✅ **Daily sales trend** — revenue per day, bills per day, AOV
3. ✅ **Hourly / day-part sales** — breakfast/lunch/dinner peaks (from `created_at`)
4. ✅ **Average bill value (AOV)** + covers (see gap #1 re: covers)
5. ✅ **Payment mode split** — cash / UPI / card / credit (exists in core, scope to dine-in)
6. ✅ **Discounts given** — total + per-bill discount analysis
7. ✅ **Tax summary** — CGST/SGST/IGST for restaurant bills (reuse core GST logic)

### B. Table & Service
8. ✅ **Per-table revenue** — revenue, bills, AOV by table (via `bills.table_number`)
9. ✅ **Per-section revenue** — indoor/outdoor/AC etc. (table.section)
10. ✅ **Table turnaround time** — avg minutes occupied (`opened_at`→`billed_at`)
11. ✅ **Table utilisation** — turns/day per table, busiest tables
12. ⚠️ **Server/waiter performance** — see gap #2 (no server-per-bill field)

### C. Menu & Items
13. ✅ **Top / bottom selling items** — qty + revenue (from running_orders.items or bill_items)
14. ✅ **Category mix** — % revenue by menu category
15. ✅ **Item profitability** — needs cost price; reuse core P&L COGS pattern if menu has cost
16. ✅ **Void / wastage report** — voided items (voided_qty in running_orders) + voided bills
17. ✅ **KOT analysis** — avg KOTs/table, rounds per session

### D. QR / Digital Channel
18. ✅ **QR order funnel** — placed → accepted → rejected → modified
    (now possible cleanly post-073: accepted+kot_no, accepted+null=modified, rejected)
19. ✅ **QR vs staff-punched split** — channel revenue contribution
20. ✅ **QR rejection reasons** — `rejected_reason` aggregation

### E. Operational
21. ✅ **Day-close / Z-report** — single end-of-day summary (sales, payments, voids, cash expected)
22. ✅ **Open tables / unsettled** — sessions still open, aged
23. ⚠️ **Comp / complimentary** — only if tracked as 100% discount; otherwise gap #3

---

## 3. Data GAPS found (decide before build)

1. **Covers (number of guests per bill).** Not captured today. AOV-per-cover
   and "revenue per seat" need it. Options: (a) add optional `covers` field
   on table-open / bill, (b) approximate from table capacity, (c) skip cover
   metrics in v1. **Recommend (c) for v1, (a) as a small later batch.**

2. **Server/waiter attribution.** Bills don't store which staff member
   served. `accepted_by_name` exists on guest orders only. True waiter
   performance needs a `server_id` on the session/bill. **Recommend: scope
   waiter report OUT of v1; note as a future batch needing a schema add.**

3. **Comps vs discounts.** No distinct "complimentary" flag — only discount.
   v1 treats 100%-discount or a discount-reason as comp if present; flag as
   approximate.

4. **Cost price for item profitability.** Depends on whether menu items
   carry a cost field. If not, item P&L is revenue-only in v1.

None of these block a strong v1 — they scope specific sub-metrics.

---

## 4. Proposed build — phased, API-first (locked rule: SQL RPC first)

**Phase R1 — core (one RPC, one report screen):**
`sbp_restaurant_report(p_shop_id, p_from, p_to)` → single jsonb with:
sales summary, daily trend, day-part, payment split, discounts, per-table,
per-section, turnaround, top/bottom items, category mix, voids, QR funnel,
day-close. Server-side aggregation, `{ok,...}` envelope, owner check,
read-only. New tab group in `reports.html` ("🍽️ Restaurant") OR a
dedicated `restaurant-reports.html` — your call (Q below).

**Phase R2 — exports & drill-down:** CSV/print per section, date presets
(today/yesterday/this week/month/custom), per-table drill-down.

**Phase R3 — gap closers (separate batches):** covers field + per-cover
metrics; server attribution + waiter report; cost-based item P&L.

---

## 5. Decisions needed from you before I build R1

1. **Placement:** add restaurant reports as new tabs inside the existing
   `reports.html`, or a separate `restaurant-reports.html` reachable from
   the restaurant sidebar? (Existing reports.html already has 13 tabs;
   adding ~6 more may crowd it. A dedicated page is cleaner for restaurant
   owners but duplicates the period/print scaffolding.)
2. **v1 gap calls:** OK to ship v1 WITHOUT covers and waiter metrics
   (gaps #1, #2), adding them as later batches? (Strongly recommended —
   they need schema additions and shouldn't delay the 90% that's ready.)
3. **Tier gating:** per locked pricing, advanced reports = Business. Confirm
   restaurant reports are Business-gated (with maybe a basic sales summary
   on Pro)?

Once you answer these three, R1 is a clean, well-scoped build with no
missed sections.
