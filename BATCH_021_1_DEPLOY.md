# BATCH 021.1 — Folio Display Hotfix

**Date:** 8 May 2026
**Type:** Hotfix (UI only, no SQL)
**Files:** 1 — `bookings.html`

---

## What was wrong

In Batch 021's folio display, the GST rollup was confusing:

```
EXTRAS (2)
  dinner [GST 5%]                          ₹650
  wine [GST 28%]                           ₹2,600
  Extras GST (CGST + SGST)                 +₹600     ← misleading "+"
─────────────────────────────────────────────────
Total Tax (CGST ₹300 + SGST ₹300)          ₹600     ← duplicate of above
Grand Total                                ₹3,700
```

Two problems:
1. **"Extras GST +₹600"** with a leading "+" looks like ₹600 is being **added** to the grand total. It isn't — when the extras are stored as GST-inclusive prices, the ₹600 GST is **already inside** the line totals. The "+" was misleading.
2. **"Total Tax (CGST ₹300 + SGST ₹300) ₹600"** is a duplicate of the same information — shown twice in different formats.

A reasonable person reading this screen does mental math `₹3,700 + ₹600 = ₹4,300` and asks "why is the grand total ₹3,700 not ₹4,300?"

The numbers under the hood are correct. The display was just badly rendered.

## What this fix does

**1. Per-line subtitle** — each extra now clearly says what's inside the price:

  - **Inclusive prices**: `incl. ₹30.95 GST · base ₹619.05` under the line amount
  - **Exclusive prices**: `₹650.00 + ₹32.50 GST` under the line amount

This means a glance at any line tells you exactly how the GST is structured for that line.

**2. Clean unambiguous rollup** at the bottom:

```
Subtotal (taxable)                ₹3,100.30
  CGST                            + ₹300.00
  SGST                            + ₹300.00
─────────────────────────────────────────────
Grand Total                       ₹3,700.00
  − Advance paid                  − ₹200.00
Balance Due                       ₹3,500.00
```

No duplicates, no misleading "+" symbols, accountant-readable.

**3. Room line also shows its own GST inline**:

```
Room (1 × ₹450) [GST 0%]
  GST exempt                              ₹450
```

or for a higher-priced room:

```
Room (1 × ₹2,500) [GST 5%]
  ₹2,500.00 + ₹125.00 GST               ₹2,625.00
```

---

## Files

```
batch021_1/
├── BATCH_021_1_DEPLOY.md
└── bookings.html       ← patched (renderDetail folio display rewritten)
```

---

## Deploy

Just one file. No SQL.

Push `bookings.html` to repo. Hard-reload (Ctrl+Shift+R) in the browser to bust cache.

## Smoke test — re-do your screenshot scenario

Same vinay / Room 101 / dinner ₹650 / wine ₹2,600 booking:

**Expected new display:**

```
🛏️ Stay
  Room                              101 (Deluxe)
  Check-in                          08 May 2026
  Check-out                         09 May 2026
  Nights                            1
  Rate                              ₹450/night (GST exempt)
  Advance                           ₹200 via ota_prepaid

📒 Folio
  Room (1 × ₹450) [GST 0%]
    GST exempt                                    ₹450

  EXTRAS (2)
    dinner [GST 5%]                               ₹650
      incl. ₹30.95 GST · base ₹619.05
    wine [GST 28%]                                ₹2,600
      incl. ₹568.75 GST · base ₹2,031.25
  ─────────────────────────────────────────────────
  Subtotal (taxable)                              ₹3,100.30
    CGST                                          + ₹300.00
    SGST                                          + ₹300.00
  ─────────────────────────────────────────────────
  Grand Total                                     ₹3,700.00
    − Advance paid                                − ₹200.00
  Balance Due                                     ₹3,500.00
```

Now the math is obvious to read:
- Line totals on the right are what gets billed
- Subtitles tell you what's GST and what's base
- Subtotal + CGST + SGST = Grand Total (clean)
- Grand Total − Advance = Balance Due

---

## A note about inclusive vs exclusive

When a hotel staff member adds an extra, the **"Price includes GST"** checkbox on the Add Extra modal controls how the input is interpreted:

- **Unchecked (default)** = You're entering the **base/taxable** price. GST gets added on top.
  - Example: type ₹650 with 5% → final billed amount is ₹682.50
- **Checked** = You're entering the **final/gross** price (what the customer pays). GST is backed out.
  - Example: type ₹650 with 5% → final billed amount stays ₹650 (with ₹30.95 GST embedded)

Most Indian small-hotel menus already display gross prices ("dinner ₹650" means ₹650 with everything included), so checking this box matches the menu price directly. The current screenshot is consistent with the box being checked.

If you'd prefer **inclusive to be the default** for hotels (matches Indian menu convention), say the word and I'll flip the default in the next batch — small one-line change.

---

## Acceptance criteria

✅ No more "Extras GST +₹X" duplicate row
✅ No more "Total Tax" duplicate row
✅ Per-line subtitle shows incl./excl. clarity
✅ Subtotal + CGST + SGST = Grand Total reads cleanly
✅ Existing math stays identical — just rendered better

---

**Built by Claude · Batch 021.1 hotfix · 8 May 2026**
