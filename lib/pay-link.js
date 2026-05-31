/* ════════════════════════════════════════════════════════════════════
 * lib/pay-link.js  —  ShopBill Pro v9 Payments (client helpers)
 * Used INSIDE the authed PWA (bills page). Requires window._sb (bills.html
 * sets it at line ~588). Requires migrations 106/107 + edge functions.
 * Exposes window.SBPPay = { getBillLink, whatsAppText, whatsAppShareUrl,
 *                           upiIntent, createGatewayLink }
 * Audited fields: grand_total, invoice_no, shops.upi.
 * ════════════════════════════════════════════════════════════════════ */
(function () {
  const APP_ORIGIN = "https://app.shopbillpro.in";

  function sb() {
    if (!window._sb) throw new Error("supabase_client_missing");
    return window._sb;
  }

  // Ensure/fetch the public share token; return the hosted bill URL.
  // cleanUrls is on in vercel.json, so /bill?b=..&t=.. resolves to bill.html.
  async function getBillLink(billId) {
    const { data, error } = await sb().rpc("sbp_get_bill_pay_token", { p_bill_id: billId });
    if (error || !data?.ok) return { ok: false, error: error?.message || data?.error };
    const url = `${APP_ORIGIN}/bill?b=${encodeURIComponent(billId)}&t=${encodeURIComponent(data.token)}`;
    return { ok: true, url, token: data.token, invoice_no: data.invoice_no };
  }

  function whatsAppText({ shopName, invoiceNo, total, billUrl, payUrl }) {
    return [
      `*${shopName || "Your bill"}*`,
      invoiceNo ? `Bill #${invoiceNo}` : null,
      total != null ? `Amount: ₹${Number(total).toLocaleString("en-IN")}` : null,
      "",
      billUrl ? `View / download: ${billUrl}` : null,
      payUrl ? `Pay online: ${payUrl}` : null,
    ].filter(Boolean).join("\n");
  }

  function whatsAppShareUrl(phone, text) {
    const p = (phone || "").replace(/\D/g, "");
    return `https://wa.me/${p}?text=${encodeURIComponent(text)}`;
  }

  // Direct UPI-app intent (no gateway). Uses shops.upi.
  function upiIntent({ vpa, shopName, amount, invoiceNo }) {
    if (!vpa) return null;
    const am = Number(amount || 0).toFixed(2);
    const tn = encodeURIComponent("Bill " + (invoiceNo || ""));
    const pn = encodeURIComponent(shopName || "Shop");
    return `upi://pay?pa=${encodeURIComponent(vpa)}&pn=${pn}&am=${am}&tn=${tn}&cu=INR`;
  }

  // Pro/Business: create a Razorpay payment link (auto-confirm) for a bill.
  async function createGatewayLink(billId, method = "link") {
    const { data: { session } } = await sb().auth.getSession();
    const token = session?.access_token;
    if (!token) return { ok: false, error: "not_authenticated" };
    const base = (window.SB_URL) || "https://jfqeirfrkjdkqqixivru.supabase.co";
    const res = await fetch(`${base}/functions/v1/create-bill-payment`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ bill_id: billId, method }),
    });
    return await res.json();
  }

  window.SBPPay = Object.assign(window.SBPPay || {}, {
    getBillLink, whatsAppText, whatsAppShareUrl, upiIntent, createGatewayLink,
  });
})();
