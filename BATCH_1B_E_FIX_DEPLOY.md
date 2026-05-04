# Batch 1B-E-Fix — Restore Beta Banner Wiring (Hotfix)

**Status:** Hotfix for a regression caused by Batch 1B-E Combined.
**Risk:** Very low. Only adds a `<script>` tag; doesn't modify any existing logic.
**Time:** ~5 minutes deploy + 2 minutes verify.

---

## What Happened (My Mistake)

When I built Batch 1B-E Combined, I needed to apply the plan-name normalization fix to 5 pages: dashboard, customers, pos-admin, stock, team. To do that, I copied each file from `/home/claude/shopbillpro/extracted/shopbillpro/` (the **original codebase**) and edited the plan check.

**The original codebase files didn't have Batch 1B-A's beta banner wiring** — that was applied to a different working directory (`/home/claude/batch1b_a/`). When I shipped 1B-E Combined, those 5 pages got the plan fix but lost the banner wiring.

**Other pages weren't affected** because 1B-E Combined didn't touch them — they kept their 1B-A wiring intact.

The result you saw:
- ✅ Bills, Marketing, Billing, etc. (10 pages) — banner still showing
- ❌ Dashboard, Customers, POS Admin, Stock, Team (5 pages) — banner gone

This was my error. Fixing now.

---

## What This Batch Does

Adds a single line — `<script src="lib/beta-banner.js"></script>` right before `</body>` — to 6 pages:

1. `dashboard.html` — restore (was working pre-1B-E)
2. `customers.html` — restore
3. `pos-admin.html` — restore
4. `stock.html` — restore
5. `team.html` — restore
6. `subscription.html` — NEW (for consistency — the inline beta panel from 1B-E is great, but the topbar countdown banner shows on every other page so users navigating to Plans shouldn't see it disappear)

**Nothing else changes.** All 1B-E plan-name normalization fixes (the `if(plan === 'business' || isActiveBeta)` patches) are preserved exactly. I pulled the live-deployed versions from production as the base, so I built on top of what's already live.

---

## Files In This Batch

| File | Action | Diff size |
|---|---|---|
| `dashboard.html` | REPLACE | +2 lines (script tag + comment) |
| `customers.html` | REPLACE | +2 lines |
| `pos-admin.html` | REPLACE | +2 lines |
| `stock.html` | REPLACE | +2 lines |
| `team.html` | REPLACE | +2 lines |
| `subscription.html` | REPLACE | +2 lines |
| `service-worker.js` | REPLACE | bumped to v1.5.5 |

---

## Deploy Steps

### Step 1 — Replace 7 files in your repo

In your local repo, copy the 7 files from the ZIP to repo root, overwriting existing.

### Step 2 — Commit and push

```bash
git add dashboard.html customers.html pos-admin.html stock.html team.html subscription.html service-worker.js
git commit -m "Batch 1B-E-Fix: restore beta banner wiring on 5 pages + add to subscription.html"
git push
```

Wait ~60 sec for Vercel deploy.

---

## Verification

### Step 1 — Hard refresh the dashboard

Open `app.shopbillpro.in/dashboard.html` (or just navigate to dashboard via sidebar).

**If you're already logged in as your beta test shop "Viraj Enterprises":**
- ✅ Green countdown banner appears at top: "🎁 Free Beta — all features unlocked till 3 Jul 2026. No card needed."
- This is the same banner you see on Bills, Marketing, etc.

**If banner doesn't appear immediately:** browser cache. Force refresh with Ctrl+Shift+R or DevTools → Application → Service Workers → Unregister → reload.

### Step 2 — Click through all 6 affected pages

Navigate to each:
- Dashboard ✅ banner
- Customers ✅ banner
- POS Admin ✅ banner
- Inventory (Stock) ✅ banner
- Team & Users ✅ banner (and the page should still WORK — not show upgrade gate, since 1B-E plan-fix is preserved)
- Plans (Subscription) ✅ banner at top + green inline panel below ("🎉 You're in the ShopBill Pro Beta")

All 6 should now have the topbar countdown banner consistent with the other 10 pages.

### Step 3 — Confirm 1B-E Combined fixes survived

Go to Team & Users → should show actual team management UI, NOT "Multi-User Access — Upgrade to Business" gate.

If you see the upgrade gate, the plan-fix got reverted somehow. Tell me — should not happen.

---

## What This Doesn't Touch

- All other 10 pages (bills, billing, marketing, wa-center, cash-register, recurring, supplier, reports, settings, bill-templates) — their banners were already working
- `lib/beta-banner.js` — already deployed and working
- `lib/sidebar-engine.js` — Batch 1B-C lib patch state preserved (assuming you've deployed 1B-C; if not, no impact)
- Any other lib or script

---

## Rollback

```bash
git revert HEAD
git push
```

That removes the script tags from the 6 pages. Banner disappears from those pages again, but otherwise nothing breaks.

---

## After This Lands

You're back to where you should have been after Batch 1B-E Combined:

- ✅ Beta banner on all 16 user-facing pages (not just the 10 untouched-by-1B-E pages)
- ✅ Plan-name normalization fixes intact (Team & Users opens, etc.)
- ✅ Beta-aware upsells suppressed
- ✅ Subscription page has both topbar banner AND inline beta panel
- ✅ All 1B-A through 1B-E features working as documented

---

## I'm Sorry For The Regression

This was avoidable. When I copy-edited the 5 files in 1B-E Combined, I should have either:
1. Pulled the post-1B-A versions as base, OR
2. Pulled the live-deployed versions and edited those, OR
3. Done a diff-based patch instead of file replacement

I did file replacement from a stale source. Lesson logged: **for any batch that re-edits a file already modified in a prior batch, pull the live or post-prior-batch version as base, never the original codebase.**
