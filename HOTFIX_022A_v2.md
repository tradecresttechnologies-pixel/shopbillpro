# Hotfix 022A v2 — Two real bugs you flagged

## Bug 1: Check Out & Bill button just lands on bookings list

**Problem:** Folio's "Check Out & Generate Bill" button navigated to
`bookings.html?id=xxx&action=checkout`, but bookings.html ignored the
URL params and just showed the list. Operator was stuck.

**Root cause:** I assumed bookings.html already handled deep-links from
URL params. It didn't — its init() never read `?id=` or `?action=`.

**Fix:** Added a deep-link handler at the end of bookings.html init():
1. After bookings load, parse `?id=` from URL
2. If present, find that booking (fetches full 'all' list as fallback if
   not in current filter view) and call `openDetail(id)` to open the modal
3. If `?action=checkout` is also present, wait 300ms for the modal to
   paint, then call the existing `doCheckOut()` function which generates
   the bill via the proven flow
4. Strip params from URL via `history.replaceState` so a refresh doesn't
   re-trigger checkout

The existing checkout logic in bookings.html is unchanged — we just
wire the URL params to it. This means folio.html → "Check Out & Bill"
now works end-to-end: opens modal, runs check-out, generates bill,
lands on bills.html with the receipt.

## Bug 2: ✎ edit on catalog item doesn't actually save

**Problem:** Tapping ✎ on a catalog item (say "Breakfast ₹150") opened
the modal pre-filled, but clicking save just added that line to the
folio — the catalog price stayed ₹150. So if Breakfast went up to ₹200,
operators had to override every single time.

**Root cause:** I shipped 028 with `_list / _add / _remove` RPCs but
forgot `_update`. So edits couldn't persist.

**Fix (two parts):**

1. **New RPC `sbp_folio_extras_catalog_update(shop_id, id, jsonb)`** —
   in migration 028a (small additive migration, doesn't touch 028).
   Partial-update semantics via `COALESCE` — supply only the fields you
   want to change, others stay untouched.

2. **Repurposed the edit modal in folio.html.** Now ✎ opens the modal in
   "edit catalog" mode with two save buttons:
   - **💾 Save to Catalog** (amber, primary) — persists the change so
     next time defaults are right. No folio line added.
   - **💾 Save & Add to Folio Now** (green, secondary) — does both in
     one tap: saves the new defaults AND adds the line at the new rate.
   - Cancel — does neither.

   Title becomes "✎ Edit catalog item" with subtitle "Changes are saved
   to the catalog so future adds use these defaults."

   The ➕ Custom Extra button still opens the same modal in
   "add custom" mode (single "💾 Add to Folio" button).

## Files in this hotfix (3)

```
db/migrations/028a_folio_catalog_update.sql   ← NEW (small additive migration)
folio.html                                    ← drop-in replace
bookings.html                                 ← drop-in replace
```

No other files changed.

## Deploy order

1. **SQL** — run `028a_folio_catalog_update.sql` in Supabase SQL Editor.
   Idempotent. Just adds the missing _update RPC.
2. **Frontend** — GitHub Desktop → push folio.html and bookings.html.
3. **Hard-refresh PWA** (or bump SW cache version).

## End-to-end test

1. Open Folio → pick any in-house guest
2. In Quick Add Extras, hover Breakfast (per person) ₹150 → tap ✎
3. Modal opens "✎ Edit catalog item". Change rate to 200. Tap
   **💾 Save to Catalog**. Toast: "✓ Catalog updated".
4. Modal closes. Tile now shows ₹200 (catalog refreshed).
5. Tap the tile (regular, no ✎) → Breakfast added at ₹200, not ₹150.
6. Now click "✓ Check Out & Generate Bill" on the right column
7. Should navigate to bookings.html, modal auto-opens for that guest,
   doCheckOut() auto-fires, bill is generated, lands on bills.html
   with the freshly minted invoice.
