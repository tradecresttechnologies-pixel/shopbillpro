# Batch v4.8b — Website Polish: Fix Duplicate Services

**Delivered:** May 14, 2026

## What this batch fixes

You flagged three things for v4.8b. Here's the honest status of each after
investigation:

### 1. ✅ FIXED — Duplicate services (rooms shown twice)

**The bug:** For hospitality shops, the AI generated room cards TWICE:
- Hand-authored "Our Rooms" cards in the #about section (with Book Now)
- A separate `data-sbp="services"` component ("Our Services") that
  hydrated the SAME rooms from `sbp_services`

The customer saw rooms listed twice — redundant and confusing.

**The fix:** Prompt v3.2 adds a hard "NO DUPLICATE OFFERINGS" rule:
- **Hospitality** → #about section shows rooms (with Book Now CTAs). The
  `data-sbp="services"` component is then for NON-ROOM extras only (spa,
  restaurant, laundry, airport pickup). Its heading becomes "Additional
  Services" not "Our Services". Rooms are never listed twice.
- **Other verticals** → #about is a short teaser, services component is
  the full list. They naturally differ — no duplication.

### 2. ⚠️ NOT A BUG — Color picker

I investigated the "Orange → wrong color" issue thoroughly. The color
picker code in `website-builder.html` is actually **correct**:
- `selectColor('Orange')` → finds `{name:'Orange', hex:'#FF6B35'}` →
  correctly sets `color_primary_hex = '#FF6B35'`
- `init()` calls `selectColor('Orange')` first, THEN `loadWebsiteState()`
  overrides it only if a saved draft exists

What you saw was **expected behavior**: you had previously saved a draft
with a different color (Sage/Teal during earlier testing). When you
reopened the builder, `loadWebsiteState()` correctly restored that saved
draft's color. That's the feature working — not a bug.

**If you want Orange:** just click Orange in the picker before generating.
It saves with the draft. Nothing to fix here.

(If you genuinely see Orange selected in the UI but a different color in
the generated site, THAT would be a real bug — but I couldn't reproduce it
from the code. If it happens, screenshot the picker + the result and I'll
dig in.)

### 3. ✅ FIXED — Appointment 400 noise

The `sbp_get_appointment_config_public` 400 error came from `s.html`
unconditionally calling two parent-page helper functions
(`loadServicesPublic` + `loadAppointmentConfig`) AFTER `renderShop()` —
even for AI-mode sites.

For an AI site, `renderShop()` replaces the whole page with a sandboxed
iframe and returns early. But those two helpers still fired:
- They look for DOM elements (`psp-book-cta-slot`) that only exist in the
  non-AI renderer's markup — so they did nothing useful
- `loadAppointmentConfig` hit `sbp_get_appointment_config_public`, which
  400s for shops without the legacy appointments module — that was the
  console error you saw

**The fix:** `s.html` now detects AI-mode sites and skips both parent-page
helpers. The iframe's own `lib/live-site.js` already handles everything
(services, gallery, contact, booking) inside. No more 400, no wasted
requests.

## DEPLOY PATHS

```
NEW      db/migrations/057_website_prompt_v3_2.sql
REPLACE  s.html
```

**Two files.** One SQL migration + one HTML file. No edge function change.

## Deploy steps

1. Supabase SQL Editor → paste `057_website_prompt_v3_2.sql` → Run
2. Verify:
   ```sql
   SELECT name, version, is_active, left(notes, 60) AS notes
   FROM ai_prompt_templates WHERE name='website_v1' ORDER BY version;
   -- v3.2 should be the only active row

   SELECT prompt_text LIKE '%NO DUPLICATE OFFERINGS%' AS has_rule
   FROM ai_prompt_templates WHERE name='website_v1' AND is_active=true;
   -- should be true
   ```
3. Copy `s.html` → repo root (overwrite) → commit → push
4. Regenerate Glitz & Glam from `/website-builder.html` to see the
   duplicate-services fix

## Test

After regenerating Glitz & Glam:
- ✅ "Our Rooms" appears once (in the #about section, with Book Now buttons)
- ✅ The services component below is now headed "Additional Services" and
  shows only non-room extras — OR is gracefully empty/hidden if the shop
  has no extras
- ✅ No more seeing the same 3 rooms listed twice
- ✅ Open DevTools Console on `/s/glitz-glam` → no more
  `sbp_get_appointment_config_public` 400 error

## Rollback

```sql
UPDATE ai_prompt_templates SET is_active = (notes LIKE 'v3.1 —%')
WHERE name='website_v1';
```

For `s.html`: git revert the commit. The change is a clean conditional
wrapper — reverting just restores the unconditional helper calls.

## Files in this batch

```
Batch_Website_Polish_v4_8b/
├── DEPLOY.md
├── s.html                              (AI-site helper-skip fix)
└── db/migrations/
    └── 057_website_prompt_v3_2.sql      (prompt v3.2 — no duplicates)
```

Run the migration, deploy s.html, regenerate Glitz & Glam.

## Note on quota

Regenerating uses one of your monthly generations. If you hit the 402
quota error again, reset with:
```sql
UPDATE sbp_shop_websites
SET ai_regenerations_used = 0, ai_regen_period_start = now()
WHERE shop_id = '73aa8ede-6352-4549-8617-cccacdd5c821';
```
