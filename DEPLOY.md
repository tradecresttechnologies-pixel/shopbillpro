# Batch v4.7-HOTFIX — Booking "Stuck on Sending" Fix

**Delivered:** May 14, 2026

## The bug

Clicking "Send request" in the booking modal got stuck on "Sending..." forever.
No network request was ever made.

**Root cause:** Line 683 of `live-site.js` called `sessionStorage.getItem(...)`.
The AI website iframe runs in a sandbox with an opaque origin (no
`allow-same-origin`). Opaque-origin iframes throw a `SecurityError` when ANY
storage API is accessed — `sessionStorage` included.

The crash happened at line 683, BEFORE the code reached the `try/catch` block
around the actual RPC call (line 701). So:
- The exception was uncaught
- `submitBookingForm()` died mid-execution
- The button stayed on "Sending..." with no error shown
- The `sb.rpc('sbp_create_booking_public')` call was never reached

This is the same class of bug as the Web Locks API issue fixed earlier —
sandboxed iframes block browser storage APIs.

## The fix

Wrapped every `sessionStorage` access in try/catch, with an in-memory
module-level variable (`_sbpIpHashCache`) as the fallback. The rate-limit
token still works within a single page visit; it just isn't persisted across
reloads when storage is blocked — which is fine.

## DEPLOY PATHS

```
REPLACE  lib/live-site.js
```

**One file.** No SQL, no edge function, no s.html change.

## Deploy steps

1. Extract this zip
2. Copy `lib/live-site.js` → your repo's `/lib/live-site.js` (overwrite)
3. GitHub Desktop → commit: `Fix: guard sessionStorage in sandboxed iframe (booking stuck on Sending)`
4. Push origin → wait ~30 sec for Vercel
5. **Hard refresh** `/s/glitz-glam` with **Ctrl+Shift+R** (important — old JS is cached)

## Test

1. Open `/s/glitz-glam` in incognito
2. Click any "Book Now" button
3. Fill the form (name, phone, dates)
4. Click "Send request"
5. **Expected:** Within 1-2 seconds → green ✅ success screen with a
   confirmation code (8-char hex) + WhatsApp follow-up button
6. Switch to shop owner view → `/bookings.html` → the booking appears with
   a 🌐 Online tag, status `pending`

## Why this is the last booking blocker

Everything else is already proven working:
- ✅ `sbp_create_booking_public` RPC works (test booking 86BF7829 created
  successfully via direct SQL call)
- ✅ Migration 053 deployed (config RPC returns 200)
- ✅ The booking modal opens and the form renders correctly
- ✅ The v4.7 booking code is in the deployed file

The ONLY thing broken was the unguarded `sessionStorage` call crashing the
submit handler. This fix resolves it.

## Changes in this file vs the previous live-site.js

Two edits:
1. Added `let _sbpIpHashCache = null;` near the top of the IIFE (module-level
   in-memory fallback)
2. Replaced the unguarded `sessionStorage.getItem/setItem` block in
   `submitBookingForm()` with try/catch-wrapped versions

Everything else is identical to the previous version.

## Rollback

Git revert the commit. But there's no reason to — the previous version is
strictly broken (booking can never complete in the sandboxed iframe).
