# Batch 1B-E — Beta-Mode Display (Deploy Guide)

**Status:** Suppresses upsell popups for active beta users. Adds beta status panel to Plans page. Fixes pre-existing bug in `upgrade-popup.js`.
**Risk:** Low-Medium. Changes plan-detection logic in 2 shared scripts. Affects 12 pages.
**Time:** ~10 minutes deploy + 10 min verify.

---

## What This Batch Fixes

After 1B-D, beta users were getting hit with these inappropriate upsells:

- 🚨 "Imagine losing all this in one second..." modal popup
- 🔒 "Your shop data is not protected — Enable cloud backup for ₹3/day" topbar banner
- "Upgrade to Pro" milestone popup after every 25 bills
- "You're a heavy user!" popup after 14 days
- "Save 20%" annual discount popup
- "Upgrade to Pro" CTAs on the Plans page (confusing — they already have Business via beta)

**All gone after 1B-E.** Beta users get a clean experience with just the green countdown banner from 1B-A.

---

## Root Cause (For The Record)

Two files defined `isPro()` independently, both with bugs:

| File | Old logic | Bug |
|---|---|---|
| `conversion.js` | `s.plan === 'pro' \|\| s.plan === 'enterprise'` | Doesn't recognize `'business'` (which is what 1B-D creates) or beta state |
| `upgrade-popup.js` | `localStorage.getItem('sbp_plan')` | Reads a key that doesn't exist — function effectively always returned `false` |

Both have been replaced with logic that reads the canonical `localStorage.sbp_shop` and recognizes:
- Active beta signups (within `plan_expires_at`)
- Beta in grace period (within `beta_grace_until`)
- All paid plans: pro, enterprise (legacy), business

---

## Files In This Batch

| File | Action | Notes |
|---|---|---|
| `conversion.js` | REPLACE | `isPro()` patched (~10 line delta) |
| `upgrade-popup.js` | REPLACE | `isPro()` rewritten + reads correct storage key |
| `subscription.html` | REPLACE | Beta panel placeholder + new `_fmtBetaDate`, `_injectBetaPanel`, `updatePlanUI` |
| `service-worker.js` | REPLACE | Bumped to v1.5.3 |

**Pages affected (no edits, but cache refresh needed):** All 12 pages that load `conversion.js` and `upgrade-popup.js` — billing, bills, customers, dashboard, marketing, pos-admin, recurring, reports, settings, stock, supplier, wa-center.

---

## Deploy Steps

### Step 1 — Replace 4 files in your repo

⚠️ Same lesson: copy individual files to repo root, NOT the `batch1b_e/` folder.

In your local repo:
1. Copy `conversion.js` → repo root `conversion.js` (overwrite)
2. Copy `upgrade-popup.js` → repo root `upgrade-popup.js` (overwrite)
3. Copy `pages/subscription.html` → repo root `subscription.html` (overwrite)
4. Copy `service-worker.js` → repo root `service-worker.js` (overwrite)

### Step 2 — Commit and push

```bash
git add conversion.js upgrade-popup.js subscription.html service-worker.js
git commit -m "Batch 1B-E: beta-aware upsell suppression + Plans page beta panel"
git push
```

Wait ~60 sec for Vercel deploy.

---

## Verification

### Test 1 — Beta user on dashboard (the main fix)

1. Sign up a fresh test account (use a new email, e.g. `youremail+1betest@gmail.com`)
2. Pick any business type in the wizard, land on dashboard

**Expected on dashboard:**
- ✅ Green beta banner above topbar (from 1B-A): "🎉 Free Beta — all features unlocked till [date]"
- ❌ NO "Your shop data is not protected" banner (was showing before 1B-E)
- ❌ NO "Imagine losing all this in one second..." modal (was showing before 1B-E)
- ❌ NO milestone popups when clicking around

If you signed up the test shop and this all matches → primary 1B-E goal achieved.

### Test 2 — Beta user on Plans page

Click "Plans" or "🚀 Plans" in the sidebar.

**Expected:**
- ✅ Green panel appears above the 3 plan cards: **"🎉 You're in the ShopBill Pro Beta"**
- ✅ Body says "All Business-plan features unlocked free until [date]. After beta ends, choose any plan below..."
- ✅ Business card CTA reads **"✅ Active (Beta)"** (not "Upgrade to Business")
- ✅ Pro card CTA reads **"Choose Pro after beta"**
- ✅ Free card CTA reads **"Stay on Free after beta"**
- ✅ Pricing display shows ₹499 Business / ₹99 Pro (from 1B-B)

### Test 3 — Existing free users unchanged

