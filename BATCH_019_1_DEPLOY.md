# BATCH 019.1 — Hotel Folio → Bill Hotfix

**Date:** 8 May 2026
**Type:** Hotfix (no migration)
**Files:** 2 — `bookings.html` + `billing.html`

---

## What broke

After deploying Batch 019, when a hotel checked out a guest via "Check Out & Generate Bill", billing.html showed the green banner "Hotel checkout — folio loaded as bill items. Review and save." but the items list was empty (just a blank row showing product typeahead suggestions like Acai peanut, Curd, gulab jamun, rice).

## Root cause

In billing.html, the `?booking_id=…` URL branch was calling:

```js
const list = await SBPHotel.bookings.list(shopId, 'all', null);
```

But the `sbp_bookings_list` RPC doesn't accept `'all'` as a `p_filter` value — it expects one of `upcoming` / `today` / `in_house` / `checked_out` / `cancelled`. So the RPC either returned an empty list or filtered the booking out, and the subsequent `find(x=>x.id===bookingId)` returned `undefined`.

Worse: this happened **after** the server-side `checkOut()` already changed the booking's status to `checked_out`. So even with a valid filter, you'd need to query the right one.

The toast `"⚠️ Booking not found"` did fire, but it dismisses in 3 seconds and was easy to miss while the green banner stayed put.

This was NOT caused by Batch 019's changes — Batch 015 (hospitality phase 1) shipped this branch with the wrong filter. It just hadn't been smoke-tested end-to-end with a real checkout until now. Batch 019 didn't break it; it surfaced it.

## What this fix does

Two-pronged:

### 1. Primary path: stash folio in sessionStorage before redirect

`bookings.html → doCheckOut()` now snapshots the folio (booking + extras) into `sessionStorage.sbp_pending_folio` **before** the redirect. The bookings page already has all this data loaded in memory (it's displaying it in the modal), so this is free.

`billing.html` reads sessionStorage first. If the booking_id matches, it populates instantly with no async round-trip. The stash is one-shot — read once and removed.

### 2. Fallback path: hardened async fetch

If sessionStorage is empty (e.g. user navigated to billing.html?booking_id=X manually, or the stash failed), the fallback async fetch now:
- Tries multiple valid filters in order: `checked_out` → `in_house` → `today` → `upcoming`
- Falls back to a direct Supabase `from('sbp_bookings').eq('id', X)` query if all filters miss
- Logs every step to DevTools console with `[BookingCheckout]` prefix
- Replaces the green success banner with a **red error banner** in the items area if it can't recover, instead of a tiny toast

### 3. Bonus: Batch 019 kind/IDs stamped automatically

Each room line gets `data-kind="room"` + `data-room-type-id` + `data-booking-id`. Each extra gets `data-kind="service"` (if category is salon/spa/laundry/massage/transport/tour) or `data-kind="product"` (food/minibar/etc), plus `data-booking-id`. This means when the bill saves, the proper kind + room_type_id + booking_id get persisted to `bill_items` — leveraging the schema additions you already deployed in Batch 019.

---

## Deploy steps

### Step 1 — Push 2 files

| From zip | To repo |
|---|---|
| `bookings.html` | `/bookings.html` (overwrites) |
| `billing.html` | `/billing.html` (overwrites — supersedes the Batch 019 version) |

Commit message:
```
Batch 019.1: hotfix hotel folio → bill flow — stash folio in
sessionStorage before redirect, harden async fallback with valid
filters + direct query fallback, stamp kind/booking_id on rows
```

No SQL migration needed.

### Step 2 — Smoke test (the same scenario from your screenshot)

1. Hard reload the bookings page (Ctrl+Shift+R) to bust the cache
2. Open the **vinay** booking detail modal (Room 101 · Deluxe · 1 night · ₹600 · with hair saloon ₹350 + dinner ₹900 = ₹1,850)
3. Click **"🧾 Check Out & Generate Bill"** → confirm
4. **Expected:** billing.html opens with:
   - Customer name "vinay" pre-filled
   - **3 item rows** populated:
     - `Room 101 · Deluxe (8 May 2026 → 9 May 2026)` — qty 1, rate ₹600
     - `hair saloon (salon)` — qty 1, rate ₹350 (tagged as service)
     - `dinner (food)` — qty 1, rate ₹900 (tagged as product)
   - Green banner across the top
5. Click Save → bill generated with all 3 lines and the right total ₹1,850

### Step 3 — DevTools console check (optional but recommended)

Before clicking the green save button, open DevTools → Console. You should see:
```
[doCheckOut] pre-fetched extras: 2
[doCheckOut] folio stashed for booking <uuid>
[BookingCheckout] using stashed folio from sessionStorage
[FolioPopulate] booking= {…} extras= [{…}, {…}]
[FolioPopulate] done — rows now: 3
```

If you see `[BookingCheckout] no stashed folio in sessionStorage` instead, the bookings.html part didn't update — check that you pushed both files.

If you see `[BookingCheckout] filter=checked_out ok=true n=…` lines, the fallback path is being used — that means sessionStorage didn't catch (still works, just slower).

If anything fails, the red error banner will tell you why — and the console log will too.

---

## Rollback

`git revert` the commit. The Batch 019 version of billing.html will be restored. The folio bug returns but no other regression.

---

## Files in this zip

```
batch019_1/
├── BATCH_019_1_DEPLOY.md
├── bookings.html       ← patched (doCheckOut stashes folio)
└── billing.html        ← patched (sessionStorage primary path + hardened fallback)
```

---

**Built by Claude · Batch 019.1 hotfix · 8 May 2026 · 5:25 AM IST**
