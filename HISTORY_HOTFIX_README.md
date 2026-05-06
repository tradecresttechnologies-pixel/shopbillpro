# Customer History — Detail mode hotfix (6 May 2026)

**Triggered by:** Vinay's screenshots showing broken empty detail page + "Could not load timeline" toast after tapping a customer (Jyoti / Vinay) in the picker.

---

## Root cause

**Two issues stacked:**

1. **Real cause:** The `sbp_get_customer_timeline` RPC is failing in your prod Supabase. The most likely reason is **migration 013_customer_history.sql hasn't been deployed** to your Supabase yet. The picker still works because it queries the `customers` table directly (different code path).

2. **UI bug I introduced:** When the RPC failed, the page would still display the detail mode — but `renderDetail()` was inside the try block, so it never ran. Result: empty broken page with avatar showing dashes and an error toast. Should have either bounced back or rendered with whatever data was available.

---

## What this hotfix does

**1 file modified:** `customer-history.html`

The `loadDetail()` function now:

```
1. Try RPC sbp_get_customer_timeline (normal path)
2. If RPC fails:
     a. If "customer not found" / "unauthorized" → bounce back to customers.html
     b. Otherwise → fall back: fetch customer from `customers` table directly
        - Detect "function does not exist" pattern → show diagnostic message
          telling you migration 013 needs deployment
        - Render with: customer header populated, empty stats, empty timeline
3. Always call renderDetail() before showing the page (never empty broken state)
4. If even the fallback fetch fails → bounce back, don't show broken UI
```

After this hotfix, even if migration 013 isn't deployed, the page will:
- Show the customer header (name, avatar, type, phone) properly
- Show empty stats grid
- Show "📭 No activity yet" empty timeline state
- Display info toast: *"Timeline feature needs migration 013 deployed in Supabase. Showing basic info only."*

Once you deploy migration 013, the timeline will populate normally.

---

## How to deploy

### Option A — If you DON'T want History feature at all right now

Just disable the sidebar entry. Open `lib/sidebar-engine.js` and remove the line:

```js
'customer_history': { href: 'customer-history.html', icon: '📋', ... }
```

(Or set `status: 'soon'` in module profiles via SQL.)

### Option B — If you DO want History (recommended)

**Step 1:** Verify migration 013 is deployed in Supabase:

```sql
SELECT proname FROM pg_proc WHERE proname = 'sbp_get_customer_timeline';
-- Should return 1 row. If 0 rows → run 013_customer_history.sql
```

If 0 rows, deploy `db/migrations/013_customer_history.sql` from the original Batch 013 zip.

**Step 2:** Push this hotfix (1 file):
```
customer-history.html   (modified — graceful fallback)
```

Vercel auto-deploys ~30 sec.

**Step 3:** Hard-refresh, tap Jyoti or Vinay → should now show:
- If 013 deployed: full timeline with bills, appointments, loyalty events
- If 013 NOT deployed: customer header + "No activity yet" + diagnostic toast

---

## My honest take

I should have built the fallback in originally. The RPC-fails-silently → empty-broken-page pattern is a recurring class of bug in this codebase (similar root cause as the Batch 013 customers loading bug from this morning). I'm baking the same fallback pattern into all new pages going forward: every page that depends on a custom RPC should have a degraded-mode that uses direct table queries when the RPC fails.

Two options ahead of you:
1. **Deploy migration 013 + this hotfix** → History works as designed
2. **Skip History entirely for now** → remove from sidebar, ship later

If you want option 2, say the word and I'll generate a one-line patch to hide it.

---

*Batch 013 follow-up hotfix · 6 May 2026*