Log in as one of your existing test shops (the ones that aren't beta — `is_beta_signup = false`).

**Expected:**
- ❌ NO green beta panel on Plans page (correct — not beta)
- ✅ Existing upsell behavior on dashboard (cloud backup banner shows because they're on Free)
- ✅ Existing CTAs on Plans page based on actual plan
- This is unchanged behavior for non-beta users

### Test 4 — Grace period edge case

Simulate beta-just-ended-but-in-grace:

```sql
-- Pick the test shop from Test 1
UPDATE shops 
SET plan_expires_at = now() - interval '1 day',
    beta_grace_until = now() + interval '5 days'
WHERE id = 'YOUR_TEST_SHOP_ID';
```

In dashboard tab, run in DevTools console:
```js
localStorage.removeItem('sbp_shop'); 
location.reload();
```

(This forces a fresh fetch of the shop record so localStorage gets the updated values.)

**Expected:**
- ✅ Banner from 1B-A shows in purple "Beta ended — your data is safe" tone
- ✅ Plans page panel shows in purple tone with grace expiry date
- ✅ CTAs revert to normal upgrade flow (so user can pick a plan to continue)
- ✅ Upsells suppressed (still in grace window)

### Test 5 — Fully expired beta

```sql
UPDATE shops 
SET plan_expires_at = now() - interval '10 days',
    beta_grace_until = now() - interval '3 days',
    plan = 'free',
    is_beta_signup = false
WHERE id = 'YOUR_TEST_SHOP_ID';
```

DevTools console: `localStorage.removeItem('sbp_shop'); location.reload();`

**Expected:**
- ❌ No banner (correct — expired)
- ❌ No beta panel on Plans page
- ✅ Upsells return (correct — user is on Free now)
- ✅ Plans page shows "Upgrade to Pro" / "Upgrade to Business" CTAs again

### Test 6 — Cleanup

Delete the test shop after verification:

```sql
DELETE FROM shops WHERE id = 'YOUR_TEST_SHOP_ID';
```

Plus delete the auth user via Supabase dashboard.

---

## Diagnostic Console Commands

If anything looks off, run these in DevTools:

### On dashboard (any page that loads conversion.js):
```js
console.log({
  conversion_js_loaded: !!window.SBPConversion,
  upgrade_popup_loaded: typeof window.SBPUpgradePopup !== 'undefined',
  shop_in_storage: JSON.parse(localStorage.getItem('sbp_shop') || 'null'),
  // Manual call to verify isPro returns true for beta users
  // (won't work as-is since isPro is internal, but check shop fields):
});
```

The key thing to look at: `shop_in_storage` should have `is_beta_signup: true`, `plan: 'business'`, and a future `plan_expires_at`.

### On subscription.html:
```js
console.log({
  beta_panel_exists: !!document.getElementById('beta-mode-panel'),
  beta_panel_visible: document.getElementById('beta-mode-panel')?.style.display,
  beta_panel_has_content: (document.getElementById('beta-mode-panel')?.innerHTML.length || 0) > 100,
  biz_cta_text: document.getElementById('biz-cta')?.textContent
});
```

For a beta user expected: `beta_panel_visible: 'block'`, `beta_panel_has_content: true`, `biz_cta_text: '✅ Active (Beta)'`.

---

## What To Watch For

| Symptom | Likely cause | Fix |
|---|---|---|
| Upsells still show for beta user | Service worker hasn't refreshed | Hard refresh (Ctrl+Shift+R) or DevTools → Application → Service Workers → Unregister → reload |
| Beta panel doesn't appear on Plans | localStorage shop has stale data | DevTools console: `localStorage.removeItem('sbp_shop'); location.reload();` (forces fresh fetch from Supabase) |
| Date shows "Invalid Date" in panel | Server returned `plan_expires_at` in unexpected format | Open DevTools console, look for the actual value of `shop.plan_expires_at` |
| Free user no longer sees upsells | Bug in 1B-E logic | This shouldn't happen — Free users have `is_beta_signup: false` and `plan: 'free'`, which both fail the new `isPro()` checks. Report if observed. |

---

## Rollback

```bash
git revert HEAD
git push
```

That reverts all 4 files to their pre-1B-E state. Beta users go back to seeing inappropriate upsells, but nothing breaks.

---

## After 1B-E

The complete pre-launch beta acquisition + retention path now works:

```
1A    → DB foundation (shop_type, beta tracking, SEO admin)
1A-fix → schema correction
006   → admin Settings hotfix
1B-A  → Beta countdown banner on every page
1B-B  → Pricing fix ₹199 → ₹499
1B-D  → Signup wizard + auto-beta-plan activation
1B-E  → Upsell suppression + Plans page beta panel  ← JUST SHIPPED
```

When CIN comes through and you flip beta to public:
1. Shopkeeper signs up → wizard captures their type → 60-day Business beta auto-activated
2. They see green countdown banner on every page (no upsell pressure)
3. Plans page shows "You're in beta" panel with their expiry date
4. On Day 53/56/59, banner color shifts to amber/orange/red urgency
5. After Day 60, 7-day grace begins (purple tone, read-only access)
6. After Day 67, auto-downgrade to Free with watermark (unless they paid)

That's the complete launch path.

### Remaining 1B sub-batches (all polish, none blocking):

- **1B-C**: Sidebar engine standardization across 16 pages — high risk, requires dedicated session + 24h pilot soak
- **1B-F**: Mobile hamburger drawer — depends on 1B-C
- **1B-G** (newly identified): Fix `localStorage.sbp_pending_shop` resume logic for email-confirm signups

### Housekeeping (5 min total when you're rested):

- Save `006_admin_settings_hotfix.sql` and `007_pricing_fix.sql` to `db/migrations/` in your repo
- Update `admin-auth.js` `MASTER_PASSWORD_HASH` constant with SHA-256 of your new master password
