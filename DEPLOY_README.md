# ShopBill Pro — Universal Appointments Module

**Batch:** 011 — Universal Appointments
**Date:** May 2026
**Master Plan §6.1:** Layer 2 universal add-on
**Plan gating:** Business-tier only (₹499/mo)
**Closes verticals:** salon, spa, gym, yoga, clinic, dentist, vet, coaching, photographer, plumber, mover, tailor + ~30 verticals to ~95% complete

---

## What's in this batch

| File | Type | Purpose |
|------|------|---------|
| `db/migrations/011_appointments.sql` | NEW | 3 tables, 16 functions (13 RPCs + helpers), RLS, indexes, triggers |
| `lib/appointments.js` | NEW | Client wrapper (`window.SBPAppt` namespace) |
| `appointments.html` | NEW | Admin page — Bookings / Providers / Blocks tabs |
| `s.html` | PATCH | Public storefront — adds Book Appointment CTA + 5-step booking flow |
| `settings.html` | PATCH | Adds Appointments menu link (BIZ-tier badge) |

---

## Deploy steps

### 1. Run SQL migration in Supabase SQL Editor

⚠️ **Order matters.** This batch references `sbp_services` from the previous batch.

If not already done, run in this order:
```
audit_round_db_patch.sql      (already deployed earlier)
admin_panel_full.sql          (already deployed earlier)
003_categories.sql            (already deployed earlier)
004_seo.sql                   (already deployed earlier)
005_beta.sql                  (already deployed earlier)
008_psp_resolver.sql          (already deployed earlier)
009_loyalty.sql               (already deployed earlier)
010_service_catalog.sql       ← required prereq
011_appointments.sql          ← this batch
```

The migration is **idempotent** — safe to re-run if you doubt yourself.

### 2. Verification queries

Paste in Supabase SQL Editor:

```sql
-- Tables exist with RLS on
SELECT tablename, rowsecurity FROM pg_tables
WHERE tablename IN ('sbp_appointment_providers','sbp_provider_blocks','sbp_appointments');
-- Expected: 3 rows, all rowsecurity=t

-- All 16 functions exist
SELECT count(*) FROM pg_proc
WHERE proname IN (
  'sbp_appt_set_updated_at','sbp_check_business_owner',
  'sbp_appt_providers_list','sbp_appt_providers_upsert','sbp_appt_providers_delete',
  'sbp_appt_block_create','sbp_appt_block_delete','sbp_appt_blocks_list',
  'sbp_appointments_list','sbp_appointments_create','sbp_appointments_update','sbp_appointments_set_status',
  'sbp_get_appointment_config_public','sbp_get_available_slots_public',
  'sbp_book_appointment_public','sbp_get_appointment_status_public'
);
-- Expected: 16

-- Public RPCs callable by anon
SELECT proname, has_function_privilege('anon', oid, 'EXECUTE') AS anon_can_call
FROM pg_proc
WHERE proname LIKE 'sbp_get_appointment_config_public'
   OR proname LIKE 'sbp_get_available_slots_public'
   OR proname LIKE 'sbp_book_appointment_public'
   OR proname LIKE 'sbp_get_appointment_status_public';
-- Expected: 4 rows, all anon_can_call=t

-- Smoke test: get appointment config for a published shop slug
SELECT sbp_get_appointment_config_public('glitz-glam');
-- Expected: {"ok":true,"enabled":false}  (false because no providers configured yet)
```

### 3. Push files to GitHub PWA repo (root directory)

```
db/migrations/011_appointments.sql
lib/appointments.js
appointments.html
s.html              ← replaces existing
settings.html       ← replaces existing
```

Vercel auto-deploys ~30 sec after push.

---

## Plan gating (Business-only)

Per Master Plan §6.1, Universal Appointments is **Business-tier only** (₹499/mo).

**Server-side enforcement** (cannot be bypassed):
- `sbp_check_business_owner()` helper rejects non-Business plans on every admin RPC
- Public RPCs (`sbp_get_appointment_config_public`, `sbp_get_available_slots_public`, `sbp_book_appointment_public`) check the shop's plan and return `enabled: false` / `feature_disabled` for Free/Pro shops

**Client-side UX** (cosmetic, server is authoritative):
- `appointments.html` shows locked banner + upgrade CTA for Free/Pro users
- `lib/appointments.js` `_isBiz()` short-circuits before any RPC call
- `s.html` Book Appointment button only renders if config returns `enabled: true`

---

## API-first compliance checklist (per locked rule May 2026)

This batch follows the API-first architecture rule:

