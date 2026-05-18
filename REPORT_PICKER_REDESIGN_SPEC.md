# Restaurant Reports — Picker Redesign Spec

**Status:** RESEARCH. No redesign code written yet. This locks scope &
decisions before any build (per locked rule: research first).

---

## 1. The problem with the current page

Today `restaurant-reports.html` renders ALL ~20 sections stacked,
every load. Issues:
- Slow / heavy: one RPC computes everything even if the user wants
  one number.
- No focus: an operator who wants "today's void report" scrolls past
  18 unrelated sections.
- Print is all-or-nothing: can't print just the discount report.
- Not how hotel/restaurant staff actually work — they pull ONE named
  report for a shift/day.

## 2. How real hospitality POS systems do it (benchmark)

Looked at the common pattern across Petpooja, Posist, Rista, Toast,
Square for Restaurants, and hotel PMS (IDS Next, eZee):

**Universal pattern = Report Picker:**
1. A **report selector** (dropdown or left list) of named reports
   grouped by category (Sales / Items / Tables / Staff / Tax /
   Operational / Audit).
2. **Date range** control (presets + custom).
3. Optional **filters** relevant to the chosen report (e.g. itemised
   sales → category/item; table report → section).
4. A **Run / Generate** button — nothing computes until pressed.
5. Result renders **below, alone**, with a **Print** (and often
   Export) button scoped to THAT report only.
6. Changing the report or date requires pressing Run again (explicit,
   predictable — no surprise reloads).

This is the model Vinay described almost exactly. Adopt it.

## 3. The report catalog (discrete, selectable)

Each becomes one pickable report. All already computed by the
existing `sbp_restaurant_report` / `sbp_restaurant_void_report`
engines — this redesign is mostly UX restructuring, not new SQL,
EXCEPT we should split the monolith RPC so "Run" computes only the
selected report (performance + correctness of the model).

| # | Report (picker label)        | Group       | Source section(s)            | Filters offered            |
|---|------------------------------|-------------|------------------------------|----------------------------|
| 1 | Sales Summary                | Sales       | sales_summary                | date                       |
| 2 | Daily Sales Trend            | Sales       | daily_trend                  | date                       |
| 3 | Day-Part (Meal Period) Sales | Sales       | day_part                     | date                       |
| 4 | Payment Mode Split           | Sales       | payment_split                | date                       |
| 5 | Discount Report              | Sales       | discounts (+ per-bill list)  | date                       |
| 6 | Tax / GST Summary            | Tax         | tax_summary                  | date                       |
| 7 | Itemised Sales Report        | Items       | top+bottom items (full list) | date, category, item       |
| 8 | Category Mix                 | Items       | category_mix                 | date                       |
| 9 | Revenue by Table             | Tables      | per_table                    | date, table                |
|10 | Revenue by Section           | Tables      | per_section                  | date                       |
|11 | Table Turnaround & Util.     | Tables      | turnaround + utilisation     | date                       |
|12 | Server / Waiter Performance  | Staff       | server_performance           | date, server               |
|13 | KOT Analysis                 | Operational | kot_analysis                 | date                       |
|14 | QR Order Funnel              | Digital     | qr_funnel + reject_reasons   | date                       |
|15 | Void & Wastage Report        | Audit       | voids + void audit trail     | date                       |
|16 | Void & Delete Audit (full)   | Audit       | sbp_restaurant_void_report   | date                       |
|17 | Day-Close / Z-Report         | Operational | day_close (+ key totals)     | (today / chosen day)       |
|18 | Open / Unsettled Tables      | Operational | open_tables                  | (live)                     |

Itemised Sales (#7), Discount (#5), Void (#15/16), Sales Summary (#1)
are the ones Vinay named explicitly — all present.

Drill-through (batch 080) is retained INSIDE each report where it
already applies (e.g. Revenue by Table rows still drill to bills →
items).

## 4. Build approach (locked rule: SQL RPC first)

**SQL — split the monolith for the picker model.** The current
6-arg `sbp_restaurant_report` computes all sections. For a picker we
add ONE param so it computes only what's asked:

`sbp_restaurant_report(..., p_report text DEFAULT NULL)`
- `p_report = NULL`  → full payload (back-compat; nothing breaks).
- `p_report = 'sales_summary'` (etc.) → only that section's key (+
  always `filter_options`, `filters`, `range`). Other keys omitted →
  far less compute per Run.

Discount report needs a per-bill discount list (new small section
`discount_detail`) — the only genuinely new SQL. Void reports already
have their own RPC. No other new SQL.

**UI — restaurant-reports.html becomes a picker:**
- Top bar: Report selector (grouped <optgroup>), date presets +
  custom, contextual filters (shown only for reports that use them),
  a **Run Report** button.
- Body: empty until Run; then ONLY the chosen report + a **Print
  this report** button (print CSS scoped so only the result prints,
  not the picker chrome).
- Keep Business gate, lang/theme prepaint, sidebar, drill-through.
- No auto-run on filter change (explicit Run, per the benchmark and
  Vinay's "push run").

## 5. Decisions needed from Vinay before build

1. **Selector style:** single grouped dropdown (compact, mobile-
   friendly) vs. a left-hand category list (desktop-POS feel). Recommend
   grouped dropdown — works on the tablet/phone many shops use.
2. **Default on open:** blank ("pick a report") vs. auto-select Sales
   Summary. Recommend blank — matches "select then Run".
3. **Export:** Print only for now, or also CSV export per report?
   (CSV is a small add but more build.)
4. **Itemised Sales depth:** full item list with qty/revenue/GST is
   in hand; do you also want per-item daily trend, or is the flat
   itemised list enough for v1?
5. **Keep the old "everything" view** anywhere (e.g. an "All / 
   Dashboard" pick), or fully replace with the picker?

Nothing is built until these 5 are answered. The catalog (§3) and
model (§2) are research-locked and benchmarked.
