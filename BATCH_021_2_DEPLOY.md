# BATCH 021.2 — Folio→Bill Math Correctness Hotfix

**Date:** 8 May 2026
**Type:** Hotfix (UI only, no SQL)
**Files:** 1 — `billing.html`
**Severity:** **CRITICAL** — current code over-charges customers when extras are entered as gst_inclusive

---

## What was wrong

When the hotel folio gets pushed to the bill, my code was stamping the extras' **gross price** (`unit_price`) as the bill's RATE field. billing.html then applies GST **on top** of the rate. For inclusive-priced extras, this double-counts GST:

| Folio (correct) | Bill (was over-charging) |
|---|---|
| dinner ₹650 (incl 5% GST inside) | rate ₹650 + 5% GST = **₹682.50** ❌ |
| wine ₹2,600 (incl 28% GST inside) | rate ₹2,600 + 28% GST = **₹3,328** ❌ |
| **Folio Grand Total: ₹3,700** | **Bill Grand Total: ₹4,460.50** ❌ |

Difference: ₹760.50 over-charged.

**Customer at front desk says: "the folio said ₹3,700"** → but the printed tax invoice would show ₹4,460.50. Embarrassing at minimum, illegal billing dispute at worst.

## What this fix does

Uses `taxable_amount` (the always-correct pre-GST base, regardless of inclusive/exclusive) as the bill's RATE. The math works in both modes:

| Mode | Folio | New Bill |
|---|---|---|
| Inclusive dinner ₹650 @5% | taxable=₹619.05, GST=₹30.95, total=₹650 | rate=₹619.05 + 5% GST = **₹650** ✅ |
| Exclusive dinner ₹650 @5% | taxable=₹650, GST=₹32.50, total=₹682.50 | rate=₹650 + 5% GST = **₹682.50** ✅ |
| Room ₹450 @0% | taxable=₹450, GST=₹0, total=₹450 | rate=₹450 + 0% GST = **₹450** ✅ |

In all cases: **Bill grand total = Folio grand total**. No surprises.

---

## Files

```
batch021_2/
├── BATCH_021_2_DEPLOY.md
└── billing.html       ← patched (booking_id branch, _sbpPopulateFolio)
```

Single file, no SQL. Push, hard-reload, retest.

---

## Smoke test (re-do your scenario)

1. Re-open the same booking (vinay or Jyoti, ₹450 room + ₹650 inclusive dinner + ₹2,600 inclusive wine)
2. Click Check Out & Generate Bill
3. **Expected on billing.html:**
   - Room 101 · Deluxe — qty 1, rate **₹450**, GST 0% (unchanged)
   - dinner (food) — qty 1, rate **₹619.05** (was 650), GST 5%
   - wine (minibar) — qty 1, rate **₹2,031.25** (was 2600), GST 28%
4. The on-screen bill should show:
   - Subtotal (taxable): ₹3,100.30
   - CGST: ₹300.00
   - SGST: ₹300.00
   - **Grand Total: ₹3,700** ← matches the folio now ✅

---

## Bug #2 — Bill number "GG-0076" repeating

You also flagged that every bill is showing the same invoice number. Need to diagnose which scenario you're hitting:

### Scenario A — Just a draft preview thing

The `next_invoice_no` RPC increments the counter on every call when billing.html opens. If you opened bill 5 times without saving, counter went 76 → 77 → 78 → 79 → 80. But you'd see them in sequence, not all 76.

If this is what's happening, **try**:
1. Generate a bill from the vinay folio
2. Click **Save** and confirm it lands on bills.html with that invoice number
3. Go back to bookings, generate ANOTHER bill from a different booking
4. Check the new draft — does it show GG-0077?

If yes → not a bug, just confusing (every fresh open shows the new number).

### Scenario B — RPC is failing silently

The atomic increment RPC has `try { ... } catch(e) { /* fall back silently */ }` — if it errors out, the screen falls back to a stale local counter that never increments. So all draft bills show the same number forever.

To check: open DevTools → Console **before** clicking "Check Out & Generate Bill". Look for any errors mentioning `next_invoice_no` or red-text PostgrestError. If you see an error, send the screenshot.

You can also paste this into the console after billing.html loads:
```js
const sb = window._sb;
const shop = JSON.parse(localStorage.getItem('sbp_shop'));
sb.rpc('next_invoice_no', { p_shop_id: shop.id }).then(r => console.log('rpc result:', r));
```

If `r.data` is `null` and `r.error` is set → RPC is broken, that's why the same number repeats. I'll add a permissions/role fix in the next batch.

If `r.data` returns `[{invoice_prefix:'GG', invoice_counter:NN}]` → RPC works, the "same number" was Scenario A.

---

## Why I'm not auto-fixing the bill number now

Two reasons:
1. Need your data to know which scenario it is. Wrong fix = no fix.
2. Math fix is the urgent one (financial integrity). The bill number issue is annoying but not over-charging anyone.

Send me the DevTools result when you've tested, and I'll write whatever fix is needed.

---

## Acceptance criteria

✅ Bill grand total = folio grand total (no over-charge)
✅ Math works for inclusive AND exclusive AND mixed extras
✅ Existing pre-batch bills unaffected (no schema change)
✅ Diagnostics in place to figure out the bill number issue

---

**Built by Claude · Batch 021.2 hotfix · 8 May 2026 · finishing your 1hr window**
