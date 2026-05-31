// ════════════════════════════════════════════════════════════════════
// supabase/functions/create-bill-payment/index.ts
// Creates a Razorpay Payment Link (or UPI QR) for ONE bill using the SHOP'S
// OWN Razorpay keys (decrypted from Vault via sbp_fn_get_creds). Tags
// shop_id/bill_id/token in `notes` so the webhook can reconcile.
// Pro/Business only (creds only exist for paid plans).
//
// Deploy:  supabase functions deploy create-bill-payment
//          (keep default JWT verification ON — called by the logged-in shop)
//
// Audited: bill total column = grand_total.
// ════════════════════════════════════════════════════════════════════
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const authHeader   = req.headers.get("Authorization") ?? "";

    // identify caller
    const userClient = createClient(SUPABASE_URL, SERVICE_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: u } = await userClient.auth.getUser();
    if (!u?.user) return json({ ok: false, error: "not_authenticated" }, 401);

    const body = await req.json().catch(() => ({}));
    const billId: string | undefined = body.bill_id;
    const want = (body.method ?? "link") as "link" | "qr";
    if (!billId) return json({ ok: false, error: "missing_bill_id" }, 400);

    const svc = createClient(SUPABASE_URL, SERVICE_KEY);

    // load bill + items, verify ownership
    const { data: bill, error: be } = await svc
      .from("bills").select("*, bill_items(*)").eq("id", billId).single();
    if (be || !bill) return json({ ok: false, error: "bill_not_found" }, 404);

    const { data: shop } = await svc
      .from("shops").select("id, owner_id, name").eq("id", bill.shop_id).single();
    if (!shop || shop.owner_id !== u.user.id)
      return json({ ok: false, error: "not_owner" }, 403);

    // amount (real column: grand_total)
    const total = Number(bill.grand_total ?? 0);
    const amountPaise = Math.round(total * 100);
    if (!amountPaise || amountPaise < 100)
      return json({ ok: false, error: "invalid_amount" }, 400);

    // ensure share token
    const { data: tok } = await svc.rpc("sbp_get_bill_pay_token", { p_bill_id: billId });
    const token = tok?.token ?? "";

    // decrypt this shop's Razorpay keys (Vault-backed, service-role-only RPC)
    const { data: creds } = await svc.rpc("sbp_fn_get_creds", { p_shop_id: shop.id });
    if (!creds?.ok) return json({ ok: false, error: "razorpay_not_connected" }, 412);

    const basic = "Basic " + btoa(`${creds.key_id}:${creds.key_secret}`);
    const notes = { shop_id: shop.id, bill_id: billId, token };

    if (want === "link") {
      const r = await fetch("https://api.razorpay.com/v1/payment_links", {
        method: "POST",
        headers: { Authorization: basic, "Content-Type": "application/json" },
        body: JSON.stringify({
          amount: amountPaise, currency: "INR", accept_partial: false,
          description: `${shop.name} • Bill ${bill.invoice_no ?? ""}`.trim(),
          notes, reminder_enable: false,
        }),
      });
      const data = await r.json();
      if (!r.ok) return json({ ok: false, error: "razorpay_error", detail: data }, 502);
      return json({ ok: true, method: "link", id: data.id, short_url: data.short_url });
    }

    const r = await fetch("https://api.razorpay.com/v1/payments/qr_codes", {
      method: "POST",
      headers: { Authorization: basic, "Content-Type": "application/json" },
      body: JSON.stringify({
        type: "upi_qr", name: shop.name, usage: "single_use",
        fixed_amount: true, payment_amount: amountPaise, notes,
      }),
    });
    const data = await r.json();
    if (!r.ok) return json({ ok: false, error: "razorpay_error", detail: data }, 502);
    return json({ ok: true, method: "qr", id: data.id, image_url: data.image_url });
  } catch (e) {
    return json({ ok: false, error: "exception", detail: String(e) }, 500);
  }
});
