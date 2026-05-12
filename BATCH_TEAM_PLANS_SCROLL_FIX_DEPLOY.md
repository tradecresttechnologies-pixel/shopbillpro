# Hotfix: Team + Plans sidebar stability

**Reported:** "team and plan side bar not stable rest working fine"

**Root cause found:** Two pages — `team.html` and `subscription.html` —
were missing `overflow-y:auto` on the `.dsb-nav` CSS rule. Every other
page in the app has it.

Without that one rule, the inner nav container can't scroll inside
itself. When the sidebar content (logo + 16+ nav items + footer)
exceeds the viewport height, items at the bottom get **clipped out
of view**. The scroll-position-preserve fix from the prior batch had
nothing to scroll, so it appeared to do nothing.

The other 020+ pages in the app all have `.dsb-nav { ...; overflow-y:auto }`
in their inline CSS, which is why the user said "rest working fine".

---

## Audit confirmed only 2 pages need the fix

Ran a sweep across all `*.html` files in the repo. Only `team.html`
and `subscription.html` were missing the rule. All other pages
(`compliance.html`, `bills.html`, `customers.html`, `reports.html`,
`stock.html`, `pos-admin.html`, `marketing.html`, `wa-center.html`,
`recurring.html`, `supplier.html`, `cash-register.html`, `dashboard.html`,
`billing.html`, etc.) already had it.

## The fix

**One-line CSS change** in each file. Append `;overflow-y:auto` to the
existing `.dsb-nav` rule:

**team.html** line 88:
```diff
- .dsb-nav{flex:1;padding:8px;display:flex;flex-direction:column;gap:2px}
+ .dsb-nav{flex:1;padding:8px;display:flex;flex-direction:column;gap:2px;overflow-y:auto}
```

**subscription.html** line 139: same change.

No JS, no SQL, no other CSS — just the single property added in each.

---

## Files

```
team.html           ← 1 character difference (added "y:auto" to overflow)
subscription.html   ← same
```

## Deploy

1. Push both files via GitHub Desktop
2. Bump SW (v1.5.31 → v1.5.32) so PWA clients re-fetch
3. Hard-refresh

---

## Smoke test

### 1. Navigate to Team (from More group)

a) On dashboard.html, click "More ⚙️" → click "Team"
b) Page navigates to team.html
c) Sidebar should now have Team highlighted **and visible** (not
   clipped below the fold)
d) Nav items at the top (Home, Bills, ...) should still be there
   if you scroll up within the sidebar

### 2. Navigate to Plans

Same flow with "Plans" → subscription.html. Sidebar should remain
fully scrollable + the active item visible.

### 3. Verify no regression on other pages

Visit any other page (Bills, Customers, Reports, etc.). Sidebar
should behave exactly as before (it already had overflow-y:auto).

---

## Why this happened

Speculation: `team.html` and `subscription.html` were among the
earliest pages built in the app — possibly before the CSS pattern
was standardized. Other pages were either built later or got
updated as part of the BATCH 1B-C sidebar consolidation. These
two were missed.

For consistency going forward, every new page that includes the
sidebar pattern should have the full CSS block (matching
`compliance.html` as the reference template). Worth a separate
audit pass eventually to standardize the entire CSS block, not just
this one property.

---

## Pass criteria

- ✅ Team item visible & highlighted when on team.html
- ✅ Plans item visible & highlighted when on subscription.html
- ✅ Sidebar scrollable inside itself on both pages
- ✅ Other pages unchanged

---

## Next priorities (unchanged)

- 021B-C Hotel KPIs (~2h)
- 028A Print stylesheet audit (~2-3h) — possibly bundle with a
  broader CSS-consistency audit since we just found a divergence
- Pre-beta QA → BETA LAUNCH 🚀
