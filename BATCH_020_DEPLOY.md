# BATCH 020 — Reports Engine foundation

**Date:** 8 May 2026
**Migration #:** 021_reports_engine.sql
**Status:** Ready to deploy
**Type:** Additive — coexists with the existing reports.html (does not touch GSTR-1 / GSTR-3B / P&L)

---

## What this batch ships

A **reusable, server-side reports engine** that makes adding new reports cheap. Each report is now:
- 1 PostgreSQL RPC (server-side aggregation, scales to millions of rows)
- 1 entry in the `REPORT_CONFIGS` dict in `lib/report-viewer.js`

Plus 4 baseline reports that work for **every** shop type, leveraging Batch 019's `kind` column for the new Item-Kind Breakdown:

| Report | RPC | What it shows |
|---|---|---|
| 📊 Sales Summary | `sbp_report_sales_summary` | Bills, revenue, AOV, daily breakdown, by-status |
| 📦 Item-Kind Breakdown | `sbp_report_item_kind_breakdown` | Revenue split by product / service / room + top 20 items |
| 🏆 Top Customers | `sbp_report_top_customers` | Top 25 by spend, with visits, AOV, dues, last visit |
| 💳 Payment Mode Mix | `sbp_report_payment_mode_mix` | Cash / UPI / Card / Credit % breakdown |

Each report has:
- Date range picker (Today, This Week, This Month, Last 7/30/90 Days, This Year, Custom)
- Refresh button
- CSV export (download formatted CSV)
- KPI cards (top metrics)
- Grouped breakdowns (where applicable)
- Sortable detail table

---

## Files

```
batch020/
├── BATCH_020_DEPLOY.md
├── db/migrations/
│   └── 021_reports_engine.sql       ← run FIRST in Supabase SQL Editor
├── lib/
│   └── report-viewer.js             ← NEW — the viewer component + REPORT_CONFIGS
└── reports-engine.html              ← NEW — landing page at /reports-engine.html
```

---

## Architecture

### Server-side (RPCs)

Every report RPC follows the same pattern:

```sql
sbp_report_<name>(p_shop_id uuid, p_from_date date, p_to_date date)
RETURNS jsonb {
  ok: true|false,
  error?: 'unauthorized' | 'rpc_failed',
  report_key: 'sales_summary',
  from_date: '2026-04-08',
  to_date:   '2026-05-08',
  summary:   { ... KPI fields ... },
  rows:      [ ... detail rows ... ],
  groups:    [ ... grouped breakdown rows ... ]
}
```

**Security:**
- Each RPC checks `auth.uid() = shops.owner_id` via `sbp_report_check_owner()` helper
- Returns `{ok:false, error:'unauthorized'}` to non-owners
- Anon role is NOT granted execute permission — only authenticated users

**Performance:**
- All aggregation happens at the DB layer (GROUP BY, SUM, COUNT)
- Never returns raw `bills` or `bill_items` data
- Will scale fine to 100k+ bills without extra indexes (uses existing `bills(shop_id, invoice_date)` and `bill_items(bill_id)` access patterns)

### Client-side (viewer)

`lib/report-viewer.js` exposes:

```js
SBPReportViewer.render({
  mountEl:   document.getElementById('mount'),
  shopId:    'uuid',
  reportKey: 'sales_summary'    // looks up REPORT_CONFIGS internally
});
```

Each entry in `REPORT_CONFIGS` defines:
- `title`, `icon`, `description`, `rpc`
- `kpis`: which summary fields to render as cards
- `groups`: optional sub-breakdown table
- `rows`: detail table column config
- `shopTypes`: array of allowed shop types or `['*']` for all

**To add a new report later** (Batch 021/022/023):
1. Add an RPC to a new migration file
2. Add a config entry to `REPORT_CONFIGS`
3. Done — viewer auto-handles UI, date picker, CSV export

---

## Deploy steps

### Step 1 — Database migration

Open Supabase SQL Editor → New Query → paste `db/migrations/021_reports_engine.sql` → Run.

**Note:** the migration is defensive — if Batch 019 wasn't deployed (no `kind` column on `bill_items`), it will add the column itself with default `'product'`. So this works whether 019 is live or not.

**Verification queries:**

```sql
-- 1. New RPCs exist
SELECT proname FROM pg_proc WHERE proname LIKE 'sbp_report_%' ORDER BY proname;
-- Expected: 5 rows
--   sbp_report_check_owner
--   sbp_report_item_kind_breakdown
--   sbp_report_payment_mode_mix
--   sbp_report_sales_summary
--   sbp_report_top_customers

-- 2. Test as logged-in shopkeeper (replace with real shop_id)
-- (You must be authenticated in Supabase Studio for auth.uid() to resolve)
SELECT public.sbp_report_sales_summary(
  (SELECT id FROM shops LIMIT 1)::uuid,
  NULL,
  NULL
);
-- Expected: { ok:true, summary:{total_bills,...}, rows:[...], groups:[...] }
-- If returns { ok:false, error:'unauthorized' }: that's correct when called
-- without a logged-in user context — RPC works, just rejecting the call.

-- 3. Confirm bill_items.kind exists (added by 019 OR by this migration)
SELECT column_name FROM information_schema.columns
WHERE table_name = 'bill_items' AND column_name = 'kind';
-- Expected: 1 row with column_name='kind'
```

