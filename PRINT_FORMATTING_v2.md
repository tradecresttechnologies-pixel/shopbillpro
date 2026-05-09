# Hotfix v2 — Compliance Print Formatting

**Issue (your screenshot):** Print preview rendered without sidebar/topbar
(good), but the table itself looked unprofessional:
- Columns unevenly sized — empty `—` columns hogging width, important
  columns squeezed
- Long values wrapping awkwardly mid-word
- Status pill wrapping like text
- Title weak (small underlined)
- Metadata row cramped
- Plus browser-injected headers/footers ("5/9/26, 10:56 AM" and the URL)

**Fixes:**

1. **Explicit column widths via `<colgroup>`**
   - Form B: 14 columns proportioned by importance (`Sl 2.8% / Arrival 7.5%
     / Name 11% / Father 8.5% / Address 9% / Nationality 6% / ID Proof 11%
     / Status 6%` etc., sums to 100%)
   - Form C: 24 columns at smaller font, narrow proportions
   - `table-layout: fixed` so widths are honored, not auto-sized

2. **Stronger title block**
   - Inverted black-on-white: white text on solid black background
   - Inline-block, centered in its own `.ph-title-wrap`
   - 13pt, weight 900, 1.5px letter-spacing
   - Reads like an official register heading, not a webpage

3. **Letterhead refinement**
   - Shop name: 18pt Outfit weight 900
   - Address line: 9pt secondary
   - Metadata row: Period / Total Records / Generated all bold-strong
   - 2.5pt black border separator (heavier than before)

4. **Cell typography rebuilt**
   - Headers: 7.5pt uppercase, weight 800, light-grey background, centered
   - Body cells: 8.5pt with `word-break: break-word; overflow-wrap: anywhere`
     so long ID numbers wrap cleanly
   - Numeric values (Sl, room, phone): JetBrains Mono for register feel
   - Guest name: 9pt Outfit weight 800
   - Foreign badge: black inverted, tight padding
   - Status pill: tight uppercase tag with hairline border, no rounded pill,
     `white-space: nowrap` so "CHECKED_OUT" doesn't wrap

5. **Page-break safety**
   - `tr { page-break-inside: avoid }` so a row never splits mid-line
   - `thead { display: table-header-group }` so column headers repeat
     on each page automatically
   - `.print-sig { page-break-inside: avoid }` so the signature block
     stays together

6. **Tighter A4 margins** (10mm vertical / 8mm horizontal vs prior 14×12)
   — gives the table ~7% more usable width, which absorbed into wider
   columns for human-readable text.

7. **Light zebra-striping** on alternating rows (#fafafa) for readability
   without making it look web-y.

---

## ABOUT THE BROWSER HEADER/FOOTER

The "5/9/26, 10:56 AM" at the top and the URL at the bottom of your
screenshot are **browser print chrome**, not from my CSS. CSS cannot
suppress them on Chrome.

**Two ways to hide them:**

(a) **In the print dialog** — click "More settings" → uncheck
"Headers and footers". Chrome remembers this for next print.

(b) **Save as PDF first** — in the print dialog change Destination to
"Save as PDF" → save → open the PDF → print the PDF. PDFs don't
carry browser headers/footers.

I've documented this in the BATCH 028A print-audit batch (next session)
so we standardize the workflow across the app.

---

## Files in this hotfix (1)

```
compliance.html       ← drop-in replace
```

## Deploy

GitHub Desktop → replace this file → push → hard-refresh.

## What you should see now when clicking Print

- Letterhead: large shop name + address line + 3-column metadata row
- Centered black title bar: HOTEL GUEST REGISTER · FORM B
- Table fills full landscape width with proportioned columns
- Repeating column headers on each page if it spills to page 2+
- Zebra-stripped rows
- Status as compact uppercase tag with hairline border
- Signature block at bottom: Manager / Owner / Date+Stamp
- 8.5pt body / 9pt name / 7.5pt headers — all readable on paper
