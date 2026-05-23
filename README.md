# ShopBill Pro v6 — Reservation Polish

## Drop-in file structure
Paths in this zip = paths in your repo. Just copy them in.

## Deploy steps

### 1. Enable pg_cron extension
Supabase Dashboard → Database → Extensions → search "pg_cron" → Enable.
(Skip if already enabled.)

### 2. Run SQL migration
- `db/migrations/099_reservation_polish.sql`

### 3. Replace files in your repo (4 files)
- `lib/reservation-state.js` (NEW FILE)
- `tables.html` (REPLACE)
- `settings.html` (REPLACE)
- `reservations.html` (REPLACE)

### 4. Push via GitHub Desktop → Vercel auto-deploys

## Full deploy guide
See `docs/DEPLOY_v6_reservation_polish.md` for:
- 8-step test plan
- Rollback procedure
- Honest flags about schema assumptions

## What's in this bundle

| Path | Purpose | Size |
|------|---------|------|
| `db/migrations/099_reservation_polish.sql` | Schema + 6 RPCs + pg_cron job | 18KB |
| `lib/reservation-state.js` | Shared helper for block-state lookups | 5KB |
| `tables.html` | Block overlay + warning modal on walk-in | 63KB |
| `settings.html` | New "Reservations" section (3 settings) | 162KB |
| `reservations.html` | Notify button + WhatsApp flow + badges | 40KB |
| `docs/DEPLOY_v6_reservation_polish.md` | Full deploy guide + test plan | 9KB |

## What this delivers

- **One-tap WhatsApp notify** for confirmed reservations
- **Automatic table blocking** during reservation windows
- **Auto no-show release** via pg_cron every 5 min
- **Owner-configurable** windows per shop (not hard-coded)
