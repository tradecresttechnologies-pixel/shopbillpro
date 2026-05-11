# Hotfix 022C — Two fixes

## Bug 1: Finalize fails with "column e.gst_amount does not exist"

**Your error:** `Could not finalize: column e.gst_amount does not exist`

**Root cause:** I assumed `sbp_booking_extras` had a single `gst_amount`
column. The actual schema (from migration 022) splits GST into
**cgst_amount + sgst_amount** for proper IGST/CGST/SGST reporting. My
migration 030 referenced the non-existent combined column.

Also referenced `e.unit` which doesn't exist on `sbp_booking_extras`
(it's only on `bill_items`).

**Fix:** new migration `030a_finalize_column_fix.sql` replaces the RPC
with corrected column references:

- **Combined GST per extra** = `COALESCE(cgst_amount, 0) + COALESCE(sgst_amount, 0)`
- **Fallback for legacy rows** (where 022's GST columns are still 0):
  derive from `gst_rate × taxable_amount`, then from category-based
  defaults as last resort (food/transport=5%, others=18%)
- Removed `e.unit` references — that column only exists on bill_items
  (which we still write to correctly)

Idempotent. Just DROP + CREATE the function. No data migration needed.

## Bug 2: bookings.html still showed old "Add Extra Charge" + "Check Out & Generate Bill" buttons (Image 3)

After 022C, folio.html owns both flows. Those buttons in the bookings
modal were redundant and confusing — operator could go either through
folio or through the legacy modal, creating two parallel UX paths.

**Fix:** removed those two buttons. The bookings modal now shows:

| Status | Buttons |
|---|---|
| Pending / Confirmed | 📋 Open Full Folio → · 🖨️ Print Folio · ✅ Check In Now · ❌ Cancel Booking · Close |
| In-house | 📋 Open Full Folio → · 🖨️ Print Folio · ❌ Cancel · Close |
| Checked-out | 📋 Open Full Folio → · 🖨️ Print Folio · 🧾 View Bill · Close |

Single primary CTA in all states: **Open Full Folio →**. Folio.html
handles everything (extras, payments, finalize, view invoice) from
there. Cancel stays as a destructive-action affordance on the modal.

The "Add Extra Charge" modal HTML in bookings.html stays (other code
paths might reference it) — just the button trigger is gone.

## Files in this hotfix (2)

```
db/migrations/030a_finalize_column_fix.sql   ← NEW
bookings.html                                ← drop-in replace
```

No SQL data migration. No folio.html change. Pure code fix + UX cleanup.

## Deploy

1. **SQL** — run `030a_finalize_column_fix.sql` in Supabase SQL Editor
2. **Verify** — call the finalize RPC again on the same booking that
   failed earlier:
   ```sql
   SELECT public.sbp_folio_finalize_to_bill(
     '<your-shop-id>'::uuid,
     'ffce7be7-01d7-4185-a723-2ba0d74bf3be'::uuid    -- booking from your screenshot
   );
   ```
   Should return `{ ok: true, already_done: false, bill_id: '...', invoice_no: '...', ... }`
3. **Push** bookings.html via GitHub Desktop
4. **Hard-refresh PWA**, retry "Check Out & Finalize" from folio.html

## After this lands, the open architectural ask is:

**Batch 022D — Audit & Authorization (the PIN system you asked for)**
See the response above for full scope. Recommend tackling that next.
