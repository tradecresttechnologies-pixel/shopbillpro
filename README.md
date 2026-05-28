# ShopBill Pro — v8.4 Restaurant Bill Print + Service Badge Fix

**Bundle:** `ShopBillPro_v8.4_restaurant_print.zip`
**Date:** 2026-05-27
**Files changed:** 2 (`running-order.html`, `bills.html`)
**Independent of v8.2 / v8.3 — can be deployed standalone**

---

## What this fixes

### Issue 1 — No way to print bill BEFORE settlement (restaurant flow)

In restaurants, the bill is brought to the customer's table for review
BEFORE payment. The customer checks the items, then pays. Currently the
running-order billing wizard goes:

```
[Customer details] → [Review & discount] → [Payment] → [Save + Print]
```

There's no print step before payment. The customer has to either trust
what's on screen or wait until settlement to see a printed bill — which
is too late if they want to dispute an item.

**Fix:** Added a "🖨️ Print Bill" button on Step 2 (Review). Clicking it
opens an 80mm thermal print preview clearly labeled "FOR REVIEW — NOT
A TAX INVOICE", with all items, GST, discount, and total. No invoice
number is allocated yet (the formal tax invoice gets one at settlement).

The wizard flow becomes:

```
[Customer details] → [Review & discount] ──[🖨️ Print Bill]──> Customer reviews
                          ↓
                     [Payment]
                          ↓
                     [Save + Print formal tax invoice]
```

The Print button appears only on Step 2. Step 1 (no items yet) and
Step 3 (already at payment) don't show it.

### Issue 2 — Bills show "🍽 SERVICE" badge on restaurant food items

In the bill view + print template, every restaurant menu item shows a
pink "✂️ SERVICE" badge. Reason: restaurant menu items are stored in
the `services` table (which makes sense at the DB level — they're not
inventory items), so `bill_items.kind = 'service'`. The badge code at
`bills.html:770` then renders "Service" for anything with kind=service.

For a salon or repair shop this badge is helpful (distinguishes a
haircut from a hair product sale). For a restaurant it's wrong — every
item is a food item; the "service" label adds noise without
information.

**Fix:** Suppress the kind badge (Service / Room) entirely when the
shop_type belongs to the `food` macro. Food shop_types:
`restaurant, cafe, qsr, ice_cream, cloud_kitchen, tiffin, catering,
bar_lounge, food_other` (matches `lib/sidebar-engine.js`
`MACRO_BY_SHOP_TYPE`).

Salons, repair shops, beauty parlors, etc. — badge stays unchanged.

---

## DEPLOY PATHS

| Action  | Path                  | Notes                                  |
|---------|-----------------------|----------------------------------------|
| REPLACE | `running-order.html`  | Repo root. Print Bill button on Step 2 + bwPrintPreliminaryBill function. |
| REPLACE | `bills.html`          | Repo root. Suppress Service/Room badge for food shops. |

Both files at repo root. No SQL changes. No Supabase work. No
dependencies on v8.2 or v8.3 — deploys cleanly on top of the current
live v8.1.

## Deploy steps

1. GitHub Desktop → drop the 2 files into repo root (overwrite).
2. Commit: "v8.4 — Restaurant: print bill before settlement, hide Service badge"
3. Push to main → Vercel auto-deploys (~2 min).

---

## Verification

### Test 1 — Print bill before settlement

1. Open a restaurant shop's `running-order.html`
2. Add some items to a table's order
3. Click "Generate Bill" → wizard opens on Step 1 (Customer)
4. Click "Next →" → Step 2 (Review & discount)
5. **You should see a "🖨️ Print Bill" button** to the left of "Next →"
6. Click it → 80mm thermal print preview opens with:
   - Shop name + address + phone
   - Black banner: "FOR REVIEW — NOT A TAX INVOICE"
   - Date, Table number, Customer
   - All items with qty/rate/total
   - Subtotal, GST, Discount, TOTAL
   - Footer: "Please review the items above. A formal tax invoice will be issued after payment."
   - NO invoice number
   - NO payment block
   - Print dialog auto-opens
7. Close the print dialog. Go back to the wizard — it's still on Step 2 (the bill wasn't saved yet)
8. Click "Next →" → Step 3 (Payment) → settle as normal → formal tax invoice gets a real invoice number and prints with status PAID

### Test 2 — Service badge hidden for restaurant bills

1. Open `bills.html` on a restaurant shop
2. View any bill that has menu items (Dal, Naan, etc.)
3. **The items should NOT show a "✂️ Service" / "🍽 SERVICE" badge anymore.**
4. Print the bill (A4 or 80mm) — still no badge.

### Test 3 — Service badge still works for non-food shops

1. Switch (or test on a separate shop) to a salon `shop_type='salon'`
2. View any salon bill with mixed services + products
3. **Service items should still show the "✂️ Service" badge.**
4. Product items show no badge (correct, kind='product').

---

## Design decisions

**Why no invoice number on the preliminary bill?**
Indian restaurant practice: the "rough bill" given at the table doesn't
need to be a tax invoice. Only the final receipt (issued post-payment)
needs an invoice number for GST. If we reserved a number at Step 2 and
the customer walked out without paying, we'd burn a number with no
matching bill. Allocating at settlement (Step 3) is safer.

**Why suppress the kind badge instead of changing the label?**
Considered renaming "Service" → "Food" for restaurants, but: (1) "Food"
as a badge adds no info on a restaurant bill where everything is food;
(2) the `kind=service` value in DB is still correct (it's a server-
side classification, not a customer-facing label). Removing the badge
in the UI for food shops is the simpler, more correct fix.

**Why 80mm thermal and not A4 for the preliminary print?**
80mm thermal is the standard for table-side restaurant printing — it's
what most restaurant printers actually output. A4 would work too but
wastes paper for a review-only bill. If the user wants A4 too, can
add a size toggle in a follow-up.

---

## Rollback

`git revert` the v8.4 commit → both files return to pre-v8.4 state.
Print button vanishes, Service badge reappears. No data loss (no
schema change).
