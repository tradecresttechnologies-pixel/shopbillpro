# Hotfix — Folio sidebar entry should land on a picker, not error out

**Issue (your screenshots):** Clicking "Folio" in the sidebar with no
specific booking selected → folio.html opens at `/folio` (no `?id=` param)
→ shows red error banner "No booking id in URL" → bounces back to
bookings.html. Dead-end UX.

**Root cause:** init() required a `?id=` param and treated its absence
as fatal. Wrong product behavior — like Stripe's `/customers` page
showing an error if you don't already know which customer you want.

**Fix:** Two-mode page. URL `/folio?id=xxx` → existing folio detail
view. URL `/folio` (no id) → new **folio picker** showing bookings
as cards.

## Picker mode

**Header:** "HOTEL FOLIOS" eyebrow + "Pick a folio to manage" title

**Filter tabs (with live counts):**
- In-House (default — guests currently checked-in)
- Today (any check-in/check-out today + currently in-house)
- Upcoming (future arrivals not yet checked in)
- Past (checked-out / cancelled / no-show)
- All

**Search bar** — filters by guest name / phone / room / ID / passport / country

**Cards (1 col mobile / 2 col tablet / 3 col desktop ≥1280px):**
Each card has:
- Status accent stripe top border (green=in-house, blue=confirmed,
  amber=pending, slate=checked-out, rose=cancelled)
- Colored avatar with guest initials
- Name (with FOREIGN tag if applicable)
- Sub-line: Room number + type + phone
- Status pill (top-right)
- Stay row: 📅 9 May → 11 May · 2n
- Footer: Balance Due (red) or Total (green if clear) + "Open Folio →" CTA

**Empty states:**
- No in-house guests right now → "Folios appear here as guests check in. Walk-ins from Front Desk land here too." + ⚡ New Walk-in button
- No search match → "Nothing matched 'X'. Try a different search."
- No past bookings → "Nothing here yet"

**Sort order:** in-house guests first (most actionable), then by check-in date desc

**Data:** uses existing `sbp_bookings_list(shop_id, 'all', null)` RPC —
one round trip pulls everything, client buckets per filter.

## What stays the same

Existing detail mode (URL with `?id=`) is untouched. All sidebar links
still go to bookings.html for the modal-based edit/check-out flow; new
"📋 Open Full Folio →" CTA inside the booking modal still goes to
folio.html?id=xxx (added in 022A v1).

## Files in this hotfix (1)

```
folio.html       ← drop-in replace
```

No SQL changes. No sidebar-engine.js changes.

## Deploy

GitHub Desktop → replace this file → push → hard-refresh.

## What you should see

- Click "Folio" in sidebar → lands on picker showing all current in-house
  guests as cards. No more red error.
- Tap any card → opens that guest's full folio (existing detail view)
- Filter tabs update live as you switch
- Search works across name/phone/room/ID
- Empty state for "In-House" tab when no guests are checked in: nice
  illustration + "New Walk-in" link to walk-in.html
