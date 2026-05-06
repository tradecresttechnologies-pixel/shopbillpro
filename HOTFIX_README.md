# ShopBill Pro — Batch 012 Hotfix (Sidebar CSS)

**Date:** 6 May 2026, post-Batch 012 deploy
**Type:** CSS-only hotfix — no SQL, no JS logic changes
**Affects:** 2 files (services.html, appointments.html)
**Risk:** Very low — additive CSS only

---

## What this fixes

After Batch 012 deployed, you reported the sidebar was rendering as plain unstyled text at the top of services.html and appointments.html (visible in your screenshots).

**Root cause:** The `.dsb-*` (desktop sidebar) and `.bnav-*` (mobile drawer) CSS rules live **inline** in every page that uses the sidebar (dashboard.html, billing.html, bills.html, etc.) — there's no shared stylesheet. When I built services.html and appointments.html in earlier batches, I included all the page-specific CSS inline but **never copied over the global sidebar/bnav CSS block** from dashboard.html.

When `SBPSidebar.render()` ran in Batch 012, it generated the correct HTML with classes like `.dsb-logo`, `.dsb-nav`, `.dsb-item`, etc. But the browser had no CSS for those classes — so they fell back to default browser styling: plain blue underlined text at the top of the page.

**What this hotfix does:**
- Imports the full sidebar+bnav CSS block (~185 lines, ~7KB) from dashboard.html into both services.html and appointments.html
- Adds a small layout shim — services/appointments use block layout (not dashboard's flex-column), so I restore `position:fixed` for the mobile `.bnav` so it stays anchored to the bottom of the viewport on mobile

## What stays exactly the same

- All Batch 012 SQL fixes (row_to_jsonb → to_jsonb) — UNTOUCHED, already deployed
- All Batch 012 JS changes (PENDING_PAGES, render() calls) — UNTOUCHED
- Settings.html, s.html, sidebar-engine.js — UNTOUCHED
- Everything else — UNTOUCHED

## Files in this hotfix

| File | Action | Change |
|------|--------|--------|
| services.html | MODIFIED | +200 lines CSS (sidebar + bnav + drawer + responsive) |
| appointments.html | MODIFIED | Same +200 lines CSS |

## Deploy

Just push the 2 files to the GitHub PWA repo. Vercel auto-deploys ~30 sec.

```
services.html
appointments.html
```

No SQL, no DB changes, no other files needed.

## After deploy — verify

Reload services.html and appointments.html (Ctrl-Shift-R for hard refresh):

- [ ] Left sidebar (220px wide) appears on desktop, with vertical menu items
- [ ] Sidebar shows the right items per your shop_type (Services NEW, Appointments NEW, Stylists SOON, Loyalty NEW for retail profiles, etc.)
- [ ] Active item (Services or Appointments) is highlighted in orange
- [ ] On mobile (resize browser <1024px), sidebar disappears and `.bnav` bottom nav appears
- [ ] Tap "More" in mobile bnav → drawer slides in from the right with full menu
- [ ] Page content shifts right by 220px on desktop (no overlap with sidebar)

## Why this wasn't caught in Batch 012 testing

Honest postmortem:
- I validated JS syntax (Node --check passed)
- I validated SQL structure (balanced $$ delimiters)
- I did NOT visually render the pages with the sidebar engine to verify CSS coverage

For future batches I should add a CSS class audit: when SBPSidebar.render() is called, check that the page has CSS for the classes it generates (`.dsb-nav`, `.dsb-item`, `.bnav-drawer`, etc.). If missing, flag before shipping.

A better long-term fix: refactor the inline sidebar CSS into `lib/sidebar.css` and have every sidebar-using page load it. That way there's no copy-paste tax when adding a new page. Filed in tech debt.
