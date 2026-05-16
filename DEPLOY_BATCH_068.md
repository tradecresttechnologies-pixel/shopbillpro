# Batch 068 — QR Guest Ordering

In-restaurant QR ordering: guest scans → views menu → places order on phone → staff confirms on running-order page → KOT auto-fires to kitchen.

## DEPLOY PATHS

```
NEW       db/migrations/068_qr_guest_orders.sql
NEW       qr-menu.html
REPLACE   running-order.html     ← realtime banner + guest review modal
REPLACE   tables.html            ← QR URL pattern updated to /qr/{slug}/{num}
REPLACE   vercel.json            ← adds /qr/:slug/:table rewrite
```

## Deploy order (CRITICAL)

### 1. SQL — run in Supabase SQL Editor FIRST

```
db/migrations/068_qr_guest_orders.sql
```

**Verify with:**
```sql
-- Should return 0 (table empty)
SELECT count(*) FROM sbp_guest_orders;

-- Should return 6 RPCs
SELECT routine_name FROM information_schema.routines
 WHERE routine_schema='public' AND routine_name LIKE 'sbp_guest_%';

-- Realtime publication contains the new table
SELECT tablename FROM pg_publication_tables
 WHERE pubname='supabase_realtime' AND tablename='sbp_guest_orders';
```

### 2. Push to GitHub → Vercel auto-deploys
- running-order.html
- tables.html
- qr-menu.html
- vercel.json

## Test flow

1. **Set up shop slug** — make sure `sbp_shop_websites.slug` is set for your shop. Without a slug the QR URLs won't work.
2. **Add at least one menu item** via Menu → Services (Pro/Business plan required to view, Business required for QR).
3. **Open a table** in tables.html → tap T10 → opens running-order, status becomes `occupied`.
4. **Print the QR for T10** — go to Tables → 📱 Table QR Codes tab → tap "Print" on T10.
5. **On your phone, scan the QR** — should land on the QR menu page.
6. **Add items + per-item notes** → tap "View Order" floating button.
7. **Optionally add name + phone** → tap "Send Order to Staff".
8. **Switch back to running-order.html on the staff side** — orange banner appears within ~1s: "1 guest request waiting · Tap to review".
9. **Tap the banner** — modal opens with guest's items, notes, optional contact info.
10. **Tap "Accept & Send KOT"** — KOT fires to kitchen, banner clears, items appear in the running order.
11. **Back on the guest phone** — status updates to "✓ Sent to kitchen · KOT #002".

## Plan gating

QR ordering is **Business-only** (or 60-day trial). The plan check (`_sbp_shop_has_qr_access`) is in:
- `sbp_guest_menu_get_public` — returns `qr_enabled:false` for non-Business shops; page shows "QR ordering is being set up" notice.
- `sbp_guest_order_place` — returns `error:'plan_required'` if non-Business tries to place.

Once Plan Gate Audit batch runs (after restaurant vertical complete), the "Print QR Codes" button on tables.html will also be hidden for non-Business shops.

## Three actions when reviewing a guest order

- **✅ Accept & Send KOT** — adds items as new KOT round, fires print/kitchen display
- **✏️ Modify** — loads items into current-round builder for staff editing, marks guest order as handled
- **❌ Send Waiter** — opens reason picker (4 presets + custom), marks guest order rejected. Guest's screen shows "Staff wants to chat" with the reason.

## Anti-abuse safeguards built in

- **Plan gate** — non-Business can't use it
- **Table state gate** — only `occupied`/`reserved` tables accept orders. Free tables show "wait for staff to seat you."
- **Server-side price refetch** — anon client sends only `service_id + qty + notes`. Server looks up real price + GST from `sbp_services`. No way to underpay.
- **Service validation** — every `service_id` must belong to the requesting shop and be `active`. No cross-shop item injection.
- **Custom items rejected** — anon can only order from the menu; can't add free-text "item" rows.
- **Anti-spam unique index** — one pending order per (shop, table) at a time. Partial unique index on `status='pending'` enforces it atomically.
- **Item cap** — max 50 distinct items per order. Anti-DOS.
- **Qty bounds** — 1 ≤ qty ≤ 99.

## Known limitations / deferred to later batches

- "Modify" path uses a reject-with-reason internally (no dedicated "modified" status yet). The audit trail is clean (reason says "Staff loaded items into round for editing") but a dedicated status would be nicer.
- No notification system for "Send Waiter" action beyond the guest's status screen update — a future batch could ping a staff member's device.
- Guest can't track KOT cooking progress (preparing → ready → served) — would need KDS broadcast back to guest. Phase 2.
- Multi-language menu is EN/HI only via existing lang spans. Regional languages are post-launch.
- No UPI payment from QR menu — that's the Phase 2 UPI batch already in pending.

## Migration sequence now up to 068.
