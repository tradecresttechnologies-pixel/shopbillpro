# Plan Gate Audit — Findings & Fix Plan

**Status:** RESEARCH COMPLETE. Audited live page gating vs locked
pricing before any code (revenue-protection task — guessing here
either leaks paid features or wrongly blocks payers).

---

## 1. Source of truth (locked pricing)

- **FREE** — basic billing, local-only, no cloud. Retail only.
- **PRO ₹99/mo** — cloud sync, basic reports, WhatsApp, catalog,
  customer DB, 5yr retention.
- **BUSINESS ₹499+GST/mo** — all verticals, GSTR, P&L, storefront,
  online ordering, loyalty, multi-user PINs, audit, 5yr retention.
- **Restaurants / hotels / premium verticals = BUSINESS only.**
  60-day trial (no card) → must pay ₹499. Retail-Free is permanent.

## 2. How the trial works (critical — verified)

`_sbpPlanInfo()` reads `sbp_shop.plan`. During a restaurant/hotel
60-day trial the backend sets `plan='business'` + `plan_expires_at`
= trial end. So `isBiz()` is TRUE during trial, flips FALSE on
expiry. **Therefore gating restaurant/hotel pages to `isBiz()` does
NOT lock out trial users** — it is exactly correct. This was the key
risk and it's cleared.

## 3. Findings — current gate vs required

| Page | Current gate | Required | Verdict |
|------|--------------|----------|---------|
| restaurant-reports.html | `isBiz()` + showGate | Business | ✅ correct |
| tables.html | `isPro()` "Upgrade to Pro" | Business | ❌ under-gated |
| running-order.html | `isPro()` only (no UI lock) | Business | ❌ under-gated |
| kitchen.html | `isPro()` "Upgrade to Pro" | Business | ❌ under-gated |
| rooms.html | `isFree()` block, "Upgrade ₹99" | Business | ❌ under-gated |
| bookings.html | `isFree()` block, "Upgrade ₹99" | Business | ❌ under-gated |
| folio.html | mixed isPro/isBiz | Business | ⚠️ verify |
| walk-in.html | mixed isPro/isBiz | Business | ⚠️ verify |
| menu.html | isPro/isBiz present | Business | ⚠️ verify |
| housekeeping.html | NO gate | Business | ❌ ungated |
| qr-menu.html | NO gate (anon customer page) | none (public) | ✅ correct |

**Revenue leak:** a PRO (₹99) shop today can use the full
restaurant suite (tables, KOT, running order, rooms, bookings) that
is supposed to be BUSINESS (₹499). That's a ~₹400/mo leak per
restaurant on Pro.

**Wrong messaging:** rooms/bookings tell users "Upgrade to Pro ₹99"
for a Business-only feature — both the gate AND the upsell are wrong.

## 4. Fix plan (UI-layer; server RPCs already owner-checked)

For every restaurant/hotel staff page: replace the `isPro()` /
`isFree()` gate with an `isBiz()` gate + a consistent "Upgrade to
Business" lock screen (mirror the proven restaurant-reports pattern).

Pages to fix: tables, running-order, kitchen, rooms, bookings,
housekeeping. Verify/normalise: folio, walk-in, menu.

Do NOT touch: qr-menu.html (anon customer page — must stay public),
core retail billing (billing.html stays Pro/Free as before — only
the *dine-in/table* path is Business).

**Trial safety:** because trial = `plan='business'`, every fix uses
`isBiz()` which is true throughout the trial. No trial user is
locked out. Expiry correctly flips them to the lock screen.

**Server side:** RPCs are already `_sbp_check_shop_owner` gated
(ownership), but that is NOT plan enforcement. UI gating is the
plan enforcement layer here; a deeper server-side plan check is
noted as future hardening (a determined user could call RPCs
directly) but is out of scope for this UI audit unless requested.

## 5. Decisions confirmed (no open questions)

- Restaurant/hotel = Business — locked, no ambiguity.
- Trial users unaffected — verified via plan mechanism.
- qr-menu stays public — it's the customer ordering page.
- Consistent lock UI = the restaurant-reports gate pattern.

Proceeding to implement §4.
