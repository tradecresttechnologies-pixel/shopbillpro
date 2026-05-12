# Batch 028B — Bill print fix (CSS injection + watermark hardening)

**Scope:** Two surgical fixes for the bill print preview issue:

1. **Print layout broken** — `printBillPreview()` opened a print window
   with only a minimal stylesheet. The bill preview uses CSS Grid
   (`.bdoc-table-row { display: grid; grid-template-columns: 2fr .5fr .7fr .7fr }`)
   for the item rows, but those `.bdoc-*` rules weren't included in the
   print window's `<style>`. Result: grid collapsed → "DescriptionQtyRateAmount"
   mashed together, qty/rate/amount stacked vertically, no header background,
   no proper spacing. The whole thing looked like a plain unstyled HTML dump.

2. **Watermark always shows, includes parent company branding** — Line 723
   was hardcoded:
   ```html
   <div class="bdoc-brand">Powered by ShopBill Pro · TradeCrest Technologies Pvt. Ltd.</div>
   ```
   No plan check at all. Business and Pro plan shops still saw the watermark
   on every bill, with the parent company name appended.

## What changed

### File
```
bills.html   ← 1426 → 1478 lines (+52)
```

### Fix 1 — Print window CSS injection

In `printBillPreview()`, replaced the minimal print-window stylesheet
with the full `.bdoc-*` ruleset (34 rules) plus:

- `:root` CSS variables (`--font-h`, `--acc`, `--acc2`, `--acc3`, `--text`,
  `--t2`) so the existing rules that use `var(--…)` work as-is in the
  new window
- `-webkit-print-color-adjust:exact; print-color-adjust:exact;` so the
  dark gradient header + status badges + UPI block actually print with
  their backgrounds (browsers strip backgrounds by default for ink savings)
- `page-break-inside:avoid` on `.bdoc-table-row` so item rows don't split
  across pages
- Size-mode overrides for 58mm/80mm thermal printers (smaller font, tighter
  padding) so the same template still works on receipt printers

The grid layout (`grid-template-columns: 2fr .5fr .7fr .7fr` — description
takes 2/3.9 = 51% width, qty 13%, rate 18%, amount 18%) now actually
applies in print. Item descriptions stay in their column, qty/rate/amount
sit aligned on the right.

### Fix 2 — Watermark plan-conditional + cleaned text

Line 723 in `openBillPreview`:

**Before:**
```html
<div class="bdoc-brand">Powered by ShopBill Pro · TradeCrest Technologies Pvt. Ltd.</div>
```
(always shown, no plan check)

**After:**
```html
${isFree()?'<div class="bdoc-brand">Powered by ShopBill Pro</div>':''}
```
- Uses the existing `isFree()` helper (line 39) which:
  - Normalizes `enterprise` → `business` (legacy alias)
  - Checks `plan_expires_at` — reverts to `free` if expired
  - Returns `true` only for genuinely-free plans
- Dropped "TradeCrest Technologies Pvt. Ltd." entirely. Only "Powered by ShopBill Pro"
  remains, and only on free-tier bills (the viral channel from memory).

Applies to BOTH the on-screen preview AND the print output (since print
copies the preview HTML).

## Deploy

1. Push `bills.html`
2. Bump SW v1.5.36 → v1.5.37
3. Hard-refresh

No SQL. No new JS files. No CSS file changes.

## Smoke tests

### Test 1 — Print layout actually renders
1. Open any bill (preferably one with a few items including a hotel
   booking — to stress-test the long description case)
2. Click **Print → A4**
3. In the print preview:
   - **Header** should have a dark green gradient background with white
     shop name + invoice number on it
   - **Items** should be in a proper 4-column grid: Description | Qty | Rate | Amount
   - Item names left-aligned, qty centered, rate + amount right-aligned
   - Each item on its own row (not stacked)
   - **Totals** right-aligned with Subtotal / CGST / SGST / Grand Total
   - **UPI block** has a light green background with the UPI ID

### Test 2 — Watermark plan check
1. **On a free-tier shop:** print a bill → footer should show
   "Powered by ShopBill Pro" (no parent company text)
2. **On a Pro or Business shop:** print a bill → footer should show
   ONLY "Thank you for your business! 🙏" — no "Powered by..." line at all
3. To verify which tier the shop is currently on, open DevTools console:
   ```js
   _sbpPlanInfo()  // → {plan: 'business', expired: false}
   isFree()        // → false (for paid plans)
   ```

### Test 3 — Thermal print still works
1. Open bill → Print → 58mm or 80mm
2. Should render compactly with smaller fonts, same grid structure but
   tighter

## Limitations / known follow-ups

These are NOT in 028B. Flagging for future batches if you want:

1. **Hotel item descriptions are verbose.** Bookings show:
   ```
   Room 101 · Deluxe (2026-05-12 → 2026-05-13)
   1 night × ₹999 | GST 0%
   ```
   The sub-line duplicates info already in qty/rate columns. Could be
   trimmed to just the dates, or moved to a separate booking-info block.
   Pre-beta cleanup.

2. **Emojis in print.** The current template uses 📞 📱 📍 🏛️ 💳 📅 🙏 📲
   throughout. They print but look a bit casual for formal invoices.
   Some shops may want to disable them via a setting.

3. **Other pages still have similar print bugs.** The same CSS-not-included
   pattern likely exists in `reports.html`, `compliance.html`,
   `customer-history.html`, `audit-log.html`. That's the full 028A audit
   I scoped earlier — this batch (028B) only fixed bills.html's bill print.

4. **WhatsApp message text** in bills.html line ~753 also includes
   "ShopBill Pro by TradeCrest Technologies" — should be cleaned for paid
   plans too. Quick follow-up if you want.

## Next priorities

After this lands and you verify the print looks right:

- **028A** — Full print stylesheet audit across the other 5 pages (~2-3h)
- **028C** (if needed) — Hotel description trim + emoji audit
- Pre-beta QA → **BETA LAUNCH** 🚀

If after deploying 028B the print STILL looks bad, send another screenshot
and I'll see what else needs to change. The injection should fix the
visible-grid-collapse issue. If the design itself isn't to your taste,
that's a separate redesign batch (which I can scope and quote).
