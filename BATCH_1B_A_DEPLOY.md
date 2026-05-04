# Batch 1B-A — Beta Banner Wiring (Deploy Guide)

**Status:** Net-additive changes. Adds beta countdown banner to 16 user-facing pages.
**Risk:** Low. Worst case = banner doesn't render (no impact on existing functionality).
**Time:** ~10 minutes deploy + verify.

---

## What This Batch Does

For shopkeepers who signed up during the 60-day beta period, every user-facing page now shows a colored countdown banner immediately above the topbar:

- **8+ days left**: green/calm — "Free Beta — all features till {date}"
- **4–7 days left**: amber/warning — "Beta ends in X days. Pick a plan."
- **1–3 days left**: orange — "Only X days left."
- **Last day**: red/pulsing — "Last day! Your data is safe."
- **In grace (Day 61–67)**: purple — "Beta ended. Read-only. Choose plan."

For non-beta shopkeepers (`is_beta_signup = false`), nothing renders — they see no change.

---

## Files In This Batch

| File | Type | Notes |
|---|---|---|
| `service-worker.js` | REPLACE | Bumped to v1.5.0 |
| `lib/beta-banner.js` | REPLACE | Updated to use `#sbpBetaBanner` placeholder, removed sticky positioning |
| 16 user-facing HTML files | MODIFY | 2 line additions each |

The 16 modified pages:
`bill-templates.html`, `billing.html`, `bills.html`, `cash-register.html`, `customers.html`, `dashboard.html`, `marketing.html`, `pos-admin.html`, `recurring.html`, `reports.html`, `settings.html`, `stock.html`, `subscription.html`, `supplier.html`, `team.html`, `wa-center.html`

