# Batch 1B-D — Signup Wizard + Beta Plan Activation (Deploy Guide)

**Status:** Wires the shop-type wizard into the signup flow + auto-applies 60-day beta plan to new signups.
**Risk:** Medium. Touches signup path. Existing logged-in users completely unaffected.
**Time:** ~10 minutes deploy + 10 min verify.

---

## What This Batch Does

When a brand-new user signs up:

1. Auth signup completes (Supabase creates user account)
2. **NEW:** Wizard modal appears → user picks business type from 80+ options across 12 categories
3. Shop record is created in DB with `shop_type` field set to user's choice
4. **NEW:** `apply_beta_plan(shop_id)` RPC runs → shop becomes a beta signup (60 days Business plan + 7-day grace)
5. localStorage gets the updated shop with beta fields
6. User lands on dashboard → green beta banner appears (from Batch 1B-A)

Skip path: if user clicks "Skip for now" in wizard, defaults to `shop_type = 'general_retail'` and **still gets the beta plan** (we discussed this — beta is your value prop, don't penalize skip).

---

## Files In This Batch

| File | Action | Notes |
|---|---|---|
| `index.html` | REPLACE | +62 lines: wizard wiring + beta plan call + helper |
| `service-worker.js` | REPLACE | Bumped to v1.5.2 |

**`lib/shop-type-wizard.js` is NOT in this ZIP** — it's already on your live server from Batch 1A. Verified live.

---

## Deploy Steps

### Step 1 — Replace 2 files in your repo

⚠️ **Same lesson as 1B-A and 1B-B**: copy individual files to repo root, NOT the `batch1b_d/` folder.

In your local repo:
1. Copy `index.html` from the ZIP → overwrite `index.html` at repo root
2. Copy `service-worker.js` from the ZIP → overwrite `service-worker.js` at repo root

### Step 2 — Commit and push

```bash
git add index.html service-worker.js
git commit -m "Batch 1B-D: wire signup wizard + apply_beta_plan into signup flow"
git push
```

Wait ~60 sec for Vercel deploy.

---

## Verification

### Test 1 — Sign up with a brand new account

1. Open **incognito window** → `https://app.shopbillpro.in`
2. Click "Create Account" tab
3. Fill in:
   - Full Name: any test name
   - Shop Name: any test shop name
   - Email: a fresh email you have access to (e.g., `youremail+1bd@gmail.com` — Gmail's `+` aliases let you reuse one inbox)
   - Phone: any 10-digit number
   - Password: anything 6+ chars
4. Click "Create Account →"

**Expected:** Wizard modal appears with 12 macro category cards (Retail, Food Service, Beauty & Wellness, etc.).

5. Click "Beauty & Wellness" (or any macro)
6. Step 2 shows ~9 specific business types (salon, spa, gym, yoga, etc.)
7. Click "Salon" (or any type)

**Expected:** Wizard closes. After ~1 second, redirect to dashboard.

8. **On dashboard:** green beta countdown banner appears immediately above the topbar:
   > 🎉 Free Beta — all features till [date 60 days from now]. No card needed.

### Test 2 — Verify in Supabase

In SQL Editor:

```sql
SELECT id, name, shop_type, is_beta_signup, plan, plan_expires_at, beta_grace_until, created_at
FROM shops
ORDER BY created_at DESC
LIMIT 1;
```

**Expected** (for the freshly-created shop):
- `shop_type` = the category code you picked (e.g., `salon`)
- `is_beta_signup` = `true`
- `plan` = `business`
- `plan_expires_at` ≈ now + 60 days
- `beta_grace_until` ≈ now + 67 days

### Test 3 — Skip path

Sign up another fresh account (use `youremail+1bd2@gmail.com`).

When the wizard appears, click **"Skip for now"** (top right).

**Expected:**
- Wizard closes immediately
- Shop created with `shop_type = 'general_retail'`
- Banner still appears (beta plan still applied)

Verify in SQL:
```sql
SELECT name, shop_type, is_beta_signup FROM shops WHERE name = 'YOUR_TEST_SHOP_NAME';
```

Expected: `shop_type = 'general_retail'`, `is_beta_signup = true`.

### Test 4 — Wizard offline fallback (optional but recommended)

Hard test: prove the wizard doesn't break if Supabase is unreachable.

1. Open DevTools → Network tab
2. In the filter bar, type `supabase.co` → click the **🚫 Block** option (right-click any matching row → "Block request domain")
3. Now go through signup flow with another fresh email
4. Wizard should STILL render its 12 macros (from `FALLBACK_MACROS` in the lib)

This test confirms the wizard is robust to RPC failures.

(Don't forget to unblock the domain after testing.)

### Test 5 — Existing users unaffected

1. Log out
2. Log back in as one of your 4 existing test shops (Glitz & Glam, etc.)

**Expected:**
- Login works normally
- Dashboard loads
- No wizard appears (it's only triggered on signup, not login)
- No banner (these shops have `is_beta_signup = false`)
- Behavior identical to before this batch

---

## Diagnostic Console Commands

If anything looks off, run these in DevTools console:

### On the signup page (before clicking signup):
```js
console.log({
  wizard_loaded: typeof SBPWizard !== 'undefined',
  wizard_open_method: typeof SBPWizard?.open,
  globals_set: !!window.SBP_SUPABASE_URL && !!window.SBP_SUPABASE_KEY,
  sb_client: typeof _sb !== 'undefined'
});
```

**Expected all true** (except the last which checks for the const).

### After signup, on dashboard:
```js
console.log({
  shop: JSON.parse(localStorage.getItem('sbp_shop') || 'null'),
  banner_visible: !!document.querySelector('#sbp-beta-banner'),
});
```

**Expected:** shop object has `is_beta_signup: true`, `shop_type: <whatever you picked>`, `plan: 'business'`. Banner visible = true.

---

## What To Watch For

| Symptom | Likely cause | Fix |
|---|---|---|
| Wizard doesn't appear | Wizard JS didn't load | Check console for `lib/shop-type-wizard.js` 404. If 404, run `curl https://app.shopbillpro.in/lib/shop-type-wizard.js` to verify. |
| Wizard shows but cards empty | RPC failed AND fallback didn't kick in | Check console for errors |
| Wizard appears but Skip doesn't close it | Click handler issue | Check console for errors |
| Shop created but `shop_type` is null | INSERT didn't include the field | Re-check edit landed in `index.html` line ~745 |
| Shop created but `is_beta_signup` is false | `apply_beta_plan` failed silently | Check console for `[1B-D] apply_beta_plan ...` warnings |
| Banner doesn't appear after signup | Either beta not applied OR localStorage stale | Run diagnostic query in DB to check actual shop state |

---

## Rollback

```bash
git revert HEAD
git push
```

Vercel auto-deploys the revert. The 4 newly-created test shops will remain in your DB (they're real records). To clean those up:

```sql
-- Find the test shops you created during verification
SELECT id, name, owner_id, created_at FROM shops 
WHERE created_at > now() - interval '30 minutes'
ORDER BY created_at DESC;

-- Delete one specific shop (replace ID)
-- DELETE FROM shops WHERE id = 'YOUR_TEST_SHOP_ID';
```

---

## Pre-Existing Bug Worth Flagging (NOT in 1B-D scope)

While auditing index.html, I noticed: `localStorage.sbp_pending_shop` is written when email-confirmation is required (no session yet), but it's **never read by any other code**. So users who go through the email-confirm path lose their shop creation.

This was broken before Batch 1B-D and remains broken. Worth a future micro-batch (maybe 1B-G) to add a "resume pending shop" check on dashboard load. For now, all 4 of your existing test shops are presumably auto-confirm path so this isn't biting you yet.

If your Supabase Auth has email confirmation enabled in the project settings, **be aware** that new signups via that path will fail to create shops. Easy workaround for now: keep email confirmation OFF in Supabase Auth settings until that bug is fixed.

---

## After 1B-D Lands

The full beta acquisition path is now wired:

1. ✅ User signs up → wizard captures shop type
2. ✅ Shop created with `shop_type` field
3. ✅ `apply_beta_plan` runs → 60-day Business beta activated
4. ✅ Banner shows on dashboard (from 1B-A) with countdown
5. ✅ Plan auto-expires after 60 days, with 7-day grace
6. ✅ Subscription page shows correct ₹499 pricing (from 1B-B)

**Remaining 1B sub-batches** (lower priority now that beta acquisition works end-to-end):

- **1B-E**: Subscription page beta-mode display (hide Upgrade CTAs while in active beta) — medium risk, ~75 min
- **1B-C**: Sidebar engine standardization (16 pages, lib needs CSS fix first) — high risk, requires dedicated session + 24h pilot soak
- **1B-F**: Mobile hamburger drawer — depends on 1B-C

Or you can stop here. The acquisition pipeline is complete enough to launch when CIN comes through. The remaining sub-batches are polish.

---

## Summary

This batch is the missing piece that makes the beta program actually work. Before 1B-D, the banner from 1B-A would only show if you manually flagged shops as beta in SQL. After 1B-D, every new signup automatically becomes a beta user with proper expiry logic.

When CIN comes through and you flip the switch to public beta, this is the path users take.
