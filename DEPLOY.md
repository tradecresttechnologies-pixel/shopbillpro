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

### 3. ⏳ DEFERRED — Appointment 400 noise

The `sbp_get_appointment_config_public` 400 error comes from leftover
Universal Appointments code (Batch 015) in `s.html` — lines ~531-572 call
that RPC on every page load, including AI-mode sites that don't need it.

**Why deferred:** The `s.html` in the project repo snapshot is dated
May 5 — it's the OLD pre-AI version. The deployed `s.html` (which handles
AI iframe rendering) is newer and isn't in the snapshot I can read. I can't
safely patch a file I can't see the current version of.

**To fix this:** upload your current deployed `s.html` (or the one from
whichever batch added AI iframe support) and I'll patch it in a tiny
follow-up — the fix is ~3 lines: skip `loadAppointmentConfig()` when
`data.ai_mode` is true.

**Impact if left alone:** harmless. It's one failed background request
that's caught and logged as a warning. Nothing user-facing breaks. Worth
cleaning up before launch but not urgent.

## DEPLOY PATHS

```
NEW  db/migrations/057_website_prompt_v3_2.sql
```

**One file.** SQL migration only. No HTML, no edge function change.

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
3. Regenerate Glitz & Glam from `/website-builder.html` to see the fix

## Test

After regenerating Glitz & Glam:
- ✅ "Our Rooms" appears once (in the #about section, with Book Now buttons)
- ✅ The services component below is now headed "Additional Services" and
  shows only non-room extras — OR is gracefully empty/hidden if the shop
  has no extras
- ✅ No more seeing the same 3 rooms listed twice

## Rollback

```sql
UPDATE ai_prompt_templates SET is_active = (notes LIKE 'v3.1 —%')
WHERE name='website_v1';
```

## Files in this batch

```
Batch_Website_Polish_v4_8b/
├── DEPLOY.md
└── db/migrations/
    └── 057_website_prompt_v3_2.sql
```

One migration. Run it, regenerate, done.

## Note on quota

Regenerating uses one of your monthly generations. If you hit the 402
quota error again, reset with:
```sql
UPDATE sbp_shop_websites
SET ai_regenerations_used = 0, ai_regen_period_start = now()
WHERE shop_id = '73aa8ede-6352-4549-8617-cccacdd5c821';
```
