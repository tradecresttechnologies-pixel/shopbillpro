# ShopBill Pro — Batch 013: Customer History

**Date:** 6 May 2026
**Type:** New feature (closes universal "📋 History" gap)
**Risk:** Low — additive only (1 new RPC, 1 new page, 1 lib patch, 1 modal injection)
**Time to deploy:** ~3 min (SQL) + ~30 sec (Vercel auto-deploy)

---

## What this batch delivers

Closes the universal "📋 History SOON" gap that was blocking 4 Tier 1 verticals from reaching strict 100% completion. After deploy:

| Vertical | Before | After |
|----------|--------|-------|
| Kirana / retail | ~95% | **100%** |
| Healthcare | ~93% | **100%** |
| Education / coaching | ~93% | **100%** |
| Food / FMCG | ~98% | **100%** |
| Salon / Spa | ~90% | ~95% (Stylists still soon) |

History menu item flips from `📋 History SOON` to `📋 History NEW` across 12 retail/service profiles. Clicking it opens `customer-history.html` — a dedicated unified-timeline page with:

- **Picker mode** (no customer selected): search box + recent customers list (last 40 by activity)
- **Detail mode** (?customer_id=X): customer header, summary stats grid, filter chips (All / Bills / Appts / Loyalty), vertical timeline of every event

Also adds a **"📋 View Full Timeline →"** button to the existing customer detail modal in `customers.html` — so shopkeepers can drill into a customer's full timeline from the customer list, not just from the sidebar History link.

---

## Files in this batch (6 files)

| File | Action | Purpose |
|------|--------|---------|
| `db/migrations/013_customer_history.sql` | NEW | RPC `sbp_get_customer_timeline` + flip 12 profiles to active+NEW |
| `lib/sidebar-engine.js` | MODIFIED | Add href to `customer_history` module + remove from PENDING_PAGES |
| `customer-history.html` | NEW | Full timeline page (~620 lines, picker + detail modes) |
| `customers.html` | MODIFIED | Add "View Full Timeline" button to existing detail modal |
| `BATCH_013_DEPLOY.md` | NEW | This file |

---

## API design

**`sbp_get_customer_timeline(p_customer_id uuid) → jsonb`**

One RPC roundtrip returns everything the page needs:

```json
{
  "ok": true,
  "customer": { id, name, phone, whatsapp, email, address, customer_type, joined_at, gstin, ... },
  "stats": {
    "total_bills": 47,
    "voided_bills": 2,
    "total_spent": 12500.00,
    "total_paid": 11200.00,
    "balance_due": 1300.00,
    "first_bill_at": "2024-12-01T...",
    "last_bill_at": "2026-05-05T...",
    "avg_ticket": 265.96,
    "appointments_total": 12,
    "appointments_completed": 10,
    "appointments_cancelled": 2,
    "loyalty_balance": 320
  },
  "timeline": [
    { "type": "bill",        "at": "2026-05-05T...", "payload": {invoice_no, grand_total, status, items_summary, voided, ...} },
    { "type": "appointment", "at": "2026-05-04T...", "payload": {service_name, provider_name, starts_at, status, ...} },
    { "type": "loyalty",     "at": "2026-05-05T...", "payload": {txn_type, points, description, bill_id} },
    { "type": "registered",  "at": "2024-12-01T...", "payload": {name, customer_type} }
  ]
}
```

**Architecture per locked rule:**
- ✅ Logic in PLpgSQL not JS (single CTE-based aggregator)
- ✅ jsonb {ok, error?, ...} envelope with stable error codes
- ✅ Server-side validation (customer_id required, ownership via shops.owner_id)
- ✅ auth.uid() check + ON DELETE rules on FK
- ✅ Idempotent (read-only, no writes)
- ✅ No localStorage/DOM in logic

**Error codes returned:**
- `unauthorized` — auth.uid() is null
- `customer_id_required` — p_customer_id is null
- `customer_not_found_or_unauthorized` — customer doesn't exist OR isn't owned by caller's shop

**Performance notes:**
- Timeline capped at 500 events (most-recent-first) to prevent runaway responses on 5+ year shops
- Pagination can be added later via optional `p_before_at` arg (not needed for v1 — 500 events covers most use cases)
- Indexes already exist on `bills.customer_id`, `sbp_appointments.customer_id`, `sbp_loyalty_transactions(shop_id, customer_id, created_at DESC)` from earlier migrations

---

## Deploy steps

### Step 1 — SQL in Supabase SQL Editor

```sql
-- One file, idempotent, safe to re-run
\i db/migrations/013_customer_history.sql
```

Or paste the SQL into the editor manually. Completes in <2 sec.

### Step 2 — Verification queries (paste in SQL Editor)

