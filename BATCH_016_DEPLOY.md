# ShopBill Pro — Batch 016: Change Business Type

**Date:** 6 May 2026
**Scope:** Let shopkeepers change their business category after signup
**Risk:** Low — additive (1 column, 2 RPCs, 2 file edits)
**Estimated deploy time:** ~3 min

---

## What this delivers

Until now, the business type chosen at signup (via `SBPWizard`) was locked forever. If a shopkeeper tapped the wrong category by mistake, or pivoted their business (kirana → adds restaurant, jewellery → boutique hotel), there was no way to fix it.

This batch lets them change it from Settings, with a 24-hour rate limit and no plan gating.

---

## Files (3 changes)

| Path | Action | What it does |
|------|--------|--------------|
| `db/migrations/016_change_shop_type.sql` | NEW | 1 column + 2 RPCs |
| `lib/shop-type-wizard.js` | MODIFIED | New `mode: 'change'` option (different copy, hides Skip button) |
| `settings.html` | MODIFIED | New "🔄 Business Type" menu item under Shop Management section + change handler |

---

## Decisions locked

- **Entry point:** Settings → Shop Management section, right under "Shop Details" ✅
- **Rate limit:** Once per 24 hours (server-enforced + client pre-check) ✅
- **Plan gate:** None — Free tier can also change ✅
- **Existing data:** Preserved (bills, customers, products, hospitality data, loyalty, services, appointments — everything stays). Only the sidebar module set changes.

---

## How it works

```
User flow:
  1. Settings → tap "🔄 Business Type [emoji + current name]"
  2. If already changed today: alert "Already changed. Wait Xh."
  3. Else: SBPWizard opens in CHANGE mode (different copy, no Skip)
  4. User picks new macro → new sub-type
  5. Confirmation: "Change to <code>?"
  6. RPC sbp_change_shop_type fires
  7. Server checks: owner, valid type, 24h rate limit, no-op
  8. On success: localStorage updated + page reloads
  9. Sidebar engine fetches new module set → modules update visibly
```

```
Server logic (sbp_change_shop_type):
  ├── auth check (must be logged in)
  ├── ownership check (must be the shop owner)
  ├── no-op check (can't change to same type)
  ├── rate-limit check (last_changed > 24h ago)
  ├── catalog check (new type exists in sbp_business_categories)
  ├── UPDATE shops SET shop_type = ..., shop_type_changed_at = now()
  └── return rich response: old + new category info, next-allowed timestamp
```

---

## Deploy steps

### Step 1 — SQL in Supabase SQL Editor

```sql
\i db/migrations/016_change_shop_type.sql
```

Or paste manually. Idempotent. Runs in <2 sec.

### Step 2 — Verify

```sql
-- (1) Column added
SELECT column_name FROM information_schema.columns
WHERE table_name = 'shops' AND column_name = 'shop_type_changed_at';
-- Expected: 1 row

-- (2) RPCs registered
SELECT proname FROM pg_proc
WHERE proname IN ('sbp_change_shop_type', 'sbp_get_my_shop_type');
-- Expected: 2 rows

-- (3) Smoke test (read current — won't change anything)
SELECT sbp_get_my_shop_type('<your-shop-uuid>');
-- Expected: {ok:true, shop_type:'kirana', emoji:'🛒', can_change_now:true, ...}
```

### Step 3 — Push 2 files to GitHub PWA repo

```
db/migrations/016_change_shop_type.sql   (new)
lib/shop-type-wizard.js                   (modified — change-mode flag)
settings.html                             (modified — menu item + handler)
```

Vercel auto-deploys ~30 sec.

---

## Smoke test checklist

### Happy path
- [ ] Hard-refresh, open Settings
- [ ] "🔄 Business Type" menu item appears under "🏪 Shop Details"
- [ ] After ~1 second, the pill next to "Business Type" populates with current type emoji + name (e.g., "🛒 Kirana / General Store")
- [ ] Subtitle reads: "Tap to change your shop category. Once per day."
- [ ] Tap the menu item — wizard opens with title "Change Business Type" and subtitle about preserving data
- [ ] Skip button is hidden in change mode
- [ ] Pick a different macro (e.g., Hospitality)
- [ ] Step 2 shows: "Pick your new sub-type"
- [ ] Tap Hotel/Lodge — confirmation prompt appears
- [ ] Confirm — toast: "✅ Business type changed to 🏨 Hotel / Lodge. Refreshing…"
- [ ] Page reloads after ~1.6s
- [ ] Sidebar now shows hospitality modules: Rooms, Bookings, Folio (with NEW badges if Batch 015 deployed)
- [ ] Old modules (e.g., POS for kirana) hidden where appropriate

### Rate limit
- [ ] Immediately try to change again
- [ ] Alert: "You already changed your business type today. You can change it again in ~24 hours."
- [ ] Wizard does NOT open
- [ ] Settings menu subtitle now reads: "Already changed today. Available again in 24h."

### Sad paths
- [ ] Try to change to same type — toast: "That is already your current business type."
- [ ] Cancel the confirmation dialog — wizard closes, no change applied

### Data preservation
- [ ] Before changing, note your bills count, customers count, products count
- [ ] After changing to a different macro
- [ ] Counts should be **unchanged** — bills/customers/products all preserved

### Plan gating verified absent
- [ ] On a Free-tier test shop, the menu item appears + works (no upgrade banner)
- [ ] Server allows the change with `plan='free'`

### Mobile sanity
- [ ] On a phone, the menu item renders cleanly (pill + subtitle don't overflow)
- [ ] Wizard opens full-screen (it always was)
- [ ] After reload, mobile bnav reflects new modules

---

## Rollback plan

| Layer | Rollback |
|-------|----------|
| RPCs | `DROP FUNCTION sbp_change_shop_type(uuid,text); DROP FUNCTION sbp_get_my_shop_type(uuid);` |
| Column | `ALTER TABLE shops DROP COLUMN shop_type_changed_at;` (only if no other code reads it) |
| HTML/JS | `git revert <commit>` and push |

The column is non-destructive — leaving it in place is also safe. Just dropping the menu item is enough to disable the feature without removing data.

---

## What changes from the user's perspective

```
BEFORE: Business type picked at signup is permanent.
        Mistake → contact support (= no support, just stuck).

AFTER:  Settings → Business Type → re-pick → done.
        Limited to once per day to prevent confusion.
        Data is preserved across changes.
```

This closes a real beta-blocker: the "I tapped the wrong category" problem. New shopkeepers will breeze through signup without fear of locking themselves in.

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Batch 016 (6 May 2026)*
