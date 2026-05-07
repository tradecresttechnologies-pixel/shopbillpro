# ShopBill Pro — Batch 017: Hospitality + Customer fixes

**Date:** 7 May 2026
**Scope:** 6 bugs from yesterday's testing (BUG-020 through BUG-025)
**Risk:** Medium — touches billing.html, bookings.html, rooms.html, sidebar engine + 1 new SQL migration
**Estimated deploy time:** ~5 min

---

## What's fixed

| Bug | Severity | Fix summary |
|---|---|---|
| BUG-020 | HIGH | Customer history stats — RPC now matches bills by id OR name OR phone OR whatsapp |
| BUG-021 | MEDIUM | Folio sidebar item removed (was duplicating Bookings, confused users) |
| BUG-022a | MEDIUM | Folio modal too narrow on desktop — now widens to 760px on screens ≥1024px |
| BUG-022b | MEDIUM | Print Folio button added to detail modal — opens print-friendly window |
| BUG-023 | HIGH | Hotel guests auto-create customer record (was orphan) |
| BUG-024 | MEDIUM | + FAB icon now renders correctly (system font + flex centering) |
| BUG-025 | **CRITICAL** | Booking → Bill prefill **now works** — hospitality.js loads before init() |

---

## Files in this batch (6 files)

| Path | Action | What it does |
|------|--------|--------------|
| `db/migrations/018_batch017_bugfixes.sql` | NEW | Updates `sbp_bookings_create` (auto-create customer) + `sbp_get_customer_timeline` (phone fallback) |
| `billing.html` | MODIFIED | hospitality.js script tag moved to top of file |
| `bookings.html` | MODIFIED | FAB CSS, modal width, Print Folio button + handler |
| `rooms.html` | MODIFIED | FAB CSS, modal width |
| `lib/sidebar-engine.js` | MODIFIED | Removed duplicate `folio` menu entry |
| `lib/hospitality.js` | UNCHANGED | Same as Batch 015, included for completeness |

---

## Critical fix detail — BUG-025

This was the most important bug. Here's exactly what was happening:

```
billing.html load order:
  Line   52: <script src="lib/sidebar-engine.js"></script>
  Line 3480: init();                          ← runs here
  Line 3889: <script src="lib/hospitality.js">  ← loads AFTER init ran
```

When init() fired the booking_id branch, it checked `window.SBPHotel`,
found undefined, and toasted "Hospitality module not loaded" before
bailing. The folio prefill code was correct — it just never ran.

**Fix:** moved `<script src="lib/hospitality.js">` up next to sidebar-engine.js
at line 53, so it loads before `init()` runs.

Also added a defensive 3-second wait in the prefill async block — if
hospitality.js hasn't finished loading for some reason (slow first visit,
service worker issue), the code now waits up to 3s instead of bailing.

---

## Deploy steps

### Step 1 — SQL in Supabase SQL Editor

```sql
\i db/migrations/018_batch017_bugfixes.sql
```

Or paste manually. Idempotent. Runs in <2 sec.

### Step 2 — Verify SQL

```sql
-- (1) Both functions recompiled
SELECT proname, pg_get_function_arguments(oid)
FROM pg_proc
WHERE proname IN ('sbp_bookings_create','sbp_get_customer_timeline');
-- Expected: 2 rows

-- (2) BUG-020: Jyoti's stats should now be real
-- Get Jyoti's UUID:
SELECT id, name FROM customers WHERE name = 'Jyoti';
-- Then test:
SELECT sbp_get_customer_timeline('<jyoti-uuid>');
-- Expected: stats.total_bills = 7 (matching customer page),
--           total_spent ≈ 5177
```

### Step 3 — Push 5 files to GitHub PWA repo

```
db/migrations/018_batch017_bugfixes.sql   (new)
billing.html                              (modified)
bookings.html                             (modified)
rooms.html                                (modified)
lib/sidebar-engine.js                     (modified)
```

Vercel auto-deploys ~30 sec.

### Step 4 — Hard refresh (important — Service Worker may cache old billing.html)

In your phone or browser:
1. Long-press refresh → Empty Cache and Hard Reload (Chrome desktop)
2. OR uninstall + reinstall PWA on phone

---

## Smoke test checklist

### BUG-025 verification (the big one)
- [ ] Create or pick an existing booking with status `checked_in`
- [ ] Add an extra (e.g., Water bottle ₹25)
- [ ] Tap "Check Out & Generate Bill"
- [ ] Page redirects to billing.html with banner "🏨 Hotel checkout — folio loaded"
- [ ] **Items section shows: Room (qty=N, rate=X) + each extra as separate row** ← THIS WAS BROKEN BEFORE
- [ ] Subtotal, GST, Grand Total all calculate
- [ ] Toast: "🏨 Folio loaded — review items and save bill"
- [ ] Save bill → returns to bookings page → booking now shows 🧾 Bill tag

### BUG-021 verification
- [ ] Open Settings or any page with sidebar
- [ ] Scroll sidebar — **Folio menu item should NOT appear** (only Rooms + Bookings)
- [ ] Both Rooms and Bookings still navigate correctly

### BUG-022 verification
- [ ] On laptop (≥1024px wide): tap any booking
- [ ] Modal opens centered (not bottom-anchored), wider (~760px), looks comfortable
- [ ] On phone: still slides up from bottom, full-width, mobile feel preserved
- [ ] Detail modal shows new "🖨️ Print Folio" button (top of action buttons)
- [ ] Tap Print Folio → new window opens with formatted folio (shop name, guest, stay dates, charges table, totals)
- [ ] Browser print dialog auto-opens

### BUG-023 verification
- [ ] Create a new booking with a new guest name + phone (someone NOT in customers list)
- [ ] After save, navigate to Customers page
- [ ] **The new guest should appear in the customer list** ← was missing before
- [ ] Returning to bookings page, the booking should show under the same guest

### BUG-024 verification
- [ ] Open bookings.html
- [ ] FAB at bottom-right shows clean + sign (no clipping, no font glitch)
- [ ] On laptop: FAB sits at bottom:24px (close to corner)
- [ ] On phone: FAB sits at bottom:78px (above bottom nav)
- [ ] Tap FAB → New Booking modal opens

### BUG-020 verification
- [ ] Open Customer History → tap Jyoti
- [ ] **BILLS card now shows 7 (or your real count)** ← was 0 before
- [ ] Total Spent populates with real amount
- [ ] Timeline lists actual bills with dates

---

## Rollback plan

| Layer | Rollback |
|-------|----------|
| RPCs | Re-run migration 015 (which has the original `sbp_bookings_create`) and 017 (original `sbp_get_customer_timeline`) — both will overwrite the 018 versions back to their previous state |
| HTML/JS | `git revert <commit>` and push |

The SQL changes are pure RPC body updates — no schema changes, no data destruction. Safe to roll back without data loss.

---

## What's still open after this batch

These weren't in scope of Batch 017 — carryover to a future batch:

```
□ BUG-013   Email-confirm signup resume          (~1-2 hr)
□ Loyalty bill-void hook in bills.html           (~1 hr)
□ BUG-016   Marketing pamphlet redesign          (needs your assets)
□ BUG-017   Replace placeholder images           (needs your assets)
□ Stale folder cleanup (pages/, root js)         (~30 min)
```

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Batch 017 (7 May 2026)*