✅ All business logic in PLpgSQL RPCs (16 functions, no JS-side orchestration)
✅ Server-side validation on every input (name length, time validity, ownership, plan)
✅ `jsonb {ok, error?, ...data}` envelope on every RPC return value
✅ Stable error codes: `not_found`, `not_owner`, `business_plan_required`, `slot_taken`, `past_starts_at`, `provider_required`, `name_required`, `feature_disabled`, etc.
✅ `auth.uid()` + ownership check on all admin RPCs (via `sbp_check_business_owner` helper — replaceable by future `sbp_caller_shop_id` helper)
✅ Idempotency on writes (slot_taken conflict check uses `tsrange &&` overlap with buffer; bookings cannot double-book)
✅ Zero localStorage/DOM dependencies in business logic
✅ Public RPCs (`sbp_*_public`) are first-class — anon-callable, slug-resolved, no auth required (powers /s/[slug] booking flow + future external website builders + AI agents)

---

## Public booking flow testing

After deploy, test the end-to-end public booking:

1. Sign in as a **Business-tier** shop owner
2. Settings → Appointments
3. Add a Provider (your name, default working hours)
4. Settings → Service Catalog → add at least 1 service with duration_minutes (e.g. "Haircut, ₹300, 30 min")
5. Make sure the shop website is published (Settings → Website Editor → toggle Public ON)
6. Open `/s/[your-slug]` in an incognito window
7. You should see a purple **📅 Book Appointment** button below the contact actions
8. Tap it → walk through Service → Provider → Date → Time → Customer info → Confirm
9. The appointment should appear in your admin Appointments page with status "pending" and source "🌐 Online"

**Expected behavior:**
- If shop has 0 providers → button doesn't appear
- If shop is not Business plan → button doesn't appear (server returns `enabled: false`)
- If shop has 1 provider → provider step is auto-skipped
- If shop has 0 services → service step is auto-skipped (generic appointments only)
- Past slots are filtered out (15-min future cutoff in IST)
- Slot conflict during submit → user is bumped back to time-pick step with refreshed availability

---

## What's NOT in this batch (v2 follow-ups)

- Full calendar grid view (week/day visual) — using list view tonight
- WhatsApp confirmation auto-send to customer (template needed: "Booking received for [time]")
- Reminder cron (24-hour-before reminder)
- Walk-in queue / in-person queue management
- Bill-link integration (link appointment → completed bill on save)
- Recurring appointments (weekly haircut, monthly checkup)
- Customer self-cancel via secret link
- Provider login + per-provider limited admin view
- Multi-shop branch support

---

## Key SQL design notes

**Slot calculation logic** (`sbp_get_available_slots_public`):
- All time arithmetic done in `Asia/Kolkata` timezone, then converted to UTC for storage
- Iterates from `work_start_time` to `work_end_time` in `slot_interval_minutes` steps
- Skips slots in the past (with 15-min cushion so user has time to confirm)
- Skips slots intersecting partial blocks (`tsrange && tsrange`)
- Skips slots intersecting existing pending/confirmed appointments (with `buffer_minutes` padding on each side)
- Returns `total_slots` and `taken_slots` so UI can show "3 of 16 left"

**Conflict prevention on book** (`sbp_book_appointment_public`):
- Re-checks slot availability at insert time (not just at slot-fetch time)
- Returns `slot_taken` error if another booking landed in that window after fetch
- UI catches this error and bumps user back to time-pick step

**Buffer minutes**:
- Configurable per-provider (default 0)
- Applied on both sides of existing appointments when checking conflicts
- Useful for: clean-up time after services, transition between back-to-back clients

---

## Troubleshooting

**Q: Book Appointment button doesn't show on `/s/[slug]`**
→ Check: shop is Business-tier? Has at least 1 active provider? Website is published? Open browser console — `sbp_get_appointment_config_public` should return `{ok:true, enabled:true}`.

**Q: "feature_disabled" error**
→ Shop is not on Business plan, or plan has expired. Check `shops.plan` and `shops.plan_expires_at`.

**Q: Slot calculation looks wrong**
→ Check the provider's `working_days` (array of 0-6, Sun=0), `work_start_time`/`work_end_time`, `slot_interval_minutes`. Times are in IST.

**Q: Customer can't see availability**
→ The provider must be `active = true`. Whole-day blocks (`start_time IS NULL`) close the date entirely.

**Q: Public RPC returns "shop_not_found" despite slug existing**
→ Slug exists but `published = false` in `sbp_shop_websites`. Owner must publish the website.

---

## Memory-friendly summary (for future sessions)

```
Batch 011 = Universal Appointments
  - 3 tables: sbp_appointment_providers, sbp_provider_blocks, sbp_appointments
  - 13 RPCs: 4 admin (providers), 3 admin (blocks), 4 admin (appointments), 4 public (storefront)
  - Public RPCs anon-callable for AI/external website builder use
  - Slot calc: IST timezone, tsrange overlap with buffer
  - Plan gating: Business-only enforced server-side via sbp_check_business_owner helper
  - UI: appointments.html (3 tabs) + s.html booking modal (5 steps)
  - Closes ~30 verticals to 95%
  - v2 deferred: WA auto-send, reminder cron, calendar grid, walk-in queue, bill-link
```
