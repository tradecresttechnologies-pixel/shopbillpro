# ShopBill Pro v6 — Reservation Polish

## What this bundle ships

Two operational improvements for restaurant reservations:

1. **One-tap WhatsApp notify** — staff can send a pre-filled confirmation message to the guest with one tap after confirming a reservation. Tracks send count + timestamp.

2. **Automatic table blocking** — once a reservation is confirmed AND assigned to a specific table, that table is automatically blocked from `block_before` minutes before arrival until `block_after` minutes after arrival. Staff trying to walk-in a blocked table gets a warning modal with override option.

3. **Auto no-show release** — pg_cron sweeps every 5 min and auto-marks confirmed reservations as `no_show` if guest doesn't arrive within `no_show_min` minutes past expected time. Configurable per shop (0 = disabled).

4. **Owner-configurable windows** — all three timings (`block_before_min`, `block_after_min`, `no_show_min`) are settings per shop, not hard-coded.

---

## DEPLOY ORDER

```
1. Enable pg_cron extension in Supabase Dashboard → Database → Extensions
2. Run SQL migration: db/migrations/099_reservation_polish.sql
3. Replace files in repo:
   • lib/reservation-state.js  (NEW FILE)
   • tables.html               (REPLACE — adds block overlay + warning modal)
   • settings.html             (REPLACE — adds Reservations group)
   • reservations.html         (REPLACE — adds notify button + badges)
4. Push via GitHub Desktop → Vercel auto-deploys
```

**No Edge Function changes. No new admin panel work. No external dependencies.**

---

## DEPLOY PATHS

| Source in zip | Target in repo | Action |
|---|---|---|
| `db/migrations/099_reservation_polish.sql` | `db/migrations/099_reservation_polish.sql` | NEW |
| `lib/reservation-state.js` | `lib/reservation-state.js` | NEW |
| `tables.html` | `tables.html` | REPLACE |
| `settings.html` | `settings.html` | REPLACE |
| `reservations.html` | `reservations.html` | REPLACE |
| `docs/DEPLOY_v6_reservation_polish.md` | (reference only) | — |

---

## What changed in each file

### `db/migrations/099_reservation_polish.sql`
- Adds 3 columns to `shops`: `reservation_block_before_min` (15), `reservation_block_after_min` (120), `reservation_no_show_min` (30)
- Adds 3 columns to `sbp_table_reservations`: `notified_at`, `notification_count`, `auto_released_at`
- 6 new RPC functions (all SECURITY DEFINER, with owner/authorized-user check)
- pg_cron job scheduled every 5 min to call `sbp_reservation_auto_release_no_shows`
- Defensive schema checks at start — fails fast with clear error if `sbp_table_reservations` table or expected columns don't exist

### `lib/reservation-state.js` (NEW)
- Shared helper exposing `window.SBPReservationState`
- `loadBlockedTables(shopId)` — fetches + caches blocked tables (60s TTL)
- `getBlockForTable(tableId)` — synchronous lookup after load
- `formatBlockBadge(block)` and `formatBlockTooltip(block)` — UI formatters
- Auto-refreshes on `visibilitychange` (when user returns to tab)
- Fails soft — if RPC errors, returns empty cache rather than blocking UI

### `tables.html`
- Includes new `lib/reservation-state.js` script tag
- New CSS: `.tcard-reservation-badge`, `.tcard.reserved-window`, `.reserve-warn-modal`
- `reloadAll()` now also fetches blocked-table state in parallel
- `render()` overlays a "Reserved 7:45 PM — Vinay (4)" badge on blocked table cards + adds orange border
- `handleTableTap()` wrapped — for free tables that are in a reservation block window, shows a warning modal with "Cancel" and "Use Anyway" buttons. Existing behavior for non-blocked tables unchanged.

