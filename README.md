# ShopBill Pro — Add "Free Tools" to nav on ALL marketing pages

## WHY
The site isn't templated — each marketing page has its own copy of the nav, drawer,
and footer. The first batch only added "Free Tools" to the homepage, so every other
page still showed the old menu. This batch adds it everywhere.

## WHAT CHANGED (each file)
- Top nav: added **Free Tools** (`/tools`) between "For Business" and "Pricing".
- Mobile drawer: same link (skipped on the 3 legal pages, which have no drawer).
- Footer "Product" column: added **Barcode Designer** + **All Free Tools** links.
No other markup, styles, or scripts touched. Active-link highlighting per page preserved.

## DEPLOY PATHS — all 20 are REPLACE

```
site/faq.html
site/free-billing-software-india.html
site/pricing.html
site/privacy.html
site/refund.html
site/terms.html
site/why-choose-shopbill-pro.html
site/features/gst-billing.html
site/features/inventory-stock.html
site/features/pos-billing.html
site/features/whatsapp-bills.html
site/for/education.html
site/for/healthcare.html
site/for/hospitality.html
site/for/online-brand.html
site/for/restaurants.html
site/for/retail.html
site/for/salon-wellness.html
site/for/services.html
site/for/wholesale.html
```

> `site/index.html` is NOT here — it already has the link from the previous deploy.

## TEST AFTER DEPLOY
Open any inner page (e.g. `/pricing`, `/faq`, `/for/retail`) → top nav now shows
**Free Tools** → clicking it opens `/tools`. Check the mobile menu (☰) too.

## NOTE — long-term
Because the nav is duplicated across ~21 files, every future nav change means editing
all of them. When you have time, worth extracting the header/footer into a shared
include (or a tiny JS injector) so it's edited once. Not urgent — flagging for later.
