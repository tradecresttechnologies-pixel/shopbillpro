// supabase/functions/indexnow-flush/index.ts
//
// v8.0 — Drains _sbp_indexnow_queue and submits URLs to IndexNow.
//
// HOW IT'S TRIGGERED
//   • pg_cron job inside Supabase, every 10 min (see mig 105 section 6).
//   • Or manually: POST https://{project}.supabase.co/functions/v1/indexnow-flush
//     with the service-role key in the Authorization header.
//
// AUTH
//   This endpoint is intentionally open to POST (no auth required) because
//   pg_net's HTTP POST from inside Supabase can pass any header but
//   simpler if anon. The function only reads its own data and pings an
//   external service — no destructive ops possible. Worst case: an
//   attacker triggers a flush, which is what we'd want anyway.
//
// HOW INDEXNOW WORKS
//   POST https://api.indexnow.org/IndexNow with JSON:
//     {
//       "host":     "app.shopbillpro.in",
//       "key":      "{IndexNowKey}",
//       "keyLocation": "https://app.shopbillpro.in/.well-known/{IndexNowKey}.txt",
//       "urlList":  ["https://app.shopbillpro.in/s/foo", ...]
//     }
//   Max 10,000 URLs per request. We batch by host.
//
// REQUIRED SECRETS (set via Supabase Edge Function Secrets dashboard)
//   SUPABASE_URL                 — auto
//   SUPABASE_SERVICE_ROLE_KEY    — needed to write to _sbp_indexnow_queue
//   INDEXNOW_KEY                 — the 32-char key matching /.well-known/{key}.txt

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL              = Deno.env.get("SUPABASE_URL")              ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const INDEXNOW_KEY              = Deno.env.get("INDEXNOW_KEY")              ?? "";

const MAX_PER_BATCH = 100;        // Drain at most 100 per invocation
const MAX_ATTEMPTS  = 5;          // Stop retrying after 5 failures

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok");

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return json({ ok: false, error: "misconfigured", missing: "supabase_creds" }, 500);
  }
  if (!INDEXNOW_KEY || INDEXNOW_KEY.length < 8) {
    return json({ ok: false, error: "misconfigured", missing: "INDEXNOW_KEY" }, 500);
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ── 1. Pull batch (oldest first, skip exhausted ones) ─────────────
  const { data: queue, error: qErr } = await sb
    .from("_sbp_indexnow_queue")
    .select("url, attempts")
    .lt("attempts", MAX_ATTEMPTS)
    .order("enqueued_at", { ascending: true })
    .limit(MAX_PER_BATCH);

  if (qErr) {
    console.error("[indexnow-flush] queue read error:", qErr);
    return json({ ok: false, error: "queue_read", detail: qErr.message }, 500);
  }
  if (!queue || queue.length === 0) {
    return json({ ok: true, drained: 0, message: "queue_empty" });
  }

  // ── 2. Group URLs by host (IndexNow requires one host per request) ─
  const byHost: Record<string, string[]> = {};
  for (const row of queue) {
    try {
      const u = new URL(row.url);
      const host = u.host;
      (byHost[host] ||= []).push(row.url);
    } catch {
      // Bad URL — mark exhausted so we don't keep retrying
      await sb.from("_sbp_indexnow_queue")
        .update({ attempts: MAX_ATTEMPTS, last_error: "invalid_url", last_attempt: new Date().toISOString() })
        .eq("url", row.url);
    }
  }

  // ── 3. POST to IndexNow per host ──────────────────────────────────
  const results: Array<{ host: string; status: number; count: number; error?: string }> = [];

  for (const [host, urlList] of Object.entries(byHost)) {
    const keyLocation = `https://${host}/.well-known/${INDEXNOW_KEY}.txt`;
    const payload = {
      host,
      key:         INDEXNOW_KEY,
      keyLocation,
      urlList,
    };

    let status = 0;
    let errMsg: string | null = null;
    try {
      const r = await fetch("https://api.indexnow.org/IndexNow", {
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Accept":       "application/json",
        },
        body: JSON.stringify(payload),
      });
      status = r.status;

      // IndexNow returns 200 (ok), 202 (accepted), 422 (key/host mismatch),
      // 403 (key file unreachable), 400 (bad request). 200/202 = success.
      if (status !== 200 && status !== 202) {
        errMsg = `http_${status}: ` + (await r.text()).slice(0, 200);
      }
    } catch (e) {
      errMsg = "fetch_error: " + (e instanceof Error ? e.message : String(e));
    }

    results.push({ host, status, count: urlList.length, error: errMsg ?? undefined });

    // ── 4. Update queue ──────────────────────────────────────────────
    if (errMsg === null) {
      // Success — delete from queue
      const { error: delErr } = await sb
        .from("_sbp_indexnow_queue")
        .delete()
        .in("url", urlList);
      if (delErr) console.error("[indexnow-flush] delete error:", delErr);
    } else {
      // Failure — increment attempts, record error
      const nowIso = new Date().toISOString();
      for (const url of urlList) {
        const row = queue.find(q => q.url === url);
        const attempts = (row?.attempts || 0) + 1;
        await sb.from("_sbp_indexnow_queue").update({
          attempts,
          last_attempt: nowIso,
          last_error:   errMsg.slice(0, 500),
        }).eq("url", url);
      }
    }
  }

  return json({
    ok:           true,
    drained:      queue.length,
    hosts:        Object.keys(byHost).length,
    results,
  });
});
