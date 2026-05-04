# Batch 1B-C-Pilot — Wire Dashboard.html To Lib (Single-Page Pilot)

**Status:** First production wiring of the sidebar engine. Only `dashboard.html` modified.
**Risk:** Medium — single page test before scaling. Other 15 pages unchanged.
**Time:** ~5 minutes deploy + 10 minutes verify.

---

## What This Batch Does

Replaces `dashboard.html`'s inline 35-line sidebar IIFE with a single call to `SBPSidebar.render()`. The lib (`lib/sidebar-engine.js`) takes over rendering responsibilities for the desktop sidebar on this page only.

Other 15 user-facing pages still use their own inline sidebars — completely unchanged. If something breaks on dashboard, the rest of the site keeps working.

---

## Files In This Batch

| File | Action |
|---|---|
| `lib/sidebar-engine.js` | REPLACE — patched lib (was never deployed before; +93 lines for desktop branch + bug fixes) |
| `dashboard.html` | REPLACE — inline IIFE removed, single render call added |
| `service-worker.js` | REPLACE — bumped to v1.5.6 |

3 files. The lib patch comes ALONG with the dashboard wiring — they go live together.

---

## What Will Visually Change On Dashboard

The sidebar will look very similar but with these specific differences from current behavior:

### Label changes (cosmetic):
- "Dashboard" → **"Home"**
- "Inventory" → **"Stock"**
- "Team & Users" → **"Team"**
- "Plans & Pricing" → **"Plans"**
- "Bill Templates" → **"Templates"**

These match what the lib uses across all pages going forward (consistency for next 15 pages too). Hindi labels follow same pattern (होम, स्टॉक, टीम, etc.).

### Items still present:
All 16 items: Home, Bills, +New Bill (FAB), Customers, Stock, Reports, POS Admin, Marketing, WhatsApp, Recurring, Cash Register, Suppliers, Team, Plans, Templates, Settings + Logout button.