**Skipped:** `index.html` (login/signup page — no topbar, no logged-in shop, banner wouldn't render anyway).

---

## Deploy Steps

### Step 1 — Backup your current repo

Just in case. Right-click your local `shopbillpro` folder → Compress → save as `shopbillpro-pre-1ba.zip`.

### Step 2 — Copy files into your repo

From the `batch1b_a` folder in this zip:

| Source | Destination in your repo |
|---|---|
| `lib/beta-banner.js` | `lib/beta-banner.js` ⚠️ **REPLACES existing** |
| `service-worker.js` | `service-worker.js` ⚠️ **REPLACES existing** |
| `pages/bill-templates.html` | `bill-templates.html` ⚠️ **REPLACES existing** |
| `pages/billing.html` | `billing.html` ⚠️ **REPLACES existing** |
| `pages/bills.html` | `bills.html` ⚠️ **REPLACES existing** |
| `pages/cash-register.html` | `cash-register.html` ⚠️ **REPLACES existing** |
| `pages/customers.html` | `customers.html` ⚠️ **REPLACES existing** |
| `pages/dashboard.html` | `dashboard.html` ⚠️ **REPLACES existing** |
| `pages/marketing.html` | `marketing.html` ⚠️ **REPLACES existing** |
| `pages/pos-admin.html` | `pos-admin.html` ⚠️ **REPLACES existing** |
| `pages/recurring.html` | `recurring.html` ⚠️ **REPLACES existing** |
| `pages/reports.html` | `reports.html` ⚠️ **REPLACES existing** |
| `pages/settings.html` | `settings.html` ⚠️ **REPLACES existing** |
| `pages/stock.html` | `stock.html` ⚠️ **REPLACES existing** |
| `pages/subscription.html` | `subscription.html` ⚠️ **REPLACES existing** |
| `pages/supplier.html` | `supplier.html` ⚠️ **REPLACES existing** |
| `pages/team.html` | `team.html` ⚠️ **REPLACES existing** |
| `pages/wa-center.html` | `wa-center.html` ⚠️ **REPLACES existing** |

> The `pages/` subfolder in the ZIP is just for organization — files go to repo **root**, not into a `pages/` folder.

### Step 3 — Commit and push

```bash
git add lib/beta-banner.js service-worker.js \
  bill-templates.html billing.html bills.html cash-register.html \
  customers.html dashboard.html marketing.html pos-admin.html \
  recurring.html reports.html settings.html stock.html \
  subscription.html supplier.html team.html wa-center.html

git commit -m "Batch 1B-A: wire beta countdown banner into 16 user-facing pages"
git push
```

### Step 4 — Wait for Vercel deploy (~60 sec)

Watch the Vercel dashboard. Green checkmark = ready.

---

## Verification

### Verify 1: Site still works (non-beta user)

Open in incognito: `https://app.shopbillpro.in/dashboard.html`
- Log in as your normal user (the one in your live DB whose `is_beta_signup` is `false`)
- Dashboard should load normally
- **No banner should appear** — because you're not a beta signup

If you see anything weird (broken layout, console errors), screenshot and we'll debug.

### Verify 2: Service worker updated

DevTools → Application → Service Workers
- Old: `shopbillpro-v1.4.0-20260504` should be redundant
- New: `shopbillpro-v1.5.0-20260504-1ba` should be activated

If still showing v1.4.0, click **Unregister** then reload — fresh SW will install.

### Verify 3: Banner shows for beta-flagged shops

Pick one of your 4 existing test shops in Supabase to flag as a beta signup, just for testing:

```sql
-- Pick any existing shop ID
SELECT id, name, plan, is_beta_signup, plan_expires_at FROM shops LIMIT 4;

-- Flag one as a beta signup (replace SHOP_ID with a real UUID)
UPDATE shops 
SET is_beta_signup = true,
    plan = 'business',
    plan_expires_at = now() + interval '30 days',
    beta_grace_until = now() + interval '37 days',
    plan_pre_beta = 'free'
WHERE id = 'SHOP_ID_HERE';
```

Now log in as that shop's owner. You should see a green banner at the top:

> 🎉 Free Beta — all features till [date]. No card needed.       [Learn more] [×]

Click around — banner appears on every page consistently. Click the × to dismiss (only the calm "active" tone is dismissable; urgent ones are not).

### Verify 4: Test different banner tones

```sql
-- Test "ending in 7 days" (amber/warning)
UPDATE shops SET plan_expires_at = now() + interval '5 days' WHERE id = 'SHOP_ID';

-- Test "ending in 3 days" (orange)
UPDATE shops SET plan_expires_at = now() + interval '2 days' WHERE id = 'SHOP_ID';

-- Test "last day" (red/pulsing)
UPDATE shops SET plan_expires_at = now() + interval '12 hours' WHERE id = 'SHOP_ID';

-- Test "in grace" (purple)
UPDATE shops SET 
  plan_expires_at = now() - interval '2 days',
  beta_grace_until = now() + interval '5 days'
WHERE id = 'SHOP_ID';
```

After each UPDATE, refresh dashboard.html — banner color/text should change.

### Verify 5: Reset the test shop

```sql
-- Restore the test shop to its original non-beta state
UPDATE shops SET 
  is_beta_signup = false,
  plan = 'free',
  plan_expires_at = NULL,
  beta_grace_until = NULL,
  plan_pre_beta = NULL
WHERE id = 'SHOP_ID_HERE';
```

---

## What To Watch For

| Symptom | Likely cause | Fix |
|---|---|---|
| Banner shows but topbar overlaps | Old SW serving cached old beta-banner.js | Hard refresh (Ctrl+Shift+R) or Unregister SW |
| Banner doesn't show for beta user | `window._sb` not set on that page | Check browser console for errors |
| Banner shows on wrong pages | shop's `is_beta_signup` was incorrectly set | Reset via SQL Verify 5 |
| Page rendering broken (white screen) | HTML edit corrupted the file | Roll back: `git revert HEAD && git push` |

---

## Rollback

If anything goes wrong:

```bash
git revert HEAD
git push
```

Vercel auto-deploys the revert. Your site is back to pre-1B-A state in ~60 seconds. The DB schema changes from Batch 1A stay (they're harmless when no code references them).

---

## After This Sub-Batch

Once 1B-A is deployed and verified, the next sub-batches are:

- **1B-B** — Hindi spans backfill on `billing.html`, `subscription.html`, `team.html` (low risk)
- **1B-D** — Signup wizard wiring + `apply_beta_plan()` call in `index.html` (medium risk)
- **1B-E** — Subscription page beta mode display (medium risk)
- **1B-C** — Sidebar engine standardization across 16 pages (high risk, deferred)
- **1B-F** — Mobile hamburger drawer (depends on 1B-C)

Reply **"start 1B-B"** when you're ready for the next one. Each sub-batch is a separate session with its own deploy + verify cycle.

---

## What Was Quietly Improved

While building 1B-A, I noticed the lib originally used `position: sticky; top: 0` on the banner host — which would have **overlapped with the existing sticky topbar**. The lib has been updated to render into a placeholder div above the topbar (no sticky positioning), so the banner sits naturally above the topbar and scrolls away with content. The topbar's existing sticky behavior is unchanged.

This is exactly what the audit-first approach catches.
