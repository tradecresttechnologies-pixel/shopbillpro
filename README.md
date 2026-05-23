# ShopBill Pro v7.0 — Bill Split + Table Merge

## Deploy steps

### 1. Run SQL migration
`db/migrations/100_bill_split_merge.sql`

Creates 8 RPCs (3 split modes + merge + move-item + helpers) and adds
4 audit-lineage columns to `bills` (split_kind, split_index, split_total_ways,
split_session_id).

### 2. Replace running-order.html
Adds **Split Bill** and **Merge / Move** buttons to the action rail and
mobile bottom actions. Two modals with full handler logic.

### 3. Push via GitHub Desktop → Vercel auto-deploys

### 4. Hard-refresh and test
See `docs/DEPLOY_v7_bill_split_merge.md` for the 7-step test plan with
SQL reconciliation queries.

## What this delivers

**Bill Split (3 modes)** — each split becomes an independent bill with its
own invoice_no. Reconciles to the paise. Equal split / Custom amount / By-item.

**Table Merge / Move** — combine all items from one table into another
(source goes free), OR move selected items only (both stay open).

## Honest flags
- Items need `item_id` (sent to kitchen at least once) for by-item split + move-some
- Payment mode defaults to 'cash' — separate dropdown per split is v7.1
- Each split = own GST invoice (consumes invoice_no faster, audit-clean)
- See deploy guide for full flag list (8 items)

## Cumulative state
v5 (websites) + v6.x (reservations) + v7.0 (bill split/merge) — this session.
Next queued: SEO + auto-indexing.
