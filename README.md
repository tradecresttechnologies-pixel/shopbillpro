# ShopBill Pro — Free Tools Hub + Barcode Designer

Adds a **Software & Tools** section to the marketing site, the first free tool
(**Barcode Designer**), and wires it into the homepage. All pages match the existing
marketing design system (orange light theme, Outfit/Inter, EN/HI toggle).

Everything lives under `/site/` (the marketing Vercel project, root dir = `site/`).
No app, Supabase, or backend changes. 100% client-side; no new dependencies on your
servers (the tool loads bwip-js + jsPDF + html2canvas from public CDNs).

---

## DEPLOY PATHS

| File in this bundle | Repo destination | Action |
|---|---|---|
| `site/tools/barcode-designer.html` | `site/tools/barcode-designer.html` | **NEW** |
| `site/tools/index.html` | `site/tools/index.html` | **NEW** |
| `site/index.html` | `site/index.html` | **REPLACE** |
| `site/sitemap.xml` | `site/sitemap.xml` | **REPLACE** |

> `site/tools/` is a new folder — create it. With `cleanUrls:true` the pages serve at
> `shopbillpro.in/tools` and `shopbillpro.in/tools/barcode-designer`.

---

## WHAT CHANGED

**NEW — `site/tools/barcode-designer.html`** (the tool + its landing page in one)
- Universal engine (bwip-js): 18 symbologies grouped by sector.
- Label designer: Barcode-only, Price tag, Product label, Shipping — editable fields + logo.
- Print formats: A4 sticker sheets (65/24/21/10-up), thermal label rolls
  (50×25 / 40×30 / 38×25 / 75×50 / 100×50 / 100×150mm + custom), 80/58mm receipt, custom mm.
- Exports: exact-size PDF, direct Print, PNG, copy-to-clipboard, SVG (vector barcode).
- Batch mode + auto sequential numbering + copies-per-label.
- How-to section + FAQ accordion + SoftwareApplication & FAQPage JSON-LD schema.
- EN/HI via `sbp_marketing_lang`.

**NEW — `site/tools/index.html`** (the hub)
- Full site nav / drawer / footer.
- Data-driven card catalog (`CATALOG` array — add a tool = add one entry).
- Filters: All / Software / Tools / Free.
- Lists ShopBill Pro (software) + Barcode Designer (live) + 3 "coming soon" tools.

**REPLACE — `site/index.html`** (homepage)
- "Free Tools" added to top nav + mobile drawer + footer Product column.
- New "Free tools — no signup" section (3 cards + "See all tools" button) before How-It-Works.

**REPLACE — `site/sitemap.xml`**
- Added `/tools` (priority 0.9) and `/tools/barcode-designer` (0.85).

---

## TEST PLAN (after deploy — allow ~10 min for Vercel edge cache)

1. `shopbillpro.in` → nav shows **Free Tools**; new tools section renders; "See all tools" works.
2. `shopbillpro.in/tools` → hub loads, filters work, cards correct, EN/HI toggles.
3. `shopbillpro.in/tools/barcode-designer`:
   - EAN-13 → Price tag → A4 sheet → **Print** → PDF opens with a sticker grid.
   - QR → Product label → 50×25mm label → **PDF** → one exact-size label per page.
   - Batch mode → paste 3 codes → preview badge shows "3 labels" → PDF has all 3.
   - PNG, SVG, Copy buttons work; FAQ accordion opens/closes.
4. View source on the tool page → confirm both JSON-LD blocks present.
5. Submit updated `sitemap.xml` in Google Search Console + Bing Webmaster Tools.

## NOTES
- Stray empty folder `site/{features,for,css,images}` (old shell artifact) can be deleted anytime — unrelated.
- Next tools (GST Calculator, Invoice Maker, QR Maker) just need a new file in `site/tools/`
  + one entry in the hub `CATALOG` array.
