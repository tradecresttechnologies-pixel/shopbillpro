// ════════════════════════════════════════════════════════════════════
// supabase/functions/bill-payment-webhook/index.ts
// Razorpay webhook for CUSTOMER bill payments (Flow B). SEPARATE from the
// existing subscription webhook `razorpay-webhook` (Flow A). Do not merge.
//
// Verifies HMAC with the PAYING SHOP'S OWN webhook secret (from Vault via
// sbp_fn_get_creds, keyed by shop_id in notes). On success: idempotently
// records the payment + marks the bill Paid (=> Supabase Realtime fires the
// in-app soundbox) and best-effort Web Push for the app-closed case.
//
// Deploy:  supabase functions deploy bill-payment-webhook --no-verify-jwt
// Register per shop in Razorpay with events:
//   payment_link.paid, qr_code.credited, payment.captured
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
//      VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:..)
// ════════════════════════════════════════════════════════════════════
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const ok  = (b: unknown) => new Response(JSON.stringify(b), { status: 200, headers: { "Content-Type": "application/json" } });
const bad = (b: unknown, s = 400) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

// HMAC-SHA256 hex using WebCrypto (matches the existing razorpay-webhook style)
async function hmacHex(body: string, secret: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function ctEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let m = 0; for (let i = 0; i < a.length; i++) m |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return m === 0;
}

function extract(evt: any) {
  const p = evt?.payload ?? {};
  const payment = p.payment?.entity;
  const link = p.payment_link?.entity;
  const qr = p.qr_code?.entity;
  const notes = payment?.notes ?? link?.notes ?? qr?.notes ?? {};
  return {
    notes,
    paymentId: payment?.id ?? evt?.id,
    entityId: link?.id ?? qr?.id ?? payment?.order_id,
    amountPaise: payment?.amount ?? link?.amount_paid ?? qr?.payments_amount_received,
  };
}

serve(async (req) => {
  if (req.method !== "POST") return bad({ ok: false, error: "method_not_allowed" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const svc = createClient(SUPABASE_URL, SERVICE_KEY);

  const raw = await req.text();
  const sig = req.headers.get("x-razorpay-signature") ?? "";

  let evt: any;
  try { evt = JSON.parse(raw); } catch { return bad({ ok: false, error: "bad_json" }); }

  const { notes, paymentId, entityId, amountPaise } = extract(evt);
  const shopId: string | undefined = notes?.shop_id;
  const billId: string | undefined = notes?.bill_id;
  if (!shopId) return bad({ ok: false, error: "no_shop_in_notes" });

  const { data: creds } = await svc.rpc("sbp_fn_get_creds", { p_shop_id: shopId });
  if (!creds?.ok || !creds.webhook_secret)
    return bad({ ok: false, error: "no_webhook_secret" }, 412);

  const expected = await hmacHex(raw, creds.webhook_secret);
  if (!ctEq(expected, sig)) return bad({ ok: false, error: "bad_signature" }, 401);

  const event = evt?.event ?? "";
  const success = ["payment_link.paid", "qr_code.credited", "payment.captured"].includes(event);
  if (!success) return ok({ ok: true, ignored: event });

  const { data: rec } = await svc.rpc("sbp_fn_record_payment", {
    p_shop_id: shopId,
    p_bill_id: billId ?? null,
    p_rzp_entity_id: entityId ?? null,
    p_rzp_payment_id: paymentId ?? `${entityId}-${Date.now()}`,
    p_amount_paise: amountPaise ?? 0,
    p_raw: evt,
  });
  if (rec?.already) return ok({ ok: true, already: true });

  // best-effort Web Push (app-closed)
  try {
    const pub = Deno.env.get("VAPID_PUBLIC_KEY");
    const prv = Deno.env.get("VAPID_PRIVATE_KEY");
    const sub = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@shopbillpro.in";
    if (pub && prv) {
      webpush.setVapidDetails(sub, pub, prv);
      const { data: subs } = await svc
        .from("sbp_push_subscriptions").select("*").eq("shop_id", shopId);
      const rupees = Math.round((amountPaise ?? 0) / 100);
      const payload = JSON.stringify({
        title: "Payment received", body: `₹${rupees} received`, amount_paise: amountPaise ?? 0,
      });
      await Promise.allSettled((subs ?? []).map((s: any) =>
        webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
        ).catch(async (err: any) => {
          if (err?.statusCode === 404 || err?.statusCode === 410)
            await svc.from("sbp_push_subscriptions").delete().eq("endpoint", s.endpoint);
        })
      ));
    }
  } catch (_) { /* push best-effort; realtime is primary */ }

  return ok({ ok: true, recorded: true });
});