### `settings.html`
- New section group "Reservations" with 3 number inputs (block before, block after, no-show grace)
- Auto-loads current values via `sbp_get_reservation_settings` on page boot
- Save button calls `sbp_update_reservation_settings` with validation
- Bilingual labels (EN/HI)
- Inserted between "Daily Operations" and "Customer-Facing" groups

### `reservations.html`
- New `📱 Notify` button on confirmed reservations (only shown if `customer_phone` exists)
- Button turns into `🔁 Resend` (green) after first send
- New `✓ NOTIFIED` badge next to status chip after notification
- New `notifyGuest()` function: builds pre-filled WhatsApp message, opens `https://wa.me/<phone>?text=...` in new tab, then calls `sbp_reservation_notify_sent` RPC to record
- Pre-filled message uses shop name + address + phone from `localStorage.sbp_shop`
- Format respects reservation date as "Tuesday, 27 May 2026" and time as "20:00"
- Includes table number and confirmation code if available

---

## TEST PLAN (in order)

### Test 1 — Migration deploys cleanly
After running `099_reservation_polish.sql`:
```sql
-- All 6 RPCs registered?
SELECT proname FROM pg_proc WHERE proname IN (
  '_sbp_reservation_expected_at',
  'sbp_reservation_notify_sent',
  'sbp_reservations_blocked_tables',
  'sbp_reservation_auto_release_no_shows',
  'sbp_update_reservation_settings',
  'sbp_get_reservation_settings'
);
-- Expected: 6 rows
```

### Test 2 — pg_cron job scheduled
```sql
SELECT jobname, schedule FROM cron.job WHERE jobname='sbp_reservation_no_show_sweep';
-- Expected: 1 row with schedule = '*/5 * * * *'
```

If you get **zero rows**: pg_cron extension isn't installed. Enable it in Supabase Dashboard → Database → Extensions, then re-run only the cron.schedule block:
```sql
SELECT cron.schedule(
  'sbp_reservation_no_show_sweep',
  '*/5 * * * *',
  $$SELECT public.sbp_reservation_auto_release_no_shows();$$
);
```

### Test 3 — Manual sweep test
```sql
SELECT sbp_reservation_auto_release_no_shows();
-- Expected: {"ok":true, "swept_count":0, "shops_affected":0, "ran_at":"..."}
```

### Test 4 — Settings round-trip
1. Open `settings.html` → scroll to "Reservations" group
2. Verify it loads with current values (default 15 / 120 / 30)
3. Change values to e.g. 20 / 90 / 45
4. Click Save → expect "✓ Saved" green message
5. Refresh page → values persist

### Test 5 — Block overlay on tables
1. In `reservations.html`, create a reservation:
   - Name: "Test Guest", Phone: "9876543210", Date: today, Time: current time + 5 min
   - Party size: 4
2. Confirm it AND assign to a specific table (e.g. T1)
3. Open `tables.html` → T1 should show:
   - Orange border
   - Badge: "Reserved [time] — Test Guest (4)"
4. Move to time = current time + 30 min → T1 still shows badge (in block window)

### Test 6 — Walk-in warning modal
1. With T1 still in a reservation block window (from Test 5)
2. In `tables.html`, click T1 (which is `free` status but has a block)
3. Warning modal should appear: "Table is reserved... Use Anyway?"
4. Click "Cancel" → modal closes, no action taken
5. Click T1 again → click "Use Anyway" → existing flow proceeds (seat guests modal)

### Test 7 — Notify button
1. In `reservations.html`, find a confirmed reservation with a phone number
2. Tap the green `📱 Notify` button
3. WhatsApp Web/App should open with pre-filled message:
   ```
   Hi [Name]! Your table reservation at [Shop] is confirmed:
   📅 Date: Tuesday, 27 May 2026
   🕐 Time: 20:00
   👥 Party of: 4
   📍 [Shop Address]
   📞 [Shop Phone]
   Please call us if any changes. See you soon!
   ```
4. Send it (or close WhatsApp)
5. Back in `reservations.html`, the reservation row should show:
   - "✓ NOTIFIED" badge next to status chip
   - Button changed to green `🔁 Resend`

