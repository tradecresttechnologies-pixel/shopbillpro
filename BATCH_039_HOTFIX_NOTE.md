# 039 hotfix — pre-existing `sbp_bill_void` collision

## The error you hit

```
ERROR: 42P13: cannot change name of input parameter "p_reason"
HINT: Use DROP FUNCTION sbp_bill_void(uuid,uuid,text,text) first.
```

Postgres's quirk: `CREATE OR REPLACE FUNCTION` can update the function
body, return type, language, etc. — but it **cannot rename parameters**.
For that, you have to `DROP` the old function first. This is a one-line
fix.

## Why it happened

There's already a `sbp_bill_void(uuid, uuid, text, text)` in your DB
from some earlier work — probably an old draft or an unrelated batch.
Migration 039 tried to redefine it with parameter name `p_reason` in
the 4th slot, but the existing function had a different name there.

The other 5 RPCs in migration 038 deployed cleanly, which confirms
only `sbp_bill_void` had a pre-existing version.

## The fix

Updated 039 has a `DROP FUNCTION IF EXISTS` line before the `CREATE`.
Idempotent — no-op if the old function isn't there, drops it if it is.

```sql
DROP FUNCTION IF EXISTS public.sbp_bill_void(uuid, uuid, text, text);
CREATE OR REPLACE FUNCTION public.sbp_bill_void(...) ...
```

## Deploy

1. Run the **updated** `039_bill_void_action.sql` in Supabase SQL Editor
2. (HTML didn't change — `bills.html` from 022D-E is fine as-is)
3. Done.

## Optional sanity check (run BEFORE you re-run 039)

If you want to see what the old `sbp_bill_void` looked like — in case
anything else in the codebase was calling it with different parameter
names — run this first:

```sql
SELECT
  proname,
  pg_get_function_identity_arguments(oid)        AS arguments,
  pg_get_function_arguments(oid)                 AS arguments_with_defaults,
  pg_get_function_result(oid)                    AS returns,
  prosrc                                         AS body
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname = 'sbp_bill_void';
```

If you see anything unexpected in the body, paste it here and I'll
make sure the new version preserves behavior. Otherwise, just run
the updated 039 — the new function does exactly what `voidBill` in
bills.html used to do client-side, just server-verified.

## Lesson absorbed

For future migrations, I'll default to:
```sql
DROP FUNCTION IF EXISTS public.<name>(<types>);
CREATE OR REPLACE FUNCTION public.<name>(...) ...
```

This avoids the parameter-name-change trap on any pre-existing function.
A few extra lines per migration, zero risk of this error.