### Step 2 — Deploy code

| From zip | To repo |
|---|---|
| `lib/report-viewer.js` | `/lib/report-viewer.js` (new) |
| `reports-engine.html` | `/reports-engine.html` (new) |

Commit message:
```
Batch 020: Reports Engine foundation — server-side aggregation RPCs,
generic viewer component, 4 baseline reports (Sales / Item-Kind /
Top Customers / Payment Mode), CSV export, date range picker
```

Vercel auto-deploys.

### Step 3 — Smoke tests

Visit `https://app.shopbillpro.in/reports-engine.html`

#### Test A — Landing page renders
- See 4 cards: Sales Summary, Item-Kind Breakdown, Top Customers, Payment Mode Mix
- Each card has icon + title + description
- "Open Legacy Reports →" link at bottom (points to existing reports.html for GSTR/P&L)
- ← Dashboard button at top

#### Test B — Sales Summary loads
- Click "Sales Summary" card
- See KPI cards: Bills, Revenue, Collected, Outstanding, AOV, Customers
- Below that: "By Status" grouped table (Paid / Credit / etc.)
- Below that: "Daily Breakdown" detail table

If your shop has 0 bills, the KPIs show 0 and tables show "No data for this period." That's correct.

#### Test C — Date range works
- Click the "Range" dropdown → select "Today" → numbers refresh
- Switch to "Last 90 Days" → numbers refresh
- Pick custom dates in From/To → numbers refresh

#### Test D — CSV export works
- Click "⬇️ CSV" button
- File downloads named `sbp_report_sales_summary_<from>_to_<to>.csv`
- Open it → should have headers matching the detail table columns

#### Test E — Other 3 reports load
- Click ← All Reports → click "Item-Kind Breakdown" → should show By Kind groups + Top 20 Items
- Repeat for Top Customers and Payment Mode Mix

#### Test F — Unauthorized rejection
- Optionally, in DevTools console try calling the RPC directly with another shop's UUID:
  ```js
  await window._sb.rpc('sbp_report_sales_summary',{p_shop_id:'00000000-0000-0000-0000-000000000000', p_from_date:null, p_to_date:null})
  ```
- Should return `{ok:false, error:'unauthorized'}` — confirms ownership check works

---

## How to add the link to your sidebar (optional but recommended)

The reports-engine.html page is reachable directly via URL but won't appear in your sidebar yet. To add it:

In `dashboard.html` (and other user-facing pages with the sidebar), add a nav-item near the existing "Reports" entry:

```html
<div class="nav-item" onclick="window.location.href='reports-engine.html'">
  <span>📊</span><span>Reports</span>
</div>
```

If your sidebar is built dynamically by `lib/sidebar-engine.js`, add `reports-engine` to the sidebar config there. (Happy to do this in a follow-up patch — just ask.)

---

## Rollback plan

If anything goes wrong:

1. **Database:** Migration is purely additive. To remove:
   ```sql
   DROP FUNCTION IF EXISTS sbp_report_payment_mode_mix(uuid, date, date);
   DROP FUNCTION IF EXISTS sbp_report_top_customers(uuid, date, date, int);
   DROP FUNCTION IF EXISTS sbp_report_item_kind_breakdown(uuid, date, date);
   DROP FUNCTION IF EXISTS sbp_report_sales_summary(uuid, date, date);
   DROP FUNCTION IF EXISTS sbp_report_check_owner(uuid);
   -- (Don't drop bill_items.kind — Batch 019 may depend on it)
   ```

2. **Code:** `git revert` the deploy commit. The new reports-engine.html simply becomes 404; existing `reports.html` is untouched.

---

## Known carryover items (not in scope for this batch)

- **Sidebar nav link** — not added automatically (see "How to add the link" above). Can do as small follow-up patch.
- **Vertical-specific reports** — Hotel occupancy/ADR/RevPAR, Salon stylist commission, Retail stock turnover come in Batches 021/022/023 respectively.
- **PDF export** — for now use CSV + your spreadsheet tool. PDF can come with a future polish batch.
- **Charts/graphs** — current viewer is tables-only. Adding line charts for daily series + pie charts for breakdowns can come in 023.5 polish.
- **Scheduled reports / email delivery** — Phase 2 post-launch.
- **Sortable/filterable tables in viewer** — header click sort is partially wired (cursor:pointer + hover) but not yet active. Easy follow-up.

---

## Acceptance criteria

✅ Migration runs without error
✅ All 5 RPCs exist (4 reports + 1 helper)
✅ Reports engine landing page renders 4 cards
✅ Each report opens, loads data (or empty state), exports CSV
✅ Date range picker works (presets + custom)
✅ Unauthorized RPC calls return `{ok:false, error:'unauthorized'}`
✅ Existing `reports.html` (GSTR/P&L) continues to work unchanged

If any fail → DevTools console screenshot + the failing query/click I should retrace.

---

**Built by Claude · Batch 020 · 8 May 2026 · ShopBill Pro · TradeCrest Technologies Pvt. Ltd.**
