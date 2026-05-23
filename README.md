# ShopBill Pro v5 — Single-page polished website

## Drop-in file structure
Paths in this zip = paths in your repo. Just copy them in.

## Deploy steps

### 1. Run SQL migrations (in this order)
- `db/migrations/097_rollback_to_singlepage.sql`
- `db/migrations/098_website_prompt_v18.sql`

### 2. Replace files in your repo
- `lib/live-site.js`
- `s.html`
- `website-builder.html`
- `supabase/functions/generate-ai-website/index.ts`

### 3. Push via GitHub Desktop → Vercel auto-deploys

### 4. Deploy Edge Function
```bash
supabase functions deploy generate-ai-website
```

## Full deploy guide
See `docs/DEPLOY_v5_singlepage.md` for:
- Exact deploy order
- 8-step test plan  
- Rollback procedure
- Honest flags about what to expect

## Bundle contents

| Path | Purpose | Size |
|------|---------|------|
| `db/migrations/097_rollback_to_singlepage.sql` | Deactivate multi-page experiment | 3KB |
| `db/migrations/098_website_prompt_v18.sql` | New single-page prompt: modals + motion | 22KB |
| `lib/live-site.js` | Runtime: modals + motion + progressive enhancement | 60KB |
| `s.html` | Public shop page renderer (scope bug fixed) | 65KB |
| `website-builder.html` | Builder UI (M2 chained gen reverted) | 112KB |
| `supabase/functions/generate-ai-website/index.ts` | Edge Function v3.11 | 18KB |
| `docs/DEPLOY_v5_singlepage.md` | Full deploy guide + test plan | 8KB |
