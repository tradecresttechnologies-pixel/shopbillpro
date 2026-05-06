# Customer History — Hotfix v2 (6 May 2026, 2nd pass)

**Triggered by:** Vinay's screenshots showing "Could not load customer" toast → bounce to customers.html when tapping any customer in the History picker. v1 hotfix didn't help because v1 had bugs in the fallback path itself.

---

## Why v1 didn't fix it

I made two mistakes in the v1 fallback:

```js
// v1 BUG 1: explicit column list
.select('id,name,phone,whatsapp,customer_type,joined_at,email,
        address,balance,credit_limit,gstin,city')
//                       ↑ if ANY of these columns doesn't exist on
//                         your customers table, the WHOLE query errors

// v1 BUG 2: .single() throws on 0 rows
.single()
//                       ↑ should be .maybeSingle() which returns null
```

So v1's "RPC fails → fall back" path itself was broken on certain shop schemas. You hit the bounce-to-customers.html because the fallback errored too.

---

## v2 fix — three-tier bulletproof load

```
async function loadDetail(){
  ┌─ Tier 1: sbp_get_customer_timeline RPC          (full timeline)
  │    └─ if works: render full page with stats + activity
  │
  ├─ Tier 2: SELECT * FROM customers (maybeSingle)  (Supabase basic info)
  │    └─ if works: render header + empty timeline + "migration needed" toast
  │
  ├─ Tier 3: localStorage sbp_customers cache       (offline fallback)
  │    └─ if works: render header + empty timeline + "offline data" toast
  │
  └─ Bounce: only if all three tiers fail
       └─ "Could not load customer" → customers.html
}
```

**Key changes vs v1:**
- `select('*')` instead of explicit column list → tolerates any schema
- `.maybeSingle()` instead of `.single()` → no error on 0 rows
- New Tier 3: localStorage cache lookup → handles offline-created customers
- Verbose console logging at every layer → easy to diagnose if it still fails

---

## Deploy (1 file, ~30 sec)

```
1. Push to GitHub PWA repo:
     customer-history.html     (this file)

2. Vercel auto-deploys ~30 sec

3. Hard-refresh phone, tap Jyoti or Vinay in History picker
```

**No SQL changes** in this hotfix — it's pure client-side resilience.

---

## What you'll see now (3 cases)

### Case A — Migration 013 IS deployed (the ideal state)
- Click customer → full timeline appears with bills, appointments, loyalty events
- No diagnostic toast (everything works as designed)

### Case B — Migration 013 NOT deployed (likely your current state)
- Click customer → header + avatar + name + phone all populate correctly
- Stats grid shows zeros (expected — RPC didn't run)
- Timeline shows "📭 No activity yet" empty state
- Info toast: *"Activity timeline needs migration 013. Basic info shown."*
- **Page is usable** — at least you can see who the customer is + WhatsApp them + create new bill

### Case C — Customer only exists offline
- Click customer → header + name + phone show from localStorage
- Info toast: *"Showing offline data. Sync customer to see full activity."*

---

## If it STILL fails after v2

That would mean:
1. The customer ID in URL doesn't match anything in Supabase OR localStorage
2. OR there's a deeper issue (network, auth)

In that case:
1. Open Chrome DevTools (F12) on desktop, OR `chrome://inspect` from a desktop browser to inspect your phone
2. Tap a customer in History picker
3. Look at Console tab — you'll see logs like:
   ```
   [CustomerHistory] Tier 1 RPC failed: function sbp_get_customer_timeline does not exist
   [CustomerHistory] Tier 2 returned null — customer ID not in Supabase
   [CustomerHistory] Tier 3: customer ID not in localStorage either
   [CustomerHistory] All three lookup tiers failed. Last error: ...
   ```
4. Send me the console output and I'll diagnose

---

## Recommended: deploy migration 013 too

The above fix makes the page **work** without 013 (Case B), but you only get the FULL experience (Case A) if migration 013 is in your Supabase. From the original Batch 013 zip:

```
db/migrations/013_customer_history.sql
```

If you want to skip 013 forever and never have a real timeline, that's also fine — Case B is functional, just less rich.

---

*Customer History bulletproofing — v2 hotfix · 6 May 2026*
