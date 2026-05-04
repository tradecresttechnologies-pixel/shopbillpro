# Batch 1B-B — Pricing Fix (Deploy Guide)

**Status:** Fixes the ₹199 → ₹499 stale Business plan pricing across HTML files and admin_settings DB.
**Risk:** Low. Pure number changes, no logic restructuring.
**Time:** ~10 minutes deploy + verify.

---

## What This Fixes

Your locked pricing strategy is **Free / Pro ₹99 / Business ₹499** but the codebase had stale `₹199` for Business in 7 places across 2 HTML files PLUS the `admin_settings` DB rows (which the page reads at runtime).

This batch updates everything to the correct locked values:

| Plan | Monthly | Yearly |
|---|---|---|
| Free | ₹0 | — |
| Pro | ₹99 | ₹990 (20% discount) |
| Business | **₹499** | **₹4,990** (20% discount) |

---

## What's In The ZIP

| File | Action |
|---|---|
| `pages/subscription.html` | REPLACE — 7 numeric edits (display, JS calc, payment amount, fallback) |
| `pages/team.html` | REPLACE — 1 edit (Upgrade to Business button text) |
| `service-worker.js` | REPLACE — bumped to v1.5.1 |
| `007_pricing_fix.sql` | RUN in Supabase SQL Editor — updates 4 admin_settings rows |

---

## Deploy Steps (3 parts)

### Part 1 — Replace HTML files in your repo

⚠️ **IMPORTANT — same lesson as Batch 1B-A**: copy individual files to repo root, **NOT the `batch1b_b/` folder itself**.

In your local repo:
1. Copy `pages/subscription.html` from the ZIP → overwrite `subscription.html` at repo root
2. Copy `pages/team.html` from the ZIP → overwrite `team.html` at repo root
3. Copy `service-worker.js` from the ZIP → overwrite `service-worker.js` at repo root
4. **Do NOT copy the `batch1b_b/` folder or `pages/` folder** into your repo

Commit and push:
```bash
git add subscription.html team.html service-worker.js
git commit -m "Batch 1B-B: fix Business plan pricing ₹199 → ₹499 (matches locked strategy)"
git push
```

Wait ~60 sec for Vercel deploy.

### Part 2 — Run SQL in Supabase

Open Supabase → SQL Editor → New query.

Open `007_pricing_fix.sql` from the ZIP, copy all contents, paste into Supabase, click **Run**.

You'll see TWO result sets:
- **First**: current pricing rows (probably showing some rows missing or with `199` / `1999`)
- **Second**: same rows after the update (must show `99`, `990`, `499`, `4990`)

If the second result set shows the 4 rows with correct values → DB is fixed.

### Part 3 — Save SQL to repo

Add the SQL to your repo for posterity:

```bash
# Save 007_pricing_fix.sql at db/migrations/007_pricing_fix.sql
git add db/migrations/007_pricing_fix.sql
git commit -m "Batch 1B-B: save pricing-fix migration"
git push
```

---

## Verification (4 quick checks)

### Check 1 — Subscription page shows ₹499

1. Open in incognito: `https://app.shopbillpro.in/subscription.html`
2. Look at the Business plan card

**Expected:** Business shows **₹499/month** (not ₹199). Subtitle should say "₹17/day · Best for shops with staff" (not ₹7/day).

### Check 2 — Yearly toggle shows correct yearly price

Click the **Yearly** toggle on subscription page.

**Expected:**
- Pro: ~₹79/month (= ₹990/12 with the 20% discount calculation)
- Business: ~₹399/month (= ₹4,990/12 with the 20% discount calculation)

The exact display logic computes from `bizM=499` and `bizY=Math.round(499*12*0.8/12) = 399`.

### Check 3 — Comparison table

Scroll down on subscription.html to "Full Feature Comparison" table.

**Expected:** column header shows **Biz ₹499** (not Biz ₹199).

### Check 4 — Team page upgrade button

Open: `https://app.shopbillpro.in/team.html`

**Expected:** Upgrade button text shows **"🏭 Upgrade to Business — ₹499/month"** (not ₹199).

### Check 5 — DevTools console diagnostic (optional)

On subscription.html, open DevTools console and run:

```js
console.log({
  biz_price_displayed: document.getElementById('biz-price')?.textContent,
  biz_per_day_displayed: document.getElementById('biz-per-day')?.textContent
});
```

**Expected:**
```js
{
  biz_price_displayed: "₹499",
  biz_per_day_displayed: "₹17/day · Best for shops with staff"
}
```

---

## What Happens If Verification Fails

| Symptom | Cause | Fix |
|---|---|---|
| Page still shows ₹199 | Browser cache | Hard refresh (Ctrl+Shift+R) or Unregister SW |
| Page shows blank/error | HTML edit corrupted file | `git revert HEAD && git push` |
| DB still shows 199 in admin_settings | SQL didn't run | Re-run `007_pricing_fix.sql` |
| Yearly shows wrong number | Dec point calc wrong | Check console for JS errors |

---

## Rollback

```bash
git revert HEAD
git push
```

For the SQL revert (if needed):
```sql
UPDATE admin_settings SET value = '199' WHERE key = 'plan_business_monthly';
UPDATE admin_settings SET value = '1999' WHERE key = 'plan_business_yearly';
```

(But you almost certainly don't want to revert — ₹199 was the bug, ₹499 is the correct value per your locked strategy.)

---

## After This Batch

Real pricing is now live. Your subscription page accurately reflects what shopkeepers will pay.

Remaining items deferred from 1B-B (per honest discussion):
- **Hindi/Hinglish localization** on billing.html, subscription.html, team.html — deferred until proper user research informs the strategy. Skipping make-believe localization is the right call.

Next batches you can pick when ready:
- **1B-D**: Signup wizard wiring (medium risk)
- **1B-E**: Subscription page beta-mode display (medium risk)
- **1B-C**: Sidebar engine standardization (high risk, save for last)
- **1B-F**: Mobile hamburger drawer (depends on 1B-C)

But honestly — after this deploys cleanly, **stop and sleep**. You've shipped real value tonight: full Batch 1A foundation, beta banner wiring, and now the pricing fix. That's a complete sprint by any measure.
