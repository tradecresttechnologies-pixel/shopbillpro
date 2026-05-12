# Batch 022D-C Stage 2 — audit-log.html (operator-facing viewer)

**Prerequisites:** 022D-A + 022D-B deployed. Some audit log entries
must exist (any high-risk action since 022D-A was deployed will have
generated entries; the smoke tests from prior batches alone are enough
to verify the viewer works).

**Scope:** One new standalone HTML file. No SQL. Uses the existing
`sbp_audit_log_query` RPC from migration 031.

---

## What's in this stage

**Files (1 new):**
```
audit-log.html   ← standalone owner-facing viewer
```

---

## What the page does

1. **Summary cards** (top, 4 across desktop / 2 across mobile):
   - **Total** — all-time count of audit entries for this shop
   - **PIN-auth** — count of entries with `auth_method='pin'` in last 7 days
   - **Today** — count from start of today (IST)
   - **7 days** — count from 7 days ago

   These come from a separate fetch capped at 500 recent entries so the
   numbers don't change as you paginate. The "Total" is the absolute
   total from the server.

2. **Filters:**
   - **Action chips** — All / Booking cancel / Extras remove / Payment void / Bill void (all 4 currently-wired action codes; future codes need adding to ACTION_CATALOG)
   - **Date range** — From / To inputs (inclusive)
   - **Clear button** to reset all filters

3. **Entry list:**
   - Card-style rows with: action icon + name, relative time (with absolute time on hover via title attr), auth-method badge, actor name, "authorized by ..." note when authorizer differs from actor, optional reason quote.
   - Auth method tag color-coded: PIN (orange), Owner session (purple), Master (red), None (gray).
   - Click any entry to open detail modal.

4. **Detail modal:**
   - Full metadata grid (action code, actor, actor ID, auth method, authorized-by, target table/ID, reason)
   - **Changes table** — auto-generated diff of `before_json` vs `after_json`. Skips noisy columns (`updated_at`, `created_at`). Changed rows highlighted; before in red, after in green. Long values truncated with ellipsis.
   - **"Show raw JSON"** toggle for power users — full entry object, prettified.

5. **Pagination** — 50 entries per page, Prev/Next buttons hidden when total ≤ 50.

6. **CSV export** — top-right 📥 button. Exports CURRENT PAGE (current filters applied) as `audit-log-YYYY-MM-DD.csv` with 8 columns (recorded_at, action_code, actor_name, auth_method, authorized_by_name, target_table, target_id, reason). Proper CSV escaping for commas/quotes/newlines.

7. **Bilingual EN/HI, dark/light theme, mobile responsive.**

---

## Deploy

1. Push `audit-log.html` via GitHub Desktop
2. Bump SW version (e.g. v1.5.25 → v1.5.26)
3. Open `https://app.shopbillpro.in/audit-log.html` while signed in as
   the shop owner

No link yet from reports.html or sidebar — direct URL for now. Adding
links comes later when you upload `reports.html` or update the sidebar
catalog.

---

## Smoke test

### 1. Page loads, shows past entries

Open the page. Expected:
- Topbar "Audit Log" + back/export/lang/theme buttons
- 4 summary cards with non-zero numbers (assuming you ran 022D-B
  smoke tests — those generated audit entries)
- Filter row with chips: All / Booking cancel / Extras remove / Payment void / Bill void
- Date inputs (empty by default)
- Entry list showing most-recent first

If you see "Access denied" — confirm you're signed in as the shop owner.
If you see "No matching entries" — likely no actions have been performed
yet; do any high-risk action from folio.html or bookings.html and reload.

### 2. Click on any entry

Should open detail modal showing:
- Action label + relative time + absolute time
- Metadata grid (action code, actor, auth method, target table/ID, reason)
- Changes table with before/after columns
- "Show raw JSON" toggle

Click outside the modal or the X to close.

### 3. Filter by action

Click "Extras remove" chip. List filters to only extras.remove entries.
Summary cards do NOT recalculate (they're 7-day overview, intentional).
Pagination updates if applicable.

Click "All" chip to reset.

### 4. Filter by date range

Set "From" = today. List should narrow to today only. Pagination
updates.

Click ✕ to clear filters.

### 5. CSV export

With some entries visible, click the 📥 icon. Browser downloads
`audit-log-2026-05-12.csv`. Open it — should be valid CSV with 8
columns, headers in row 1, properly quoted strings with commas.

### 6. Pagination (only if you have >50 entries)

If your shop has more than 50 audit entries (probably not yet —
build over time), scroll down to the Prev/Next pager. Click Next.
Should fetch the next 50 and scroll to top.

### 7. Bilingual + theme

Click अ — labels switch to Hindi. Click again — back to English.
Click ☀️/🌙 — theme toggles, preserved across reloads.

### 8. Generate a fresh test entry, see it appear

In another tab, go to folio.html, void a payment or remove an extra
(use Test Manager PIN `1234` if `require_auth_for_high_risk` is on).

Refresh `audit-log.html` — the new entry should be at the top, marked
"just now".

---

## Pass criteria

- ✅ Page loads, lists past entries
- ✅ Summary stats show non-zero numbers (assuming prior batches ran)
- ✅ Click on entry → detail modal with diff table
- ✅ Action filter chips narrow the list
- ✅ Date filter narrows the list
- ✅ CSV export downloads a valid file
- ✅ Bilingual + theme toggle work
- ✅ Fresh action shows up after reload

---

## With this, 022D is fully complete 🎉

| Stage | What | Status |
|---|---|---|
| 022D-A | Foundation (tables, RPCs, auth-pin modal) | ✅ Done |
| 022D-B-1, B-2, B-3 | Server-side gates + frontend wiring on 4 high-risk RPCs | ✅ Done |
| 022D-C-1 | Authorized Users CRUD page | ✅ Done |
| 022D-C-2 | Audit Log viewer | 📦 This stage |
| 022D-C-3 | team.html migration UI | ✅ Done |

The full authorization + audit + UI story is now end-to-end:

- Shop owner adds managers/staff with PINs via `authorized-users.html`
- Owner can flip `require_auth_for_high_risk` from the UI
- Voiding a bill, canceling a booking, removing a charge, or voiding
  a payment requires a manager PIN (when auth flag is on)
- Every high-risk action gets audit-logged server-side with
  before/after state, reason, and authorizer identity
- Owner reviews who did what via `audit-log.html`
- Legacy localStorage PINs can be migrated to cloud via `team.html`

---

## Next priorities (from master roadmap)

1. **Link audit-log + authorized-users from sidebar/settings/reports** —
   small wiring task; needs latest `settings.html` + `reports.html` +
   `lib/sidebar-engine.js` upload from you
2. **022E** Vertical-Aware Sidebar (~1.5h)
3. **021B-C** Hotel KPIs (occupancy / ADR / RevPAR) (~2h)
4. **028A** App-wide print stylesheet audit (~2-3h)
5. Vertical polishing → Pre-beta QA → **BETA LAUNCH** 🚀

Ready for whichever you want next.
