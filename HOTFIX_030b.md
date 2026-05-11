# Hotfix 030b — next_invoice_no return columns

**Your error:** `Could not finalize: invoice_no_failed`

**Root cause:** I assumed `next_invoice_no` returns `(prefix, n)`. The
actual return columns are `invoice_prefix` and `invoice_counter`
(confirmed via billing.html usage). My PL/pgSQL referenced non-existent
fields → exception → caught → returned the generic `invoice_no_failed`
error.

**The bigger fix:** the exception handler now also returns `detail`
(the underlying `SQLERRM` text) and `state` (PostgreSQL error code).
folio.html now displays the detail in the error toast — so any future
SQL errors are diagnosable in one screenshot instead of a back-and-forth.

## Files (2)

```
db/migrations/030b_invoice_no_columns_fix.sql   ← NEW
folio.html                                      ← drop-in replace (better error msg)
```

## Deploy

1. Supabase SQL Editor → run `030b_invoice_no_columns_fix.sql`
2. Push folio.html
3. Retry "Check Out & Finalize" from the same booking

Expected: toast shows `✓ Invoice GG-NNNN generated` and folio refreshes
with the invoice number badge + locked state.

If something else fails, the error toast will now show the actual SQL
detail like `Could not finalize: invoice_no_failed (relation "X" does
not exist)` instead of just the generic error code — send screenshot.
