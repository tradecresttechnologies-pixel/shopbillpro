# Batch Block 2 — Housekeeping + PSP-Polish

**Date:** May 5, 2026
**Scope:** Three small items — version-controlled migrations, admin password rotation, PSP URL hardcode
**Time:** ~10 minutes total

---

## What's in this batch

| # | Item | What it does |
|---|---|---|
| C1 | `db/migrations/` folder | Saves migration `008_public_shop_page.sql` to repo + adds README documenting the migration system going forward |
| C2 | `admin-auth.js` patch + `password-hasher.html` helper | Eliminates the public `SBP_ADMIN_2024_SECURE` backdoor password by replacing the public hash with a placeholder you fill in with your own |
| C3 | `settings.html` URL hardcode | Public Shop Page URL displayed to owners always says `https://app.shopbillpro.in/s/...` regardless of which Vercel deployment they accessed settings from |

---

## File list

```
ShopBillPro_Batch_Block2/
├── db/
│   └── migrations/
│       ├── README.md                ← migration system docs (commit to repo)
│       └── 008_public_shop_page.sql ← copy of migration we already deployed
├── admin-auth.js                    ← REPLACES existing (placeholder hash)
├── password-hasher.html             ← NEW (offline tool, optional but recommended)
├── settings.html                    ← REPLACES existing (URL hardcode)
└── BATCH_BLOCK2_DEPLOY.md           ← this file
```

---

## Deploy sequence

### Step 1 — Set up `db/migrations/` folder (~2 min)

In your local repo, create the folder structure if it doesn't exist:
```
db/
└── migrations/
```

Copy these two files from the batch into `db/migrations/`:
- `README.md`
- `008_public_shop_page.sql`

This is **version-control housekeeping** — no production deploy needed. Just commit + push.

If you have copies of the older migrations (`audit_round_db_patch.sql`, `admin_panel_full.sql`, `003_categories.sql`, `004_seo.sql`, `005_beta.sql`, `006_admin_hotfix.sql`, `007_pricing_fix.sql`) sitting on your machine, drop them into the same folder. The README explains which are missing and why — production database is already correct, this is just bookkeeping.

### Step 2 — Rotate admin master password (~5 min)

This is the security item — currently anyone who reads our design notes knows the master password is `SBP_ADMIN_2024_SECURE`. We need to change it.

**Step 2a: Generate your new password's hash**

Drop `password-hasher.html` into your repo root. Open it directly in any browser (Chrome/Edge/Firefox/Safari). The tool runs entirely offline — no network calls, no analytics. Even if you opened it without internet, it would still work.

You'll see a dark page with one input field. Type your new admin password (16+ characters recommended, mix of letters/numbers/symbols). Click **Compute SHA-256 Hash**. A green 64-character hex string appears. Click **📋 Copy hash**.

Examples of strong passwords:
- `SBP_xK9!mLp2qWnR8vTb`
- `Vinay_Master_2026_Q9pZ#`
- `TradeCrest!2026#yK7Lm`

Pick something you can remember. Don't reuse the old one.

**Step 2b: Replace the placeholder in `admin-auth.js`**

Drop the new `admin-auth.js` from this batch into your repo root (replacing the existing one). Open it in your text editor.

Find this line near the top (around line 32):
```javascript
MASTER_PASSWORD_HASH: 'PASTE_YOUR_64_CHAR_SHA256_HEX_HERE_________________________________',
```

Replace `PASTE_YOUR_64_CHAR_SHA256_HEX_HERE_________________________________` with the hash you copied from Step 2a. Save the file.

The line should now look like (your hash will differ):
```javascript
MASTER_PASSWORD_HASH: '4e8b3a9c1d2e5f7a6b4c8d9e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a',
```

**Step 2c: Update the DB token to match**

In Supabase SQL Editor, run (replace `YOUR_NEW_PASSWORD_HERE` with the actual password you typed in Step 2a — NOT the hash):

```sql
SELECT admin_set_master_token('YOUR_NEW_PASSWORD_HERE');
```

Expected result: `Success` or returns `1`.

This updates the DB-side token used by the `admin_verify_token` RPC. After this, both the frontend hash check AND the server check will recognize your new password.

**Step 2d: Test it**

DON'T commit yet. First test locally:

1. Open `https://app.shopbillpro.in/admin-login.html`
2. Try the OLD password `SBP_ADMIN_2024_SECURE` — should be rejected
3. Try YOUR NEW password — should log you in successfully

