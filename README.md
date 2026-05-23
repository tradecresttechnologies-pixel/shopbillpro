# ShopBillPro · v7 Hotfix — Plan-helpers in running-order.html

**Bundle:** `ShopBillPro_v7_hotfix_plan_helpers.zip`
**Date:** 23-May-2026
**Severity:** P0 — `running-order.html` cannot load (ReferenceError aborts init)
**Scope:** 1 file changed. 4 lines added. No SQL.

---

## DEPLOY PATHS

| Action  | Repo path             | Notes                                                  |
|---------|-----------------------|--------------------------------------------------------|
| REPLACE | `running-order.html`  | Adds `isBiz()`, `isBusiness()`, `isFree()` to the inline plan-helper block in `<head>`. Matches the canonical pattern used by `dashboard.html` and 19 other pages. |

No other files touched. No CSS, no JS lib, no SQL.

---

## Root cause (audit summary)

The v7 commit `1b74072 "running"` shipped a new `running-order.html` whose inline `<head>` plan-helper block defined only:

```js
function _sbpPlanInfo(){ ... }
function isPro(){ ... }
```

But `init()` at line 2341 calls `isBiz()`:

```js
if(!isBiz()){
  document.body.innerHTML='<div ...>Upgrade to Business</div>';
  return;
}
```

`isBiz` was never defined in scope → `ReferenceError: isBiz is not defined` → `init()` aborts before menu fetch and before `sbp_ro_open` call → "Loading menu…" placeholder never resolves → toast "Error loading running order" fires.

Every other page that gates by Business plan (`dashboard.html`, `billing.html`, `bills.html`, `customers.html`, `audit-log.html`, `team.html`, `reservations.html`, `restaurant-reports.html`, `menu.html`, `stock.html`, `loyalty.html`, `appointments.html`, `services.html`, `reports.html`, `recurring.html`, `compliance.html`, `bookings.html`, `folio.html`, `front-desk.html`, `rooms.html`, `walk-in.html`) defines all four helpers inline. `running-order.html` got 2 of the 4 by mistake.

## The fix (4 lines added in `<head>`)

Before:
```js
function isPro(){const p=_sbpPlanInfo().plan;return p==='pro'||p==='business';}
</script>
```

After:
```js
function isPro(){const p=_sbpPlanInfo().plan;return p==='pro'||p==='business';}
function isBiz(){return _sbpPlanInfo().plan==='business';}
function isBusiness(){return _sbpPlanInfo().plan==='business';}
function isFree(){return _sbpPlanInfo().plan==='free';}
</script>
```

Pasted at line 19, before `</script>`. No other changes to the file.

---

## Deploy steps

1. Replace `running-order.html` at repo root with the file in this bundle.
2. Commit + push to GitHub (Vercel auto-deploys).
3. Wait ~2–10 min for Vercel edge cache to flush.
4. Hard-refresh the table-pos page (Ctrl+Shift+R) to bust the local cache.

---

## Verification (after deploy)

1. Open `app.shopbillpro.in/running-order?table_id=<any open table>`
2. **Console tab** — no red `ReferenceError`.
3. **Page** — menu items load (no permanent ⏳ "Loading menu…").
4. **Right rail** — "Build the first order" empty state shows for a fresh table; existing KOTs render for tables with running orders.
5. Toast "Error loading running order" no longer appears.

If you see the menu list but tapping items does nothing or 500s, that's a different bug — file separately.

---

## Migration 100 — separate check, not blocked by this hotfix

The v7 commit also added `db/migrations/100_bill_split_merge.sql`. The hotfixed `running-order.html` calls these RPCs:

- Line 4976: `sbp_ro_split_equal`
- Line 4985: `sbp_ro_split_custom`
- Line 5010: `sbp_ro_split_by_item`
- Line 5052: `sbp_ro_list_open`
- Line 5125: `sbp_ro_merge_into`
- Line 5145: `sbp_ro_move_item`

All six are defined only in migration 100. They are only invoked when the user taps **Split Bill** or **Merge / Move** in the action rail — the page itself loads fine without them.

**If migration 100 has not been run in Supabase SQL Editor yet:**
- ✅ Page loads, menu renders, Add Order / By KOT / By Item all work — this hotfix is enough.
- ❌ Tapping Split Bill or Merge / Move will fail with `PGRST202 — function ... does not exist`.

Verify by running this in Supabase SQL Editor:

```sql
SELECT proname FROM pg_proc WHERE proname LIKE 'sbp_ro_split%' OR proname LIKE 'sbp_ro_merge%' OR proname = 'sbp_ro_list_open' OR proname = 'sbp_ro_move_item';
```

Expected: 6 rows. If you get 0, run `db/migrations/100_bill_split_merge.sql` end-to-end.

---

## Rollback

Revert to the previous `running-order.html` from commit `9f0143a "update"` (the pre-v7 file). No DB rollback needed.

---

## Why this slipped through

The previous session generated v7 `running-order.html` from scratch and authored a custom `<head>` block instead of copying the canonical block from `dashboard.html`. The two functions that were defined (`_sbpPlanInfo`, `isPro`) happen to be what the v7 split/merge code paths use, so the author tested those paths and they worked — but the plan-gate at line 2341 (the very first thing `init()` does) was never exercised in dev because dev was running on the Business beta where the gate is a no-op visually. Lesson: when copying boilerplate from one page to another, copy the **whole** block, not the subset that "looks needed."

