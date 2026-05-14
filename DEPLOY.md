# Batch v4.8a-HOTFIX — Address Fix + Contrast Fix + Booking Buttons

**Delivered:** May 14, 2026

Fixes the 3 issues found after v4.8a deployment:

1. **Address shows "Gorakhp"** instead of the real address → resolver was reading the wrong field
2. **Section text invisible** (dark-on-dark) → prompt contrast rule wasn't strong enough
3. **No "Book Now" buttons** on room cards → prompt didn't require booking CTAs

## DEPLOY PATHS

```
NEW      db/migrations/055_fix_address_resolution.sql
NEW      db/migrations/056_website_prompt_v3_1.sql
REPLACE  website-builder.html
```

**3 files.** Two SQL migrations + one HTML file. No edge function change (v3.2 stays).

---

## Deploy in 4 steps (~5 min)

### Step 1 — (Optional but recommended) Manual address patch for Glitz & Glam

If you haven't already run this, do it now in Supabase SQL Editor — instantly fixes your test shop:

```sql
UPDATE shops
SET address = 'Cinema Road, Near Golghar', city = 'Gorakhpur'
WHERE id = '73aa8ede-6352-4549-8617-cccacdd5c821';
```

(Migration 055's backfill will then sync this into content_json automatically.)

### Step 2 — Run migration 055 (address resolution fix)

Supabase SQL Editor → paste `055_fix_address_resolution.sql` → Run.

**Verify:**
```sql
-- Should now show the real address, not "Gorakhp"
SELECT sbp_resolve_shop_slug('glitz-glam') -> 'content' ->> 'address';
-- Expected: "Cinema Road, Near Golghar"
```

### Step 3 — Run migration 056 (prompt v3.1)

Supabase SQL Editor → paste `056_website_prompt_v3_1.sql` → Run.

**Verify:**
```sql
-- Should show v3.1 active
SELECT name, version, is_active, left(notes, 50) AS notes
FROM ai_prompt_templates WHERE name='website_v1' ORDER BY version;

-- Should both be true
SELECT prompt_text LIKE '%card-cta%'        AS has_card_cta,
       prompt_text LIKE '%CONTRAST — HARD%' AS has_contrast_rule
FROM ai_prompt_templates WHERE name='website_v1' AND is_active=true;
```

### Step 4 — Deploy website-builder.html

1. Extract zip → copy `website-builder.html` → repo root (overwrite)
2. GitHub Desktop → commit: `v4.8a-hotfix: address sync + contrast + booking CTA`
3. Push origin → wait ~30 sec for Vercel

---

## Step 5 — Regenerate Glitz & Glam to see the fixes

1. `/website-builder.html` → click **🚀 Generate Website with AI**
2. Open `/s/glitz-glam` in incognito

**Expected changes:**
- ✅ Hero photo still works (from v4.8a)
- ✅ Section headings now READABLE — proper contrast (no more dark-on-dark)
- ✅ Room cards now have **"Book Now"** buttons
- ✅ Clicking "Book Now" → opens the booking form modal (from Batch v4.7 — confirm that's deployed too)
- ✅ Contact info card shows the real address "Cinema Road, Near Golghar"

---

## What each fix does

### Fix 1 — Address resolution (migration 055)

**The bug:** Website builder's "Save All" wrote address to the `shops` table. But `sbp_resolve_shop_slug` read it from `content_json.address` — a different storage location the builder never populated. So the resolver fell back to `content_json.city` ("Gorakhp", stale data).

**The fix:**
- `sbp_resolve_shop_slug` now merges contact fields with `shops.*` taking priority over `content_json.*`, treating empty strings as "missing" so they never override real data
- One-time backfill copies `shops.address` → `content_json.address` for all existing shops
- `website-builder.html` now writes address/city/phone/email to BOTH the shops table AND content_json, so they never diverge again

### Fix 2 — Contrast rule (prompt v3.1)

**The bug:** v3 generated sections with dark backgrounds but kept heading text in navy/accent → navy-on-near-black, invisible.

**The fix:** New hard rule in the prompt — an explicit contrast pairing table:
- Dark background → ALL text white
- Light background → ALL text near-black
- Forbids dark-on-dark and light-on-light
- Instructs the AI to mentally check every section before finishing

### Fix 3 — Booking CTA buttons (prompt v3.1)

**The bug:** v3 generated room/service cards as plain text. The v4.7 booking runtime intercepts "Book Now" clicks — but there were no buttons.

**The fix:** New hard rule — every hand-authored card MUST end with:
```html
<a href="#contact" class="card-cta">Book Now</a>
```
Label adapts per vertical (Book Now / Book Appointment / Reserve a Table / Get a Quote / Enquire Now). The `href="#contact"` is what the live-site.js v4.7 interceptor catches to open the booking modal.

---

## ⚠️ Prerequisite check — is Batch v4.7 deployed?

The booking buttons only DO something if `lib/live-site.js` from Batch v4.7 is live. Verify:

1. Open `https://app.shopbillpro.in/lib/live-site.js` in your browser
2. Ctrl+F for `openBookingModal`

- **Found** → v4.7 booking JS is deployed, booking buttons will work after this hotfix
- **Not found** → deploy `lib/live-site.js` from `Batch_Website_Booking_v4_7.zip` first, then this hotfix

Also confirm migration `053_public_booking.sql` ran (the booking RPC). If unsure:
```sql
SELECT sbp_get_public_booking_form_config('glitz-glam');
-- If this errors "function does not exist" → run 053 first
```

---

## Rollback

```sql
-- Rollback prompt to v3
UPDATE ai_prompt_templates SET is_active = (notes LIKE 'v3 —%') WHERE name='website_v1';

-- Rollback resolver: re-run migration 050's version of sbp_resolve_shop_slug
-- (050_fix_resolve_shop_slug.sql) — but 055 is strictly better, no reason to.
```

`website-builder.html` → git revert the commit.

No data at risk — 055's backfill only ADDS data to content_json, never deletes.

---

## Files in this batch

```
Batch_Website_Hotfix_v4_8a/
├── DEPLOY.md
├── db/migrations/
│   ├── 055_fix_address_resolution.sql    (5.5 KB)
│   └── 056_website_prompt_v3_1.sql        (14 KB)
└── website-builder.html                   (~66 KB)
```

Run 055 → run 056 → deploy website-builder.html → regenerate Glitz & Glam.