Wait — but you haven't deployed admin-auth.js yet. So the OLD frontend hash check still works. That's expected. The DB token has been updated, so the server check now requires your new password. Either path succeeds → login works.

For now, just **commit + push** admin-auth.js so the new frontend hash deploys. After Vercel deploys, both layers will require the new password.

### Step 3 — PSP-Polish (~1 min)

Replace your existing `settings.html` with the one in this batch. The change is small but important:

**Before:** Owner URL was built using `window.location.origin` — so if owner visited `shopbillpro-rho.vercel.app/settings.html`, they got URLs starting with `shopbillpro-rho.vercel.app/s/...` to share. Confusing brand.

**After:** Owner URL is hardcoded to `https://app.shopbillpro.in/s/...` regardless of which domain they accessed settings from. Brand-correct everywhere.

The change is just one constant + 4 reference updates inside the PSP JS block. No other settings.html behavior changed.

When we eventually point `shopbillpro.in` (root domain) to the marketing site and want shop URLs to use the cleaner root URL, just change one line — no hunting.

---

## Single commit + push

After all three items are in place:

```
git add .
git commit -m "Batch Block 2: housekeeping + PSP polish

- Save migration 008 to db/migrations/ + README documenting migration system
- Rotate admin master password (eliminate public SBP_ADMIN_2024_SECURE backdoor)
- Hardcode shop URL to app.shopbillpro.in/s/... in settings.html
"
git push
```

Or via GitHub Desktop, drop a similar commit message.

Vercel auto-deploys.

---

## After deploy — verification

### Verify C1 — migrations in repo

Look at your GitHub repo in the browser. You should see a new `db/migrations/` folder with `README.md` and `008_public_shop_page.sql` inside. That's it — no production impact.

### Verify C2 — password rotated

After Vercel finishes deploying:

1. Open `https://app.shopbillpro.in/admin-login.html`
2. Try the OLD password `SBP_ADMIN_2024_SECURE` — should fail with "Invalid password"
3. Try YOUR NEW password — should log you in
4. Once logged in, navigate around admin pages — should all work

If you ever need to rotate again, repeat Step 2 (a-d).

### Verify C3 — URL hardcoded

1. Open `https://app.shopbillpro.in/settings.html` — settings card shows URL `https://app.shopbillpro.in/s/viraj-enterprises` ✓
2. Open `https://shopbillpro-rho.vercel.app/settings.html` (the auxiliary deployment) — settings card should ALSO show `https://app.shopbillpro.in/s/viraj-enterprises` (NOT the rho URL)

That confirms the hardcode worked. The owner gets the brand-correct URL no matter where they opened settings from.

---

## What's NOT in this batch (intentionally parked)

- **Service worker bump** — SW currently returns empty content from CDN (Vercel cache glitch). When the empty-SW issue resolves naturally (or after the next service-worker.js commit), we'll bump to v1.5.12 in a tiny followup batch.
- **Open-source template curation for Phase 5** — per the locked decision, no designer engagement. Curation work happens just before Phase 5a launches (Month 4-5), not now.
- **Tutorial videos / placeholder image replacement** — your work, not blocked by code

---

## Rollback (if something goes wrong)

### Block 2-C2 rollback (locked out of admin)

If you accidentally locked yourself out of admin (typed wrong password or forgot the new one):

1. Go to Supabase SQL Editor
2. Run a known-good `admin_set_master_token('any_password_you_pick_now')` to override
3. In `admin-auth.js`, set `MASTER_PASSWORD_HASH` to the hash of that new password (use password-hasher.html)
4. Commit + push

The admin_set_master_token RPC is callable from SQL Editor (you're authenticated as `postgres` role there), so you can always recover via SQL even if the frontend is broken.

### Block 2-C3 rollback (URL hardcode breaks something)

If the hardcoded URL causes issues, edit `settings.html` line 2036 to change:
```javascript
const PUBLIC_SHOP_BASE_URL = 'https://app.shopbillpro.in';
```
back to:
```javascript
const PUBLIC_SHOP_BASE_URL = window.location.origin;
```

Or replace the file with the one from Batch PSP-MVP.

---

## Done?

After all three verifications pass, reply **"Block 2 done"** and I'll start Block 3 (Marketing site — 14 SEO landing pages, ~4-6 hours of work split into chunks).
