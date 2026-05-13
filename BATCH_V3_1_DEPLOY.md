# Batch v3.1 — Admin Sidebar Consistency Hotfix

Adds the **🌐 Websites** menu item to all 14 admin pages' sidebars so the link
appears no matter which admin page you're on. Pure copy-paste hotfix — no SQL,
no logic changes, just one inserted line per file.

## DEPLOY PATHS — REPLACE all 14 in repo root

```
REPLACE  admin-analytics.html
REPLACE  admin-audit.html
REPLACE  admin-blog.html
REPLACE  admin-categories.html
REPLACE  admin-company-details.html
REPLACE  admin-features.html
REPLACE  admin-notifications.html
REPLACE  admin-revenue.html
REPLACE  admin-seo-global.html
REPLACE  admin-seo-pages.html
REPLACE  admin-settings.html
REPLACE  admin-subscriptions.html
REPLACE  admin-technical.html
REPLACE  admin-users.html
```

`admin-dashboard.html` and `admin-websites.html` already have the link
from Batch v3 — no changes here.

## What changed in each file

Exactly one line inserted right after the **Users** nav-item, before **Revenue**:

```html
<div class="nav-item" onclick="goTo('admin-websites.html')"><span>🌐</span><span>Websites</span></div>
```

## Deploy

1. Copy all 14 files into your repo root (overwrite existing)
2. Commit + push → Vercel auto-deploys ~30 sec
3. Hard-refresh browser (Ctrl+Shift+R) on any admin page
4. Verify: click around — every admin page sidebar now shows 🌐 Websites
   between Users and Revenue

That's it. No SQL, no edge function changes.

## Verify

After deploy, click through each admin page in the sidebar. On every one,
the "Main" section should show:
- Dashboard
- Subscriptions
- Users
- 🌐 Websites      ← new on every page
- Revenue
- Analytics