(I added POS Admin and Templates to the lib's UNIVERSAL_CORE because they were missing — every shop needs them.)

### Order:
Same as before. Home → Bills → +New Bill → Customers → Stock → Reports → POS Admin → ... → Templates → Settings → Logout.

### Smart-sidebar effect for your beta test shop:
Your beta shop has `shop_type='d2c_brand'`. The lib will RPC `get_shop_modules(shop_id)` to fetch which vertical modules apply. If `sbp_module_profiles` has data for `d2c_brand`, those modules show. Otherwise the lib's `DEFAULT_FALLBACK` provides 8 sensible items (website, marketing, wa_center, recurring, cash_register, supplier, team, subscription).

**Net result for your test shop:** sidebar should look approximately like before with the label changes above.

---

## Bugs I Fixed In The Lib During Pilot Build

While building the pilot, I caught and fixed two issues in the lib:

1. **`order: 0` falsy bug** — `items.sort((a,b) => (a.order || 999) - ...)`. Since `order: 0` is falsy, Home item was getting sorted to the bottom. Fixed with explicit undefined/null check.
2. **Missing items** — POS Admin and Bill Templates weren't in `UNIVERSAL_CORE` or `MODULE_CATALOG`. Added them so they appear for every shop.

These would have shown up during pilot verification. Caught early.

---

## Deploy Steps

### Step 1 — Replace 3 files in your repo

In your local repo:
1. Copy `lib/sidebar-engine.js` from ZIP → repo's `lib/sidebar-engine.js` (overwrite)
2. Copy `dashboard.html` from ZIP → repo root (overwrite)
3. Copy `service-worker.js` from ZIP → repo root (overwrite)

### Step 2 — Commit and push

```bash
git add lib/sidebar-engine.js dashboard.html service-worker.js
git commit -m "Batch 1B-C-Pilot: wire dashboard.html to sidebar-engine lib"
git push
```

Wait ~60 sec for Vercel deploy.

---

## Verification

### Step 1 — Hard refresh dashboard

Open `app.shopbillpro.in/dashboard.html`. Hard-refresh (Ctrl+Shift+R) to bypass service worker cache.

Better yet: DevTools → Application → Service Workers → Unregister → reload. This guarantees the new SW (v1.5.6) takes over.

### Step 2 — Check the sidebar visually

**Expected (looks similar to before with label changes):**
- ✅ Logo at top: orange shield + "ShopBill Pro" text
- ✅ All 16 items present (Home, Bills, +New Bill FAB, Customers, Stock, Reports, POS Admin, Marketing, WhatsApp, Recurring, Cash Register, Suppliers, Team, Plans, Templates, Settings)
- ✅ Home highlighted as active (orange tint)
- ✅ +New Bill is the orange FAB-style button
- ✅ Logout button at bottom + "ShopBill Pro v1.0" text

### Step 3 — Click each sidebar item

Click each one and verify it navigates to the correct page:
- Home → `dashboard.html` (you're already there, just refreshes active state)
- Bills → `bills.html`
- +New Bill → `billing.html`
- Customers → `customers.html`
- Stock → `stock.html`
- Reports → `reports.html`
- POS Admin → `pos-admin.html`
- Marketing → `marketing.html`
- WhatsApp → `wa-center.html`
- Recurring → `recurring.html`
- Cash Register → `cash-register.html`
- Suppliers → `supplier.html`
- Team → `team.html`
- Plans → `subscription.html`
- Templates → `bill-templates.html`
- Settings → `settings.html`
- Logout → signs out, returns to `index.html`

### Step 4 — Verify other 15 pages still work normally

Click through other pages (any of the ones you didn't go to via the new lib) — they should look exactly as before since they still use their own inline sidebars.

### Step 5 — Check beta banner still works

Banner should still appear at top of dashboard (the green "Free Beta" countdown). 1B-A wiring is independent of sidebar wiring.

### Step 6 — DevTools console check

Press F12 → Console. Should be **NO errors** from the lib. If you see:
- `[1B-C-Pilot] SBPSidebar lib not loaded` → lib didn't load. Check `lib/sidebar-engine.js` deployed.
- `[SBPSidebar] RPC error` → harmless, lib falls back to cache/default.
- `Cannot read properties of null` → real bug, paste full error to me.

---

## Smart-Sidebar Inspection (Optional)

Your beta test shop has `shop_type='d2c_brand'`. To see the smart-sidebar effect, run in DevTools console on dashboard:

```js
// What modules will show for this shop_type?
const sb = supabase.createClient('https://jfqeirfrkjdkqqixivru.supabase.co', 'YOUR_ANON_KEY_HERE');
const shopId = JSON.parse(localStorage.getItem('sbp_shop')).id;
const { data, error } = await sb.rpc('get_shop_modules', { p_shop_id: shopId });
console.log('Modules for this shop:', data);
console.log('Error (if any):', error);
```

If the RPC returns module data, those drive the sidebar. If RPC fails (no module_profile for d2c_brand), lib uses DEFAULT_FALLBACK.

If you want to customize what shows up for d2c_brand specifically, edit module profiles via your `admin-categories.html` admin page. That's the smart-sidebar configurability — admin can tune which modules appear per business type without code changes.

---

## What To Watch For

| Symptom | Likely cause | Fix |
|---|---|---|
| Sidebar looks completely different (mobile-style on desktop) | Lib's old version still cached | Hard refresh; unregister SW; reload |
| Sidebar missing entirely on dashboard | Lib didn't load | Check Network tab — is `lib/sidebar-engine.js` 200 OK? Should be 22 KB |
| Sidebar present but no logout / logo / items | `_sb` not initialized when render fires | Should not happen since render runs in main script block AFTER `_sb` is created. If it does, paste console errors |
| Click an item → 404 | Item href wrong in lib | Tell me which item, I'll check MODULE_CATALOG |
| Other pages broken | Should NOT happen since this batch only changes dashboard.html | Hard refresh that page; check it's not Vercel deploy lag |

---

## Rollback

```bash
git revert HEAD
git push
```

Reverts all 3 files. Dashboard goes back to inline sidebar. Lib goes back to 1B-A version (mobile-only). Service worker bumps further so cache invalidates.

---

## After Pilot Soak

Once you verify pilot works for 24+ hours (and no real users reported issues), the next batch is **1B-C-Scale**: wire the remaining 15 pages to use the lib in the same way.

For each page, the change is identical:
1. Remove the inline ~35-line sidebar IIFE
2. Add `<script src="lib/sidebar-engine.js">` near other script tags
3. Add `SBPSidebar.render({ layout: 'desktop', currentPage: '<page-code>' })` where the IIFE used to be

I'll do them in batches of 4-5 pages with verification between batches.

But there's no rush. **Pilot success first, then scale.**

---

## Reply Path

- **"Pilot deployed clean — sidebar works on dashboard"** → 1B-C-Pilot succeeded; we'll plan 1B-C-Scale for next session
- **"Sidebar looks weird: ___"** → describe what's off, paste screenshot, I debug
- **"Got error: ___"** → paste, debug
