# ShopBill Pro — Audit Round 2 Addendum
*Builds on the original audit. Run BOTH SQL patches on Supabase.*

## What's added in this round

### Phase 1 UPI Enhancement ✅

**Send WhatsApp with UPI QR Image**
- New 3-option WA send modal in billing.html: Text, Bill+QR Image, PDF Image
- Generates a clean payment card (shop name, amount, scannable UPI QR) using `qrcodejs` + `html2canvas`
- Uses Web Share API on mobile (one tap → WhatsApp gallery picker)
- Falls back to download + open WhatsApp on desktop
- "Bill + UPI QR Image" is highlighted as RECOMMENDED for credit/pending bills

**Mark-as-Paid Follow-Up**
- After sending a payment reminder via WhatsApp, a follow-up modal appears asking "Did the customer pay?"
- One tap → applies payment FIFO to oldest open bills, updates customer ledger, syncs to Supabase, posts to audit log
- Tracked in `sbp_reminder_log` localStorage so you can see reminder history

### Reports Professional Upgrade ✅

**Four new pro-grade tabs** (in addition to existing Sales/Daily/GST/Customers/Items/Voids/Insights/Forecast):

1. **GSTR-1** — Outward supplies report
   - Auto-splits invoices into B2B (with GSTIN) vs B2C
   - Shows taxable value, IGST, CGST, SGST per section
   - **Export B2B CSV** in GSTN-portal format (GSTIN of recipient, invoice details, tax breakdown)
   - **Export B2C Summary CSV** grouped by place-of-supply × rate

2. **GSTR-3B** — Monthly tax summary
   - 3.1(a) Outward taxable supplies — taxable value, IGST, CGST, SGST
   - 3.1(c) Nil-rated/exempt supplies
   - **Export GSTR-3B CSV** in standard return format

3. **P&L Statement** — true profit & loss
   - Net Sales (excl. GST pass-through, less discounts)
   - **COGS** computed from product `cost_price` × quantities sold
   - Gross Profit + Gross Margin %
   - Operating Expenses
   - **Net Profit** with up/down indicator
   - Warns when units sold are missing cost prices
   - **Export P&L CSV**

4. **Payments Breakdown**
   - Per payment-mode (Cash, UPI, Card, Bank, Cheque, Credit)
   - Amount + bill count + percentage with progress bars
   - **Export Payments CSV**

**Period Comparison on Sales**
- Top of Sales tab now shows previous-period comparison strip
- "Last week → this week", "Last month → this month", etc.
- Sales delta and bill count delta shown as growth %

### Bug fix in this round

**Regression fix from audit round 1** — the bulk timezone helper got injected INSIDE `<script src="...">` tags in 11 files, causing helpers to silently not execute (script-tag-with-src ignores body content). All files now have helpers in their own inline `<script>` blocks.

## Files modified (this round)

`reports.html` (4 new report tabs + period comparison)
`billing.html` (WA send modal + QR image + html2canvas added)
`customers.html` (Mark-as-Paid follow-up)
`bill-templates.html` `cash-register.html` `recurring.html` `stock.html` `supplier.html` `wa-center.html` `marketing.html` `settings.html` `bills.html` (regression fix for inline-script injection)

## Verification checklist (this round)

- [ ] Open Reports → click GSTR-1 tab → see B2B/B2C split → Export B2B CSV opens in Excel cleanly
- [ ] Open Reports → click GSTR-3B → see 3.1(a) and 3.1(c) populated
- [ ] Open Reports → click P&L → see Net Sales / COGS / Gross Profit / Net Profit. Set a `cost_price` on a product, sell it, verify COGS appears.
- [ ] Open Reports → click Payments → see each payment mode with %
- [ ] Sales tab → if any bills exist in previous period, see "vs previous month/week" comparison strip with growth %
- [ ] Create a bill with a customer who has WhatsApp + your UPI ID set in Settings → click WA → pick "Bill + UPI QR Image"
   - On mobile: Share sheet opens → pick WhatsApp → image attaches with caption
   - On desktop: image downloads + WhatsApp Web opens with text
- [ ] Customers page → click reminder bell on overdue customer → after WA opens, return to app → "Did they pay?" modal appears → tap "Yes mark paid" → balance updates
- [ ] Pages load without JS errors (open DevTools console, navigate to each page)
