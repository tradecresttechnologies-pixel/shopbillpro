# ShopBill Pro — Root Directory Split (Simplified)

## What this batch does

1. **Marketing project** (`shopbillpro.in`) and **App project** (`app.shopbillpro.in`) get split at the file-system level using Vercel's "Root Directory" setting. No more PWA file leaks, no more rewrite gymnastics.

2. **No automatic redirects from marketing-domain to app-domain.** Users navigate via the existing "Sign in" / "Get started" buttons in the marketing nav. Clean, standard SaaS pattern (Shopify / Razorpay / Notion all do exactly this).

## What's in this zip

| File | Goes to | Action |
|---|---|---|
| `vercel.json` | `/vercel.json` (repo root) | REPLACE existing |
| `site/vercel.json` | `/site/vercel.json` | NEW |
| `site/icons/*` (10 PNGs) | `/site/icons/` | NEW (copies of `/icons/*`) |

The repo-root `/icons/` folder stays — the PWA still uses it.

## Why /vercel.json has login/signup redirects

The marketing site's "Sign in" / "Get started" buttons currently link to:
- `https://app.shopbillpro.in/login.html`
- `https://app.shopbillpro.in/signup.html`

But your PWA login is at `/index.html` (no `/login.html` or `/signup.html` file exists). Without these redirects, the buttons would 404. The redirects make them work transparently:
- `/login` → `/`
- `/signup` → `/`

Vercel's `cleanUrls` strips `.html` first, so `/login.html` becomes `/login`, then redirects to `/`.

## Why /site/vercel.json is so small

After Root Directory = `site`, the marketing project only contains marketing files. Nothing to redirect except `www → bare domain` for SEO canonicalization.

## Deploy steps

### 1. Drop files into repo

Replace `/vercel.json` with the new one. Add `/site/vercel.json` and `/site/icons/`.

### 2. Commit + push to `main`

### 3. Vercel UI — set Root Directory on MARKETING project (CRITICAL STEP)

1. Vercel Dashboard → **shopbillpro** project (the rho one)
2. **Settings** → **Build & Deployment**
3. **Root Directory** → enter exactly: `site` → Save

Do NOT touch Root Directory on the app project.

### 4. Force redeploy without cache (both projects)

Deployments → latest → ⋯ → Redeploy → uncheck "Use existing Build Cache".

### 5. Wait 10–15 min, then verify in incognito

## Verification

| URL | Expected |
|---|---|
| `https://shopbillpro.in/` | Marketing home |
| `https://shopbillpro.in/pricing` | Marketing pricing |
| `https://shopbillpro.in/faq` | Marketing FAQ |
| `https://shopbillpro.in/for/retail` | Retail landing |
| `https://shopbillpro.in/features/gst-billing` | GST feature page |
| `https://www.shopbillpro.in/` | 301 → `https://shopbillpro.in/` |
| `https://shopbillpro.in/dashboard` | **404** (intentional — users use the "Sign in" button) |
| Click "Sign in" on marketing nav | → `app.shopbillpro.in/` (PWA login) |
| Click "Get started — Free" on nav | → `app.shopbillpro.in/` (PWA login) |
| `https://app.shopbillpro.in/` | PWA login |
| `https://app.shopbillpro.in/dashboard` | PWA dashboard |
| `https://app.shopbillpro.in/login` | Redirects to `/` (PWA login) |
| `https://app.shopbillpro.in/signup` | Redirects to `/` (PWA login) |

## Final clean architecture

```
shopbillpro.in/                    → marketing home
shopbillpro.in/pricing             → marketing pricing
shopbillpro.in/faq                 → marketing FAQ
shopbillpro.in/for/<vertical>      → vertical landing
shopbillpro.in/features/<feature>  → feature page
shopbillpro.in/<anything-else>     → 404

app.shopbillpro.in/                → PWA login
app.shopbillpro.in/dashboard       → PWA dashboard
app.shopbillpro.in/admin-login     → admin panel
app.shopbillpro.in/s/<slug>        → public shop page
```

## Rollback if needed

Vercel UI → marketing project → Settings → Root Directory → clear field → Save. Both projects redeploy in their old state.