### Test 8 — Auto no-show release
1. Create a reservation for the past (e.g. yesterday at 8 PM)
2. Confirm it (assign table)
3. Wait for next 5-min cron tick, OR manually run:
   ```sql
   SELECT sbp_reservation_auto_release_no_shows();
   -- Should return swept_count >= 1
   ```
4. Refresh `reservations.html` → that reservation now shows status `no_show`

---

## ROLLBACK

If something breaks badly:

```sql
-- Unschedule the cron job
SELECT cron.unschedule('sbp_reservation_no_show_sweep');

-- Drop the new columns (settings will revert to nothing)
ALTER TABLE shops
  DROP COLUMN IF EXISTS reservation_block_before_min,
  DROP COLUMN IF EXISTS reservation_block_after_min,
  DROP COLUMN IF EXISTS reservation_no_show_min;

ALTER TABLE sbp_table_reservations
  DROP COLUMN IF EXISTS notified_at,
  DROP COLUMN IF EXISTS notification_count,
  DROP COLUMN IF EXISTS auto_released_at;

-- Drop the RPCs
DROP FUNCTION IF EXISTS sbp_reservation_notify_sent(uuid);
DROP FUNCTION IF EXISTS sbp_reservations_blocked_tables(uuid);
DROP FUNCTION IF EXISTS sbp_reservation_auto_release_no_shows();
DROP FUNCTION IF EXISTS sbp_update_reservation_settings(int, int, int);
DROP FUNCTION IF EXISTS sbp_get_reservation_settings();
DROP FUNCTION IF EXISTS _sbp_reservation_expected_at(date, text);

NOTIFY pgrst, 'reload schema';
```

Then `git revert` the HTML/JS file changes.

---

## HONEST FLAGS

1. **Schema assumption — reservations table column names.** Per the reservations.html audit (22-May-26), I'm assuming `sbp_table_reservations` has columns `customer_name`, `customer_phone`, `customer_email`, `reservation_date`, `time_slot`, `party_size`, `status`, `table_id`. Migration 099 has defensive schema checks that fail fast with a clear error if any of these are wrong. **If the migration fails at the schema check stage, paste me the error message and I'll fix in v6.1.**

2. **Time zone assumption — IST.** The `_sbp_reservation_expected_at()` helper treats stored time_slot as Asia/Kolkata. If your installation is for a different timezone, this needs updating. Indian shops only: safe.

3. **pg_cron requires extension.** If pg_cron isn't installed, the migration completes (with a WARNING in logs) but auto-release won't run. Fall back: just enable pg_cron in Supabase Dashboard → Database → Extensions, then re-run the cron.schedule call.

4. **Notify button depends on `sbp_reservations_list` returning `notified_at`.** I don't have the source for that RPC. If it doesn't return `notified_at`, the "✓ NOTIFIED" badge won't appear (but the notify flow will still work — just won't show the badge until the RPC is updated to include the new column). **Easy fix if needed:** update `sbp_reservations_list` to `SELECT ..., notified_at, notification_count, ... FROM sbp_table_reservations` — I can write that patch if/when you confirm.

5. **No SMS or email channels.** WhatsApp only, per locked spec. SMS/email can be added later via MSG91 (pending Meta approval) without changing this bundle's database schema.

6. **Bill split/merge feature is NEXT.** This bundle is reservation polish only. Bill split is the next session per locked queue.

---

## AFTER DEPLOY

Run through the 8-step test plan. Report:
- ✅ What works
- ❌ What fails (with screenshot or error message)

If migration 099 fails at the schema check stage, that means the actual reservation columns differ from what reservations.html v1 suggests. Paste me the exact error and I'll iterate to v6.1.

Otherwise: this bundle should ship cleanly. Operational impact: notify flow saves staff 1-2 minutes per reservation, table blocking prevents double-bookings, auto-release keeps the table grid accurate without manual cleanup.