```sql
-- (1) RPC exists and is callable by authenticated role
SELECT pg_get_functiondef(oid)
FROM pg_proc
WHERE proname = 'sbp_get_customer_timeline';
-- Expected: 1 row, function body matches migration

-- (2) Profile updates landed — should show 12 rows, all active+NEW
SELECT profile, status, badge FROM sbp_module_profiles
WHERE module_code = 'customer_history' ORDER BY profile;
-- Expected: salon, standard, kirana, garments, mobile, jewellery, pharmacy,
--           food, restaurant, healthcare, education, services
--           All status='active', badge='NEW'

-- (3) Smoke test the RPC against a real customer of yours
-- Find a customer with bills:
SELECT c.id, c.name, COUNT(b.id) as bills
FROM customers c
LEFT JOIN bills b ON b.customer_id = c.id
WHERE c.shop_id = (SELECT id FROM shops WHERE owner_id = auth.uid() LIMIT 1)
GROUP BY c.id, c.name
ORDER BY bills DESC
LIMIT 5;

-- Then call the RPC:
SELECT sbp_get_customer_timeline('<paste-customer-uuid-here>');
-- Expected: ok=true, customer={...}, stats={...}, timeline=[...]
```

### Step 3 — Push files to GitHub PWA repo

```
db/migrations/013_customer_history.sql       (new)
lib/sidebar-engine.js                         (modified)
customer-history.html                         (new)
customers.html                                (modified)
BATCH_013_DEPLOY.md                           (new)
```

Vercel auto-deploys ~30 sec after push.

---

## Smoke test checklist

### Sidebar nav
- [ ] On dashboard, sidebar shows "📋 History NEW" badge (was "SOON")
- [ ] Click "History" — navigates to `customer-history.html` (NOT a "Coming Soon" toast)

### Picker mode (entered from sidebar with no customer selected)
- [ ] Page loads with "Recent Customers" header
- [ ] Last 40 customers visible, sorted by recent activity
- [ ] Search box filters by name / phone / WhatsApp
- [ ] Click any customer → URL updates to `?customer_id=X` and timeline loads

### Detail mode (entered with ?customer_id=X)
- [ ] Customer header shows: avatar (initial-color), name, "Regular · Since [date] · phone"
- [ ] Stats grid populates with: Bills, Total Spent, Due/Clear, Last Visit (and Appts/Loyalty if non-zero)
- [ ] Filter chips show counts: All / Bills / Appointments / Loyalty
- [ ] Timeline renders with vertical line connector between events
- [ ] Bill events: tap → opens `bills.html?id=X`
- [ ] Voided bills shown with strikethrough + "VOIDED" red tag
- [ ] Appointment events: show service name, provider, date/time, status tag
- [ ] Loyalty events: show +/- points with green/red color, txn type label
- [ ] "Registered" event at the bottom (oldest) — synthetic from joined_at
- [ ] WhatsApp button → opens wa.me link
- [ ] New Bill button → navigates to billing.html with cust pre-filled

### Customer detail modal integration (customers.html)
- [ ] Open any customer in customers.html → modal appears as before
- [ ] New "📋 View Full Timeline →" button visible above WhatsApp/New Bill row
- [ ] Click it → navigates to customer-history.html?customer_id=X with that customer's timeline

### Sidebar styling (Batch 012 hotfix carry-over verification)
- [ ] On desktop, left sidebar visible at 220px wide
- [ ] On mobile, bottom nav appears with 5 items
- [ ] Bilingual text NOT concatenated ("Total" not "Totalकुल")

### Edge cases
- [ ] Open `customer-history.html?customer_id=BOGUS-UUID` → toast "Customer not found", redirects to customers.html
- [ ] Brand new customer with no bills/appointments — timeline shows ONLY the "🎉 Joined as customer" event
- [ ] Customer with only loyalty txns (no bills) — loyalty events render correctly
- [ ] Customer with very long history (50+ events) — page renders smoothly, all events visible

---

## Rollback plan

If anything breaks after deploy:

| Layer | Rollback |
|-------|----------|
| SQL — RPC | `DROP FUNCTION sbp_get_customer_timeline(uuid);` |
| SQL — Profiles | `UPDATE sbp_module_profiles SET status='soon', badge='SOON' WHERE module_code='customer_history';` (or `DELETE` non-salon rows) |
| Frontend | `git revert <commit>` and push |

Vercel keeps deploys for 7 days. No data is created, modified, or destroyed by this batch (RPC is read-only, profile rows are config). Rollback risk minimal.

---

## What's still pending after this batch

| Vertical | At 100%? | Remaining |
|----------|----------|-----------|
| Skilled services | 100% | nothing |
| Tea stall / minimal | 100% | nothing (by design) |
| Kirana / retail | **100%** | nothing |
| Food / FMCG | **100%** | (batch + expiry are post-100% depth) |
| Healthcare | **100%** | (patient depth is post-100%) |
| Education | **100%** | (student depth is post-100%) |
| Salon / Spa | ~95% | Stylists deeper feature (~6-8 hr batch) |

**Biggest remaining gap:** Stylists module for salon profile. After that's built, every Tier 1 vertical hits 100%.

Tier 2 + Tier 3 verticals continue per the Master Plan monthly roadmap (Pharmacy Month 3, Variants/IMEI Month 4, etc.).

---

*ShopBill Pro · TradeCrest Technologies Pvt. Ltd. · Batch 013 (6 May 2026)*
