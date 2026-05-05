# CSS Path Hotfix

## What broke

After Root Directory was changed to `site`, the marketing pages stopped loading their stylesheet — making the page render as plain unstyled HTML with both English and Hindi text visible at once.

## Why

The 14 marketing HTML files referenced CSS as `/site/css/marketing.css`. That path worked when Root Directory was `./` (repo root). With Root Directory now `site`, the deployment treats `/site/` as root, so the CSS file is actually served at `/css/marketing.css` (without the `/site/` prefix). The OLD path now 404s.

## Fix

Single change applied to all 14 marketing HTML files:
```
/site/css/marketing.css  →  /css/marketing.css
```

## Files in this zip (14 HTML files)

```
site/
├── index.html
├── pricing.html
├── faq.html
├── why-choose-shopbill-pro.html
├── free-billing-software-india.html
├── features/
│   ├── gst-billing.html
│   ├── inventory-stock.html
│   ├── pos-billing.html
│   └── whatsapp-bills.html
└── for/
    ├── education.html
    ├── healthcare.html
    ├── restaurants.html
    ├── retail.html
    └── services.html
```

## Deploy

1. Drop the `site/` folder over your existing `/site/` folder in the repo (overwrites the 14 HTML files)
2. Commit + push to `main`
3. Marketing project auto-deploys
4. Wait 5–10 min for edge cache
5. Test `https://shopbillpro.in/` in incognito → should show fully styled marketing page (light theme, orange, English-only or Hindi-only depending on toggle)

No Vercel UI changes needed. Root Directory stays `site`. This is a pure HTML content fix.

## Why this happens generally

Absolute paths starting with `/site/...` are coupled to "the deployment serves from repo root". When you change Root Directory, those paths break because they no longer match the new file layout in the deployment.

For future-proofing, marketing HTML should reference assets relative to the marketing root, not relative to the repo root. This batch makes them match the new Root Directory setup.
