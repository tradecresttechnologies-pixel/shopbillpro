# Batch 018.1 HOTFIX — Fix nav helpers on 5 admin pages

**Date:** 8 May 2026 · 4:10 AM IST

## What this fixes
My earlier sidebar-sync regex injected `goTo()` and `logout()` helper functions
inside a `<script src="...">` tag on these 5 pages, which is invalid HTML —
the browser ignores the body of script tags with `src` attributes, so the
functions were never defined. Result: clicking sidebar items did nothing.

## Files (5 admin pages, all corrected)
- admin-dashboard.html
- admin-features.html
- admin-technical.html
- admin-notifications.html
- admin-audit.html

## Deploy
Push these 5 files to your repo (overwrites previous versions). Vercel
auto-deploys. Hard-refresh admin → all 5 pages now have working sidebar nav.

## NOT THE CAUSE OF YOUR BLANK DASHBOARD
The blank dashboard you saw was caused by your sessionStorage holding a
stale admin password from before the password reset. To fix:
1. Click Logout in the admin sidebar
2. Log in with: `SBP_ADMIN_2024_SECURE`
3. Hard-refresh

After log-in-with-fresh-password + this hotfix deploy, both the dashboard
content AND the sidebar navigation will work correctly.
