/* ============================================================================
 * lib/pay-realtime.js  —  ShopBill Pro v9
 * Subscribes to INSERTs on sbp_bill_payments for the current shop. When a
 * customer payment lands (via the webhook), this fires the soundbox alert
 * while the app is OPEN. (App-closed alerts come from Web Push — pay-push.js.)
 *
 * Requires: window._sb (Supabase client), lib/pay-announce.js loaded.
 * Call: SBPPayRealtime.start(shopId)  — once per session, Pro/Business only.
 * ========================================================================== */
(function () {
  let channel = null;

  function toast(msg) {
    // Lightweight, dependency-free toast. Replace with the app's toast if present.
    let el = document.getElementById("sbp-pay-toast");
    if (!el) {
      el = document.createElement("div");
      el.id = "sbp-pay-toast";
      el.style.cssText =
        "position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:99999;" +
        "background:#166534;color:#fff;padding:14px 22px;border-radius:12px;font:600 16px Poppins,sans-serif;" +
        "box-shadow:0 8px 28px rgba(0,0,0,.25);opacity:0;transition:opacity .25s;";
      document.body.appendChild(el);
    }
    el.textContent = msg;
    el.style.opacity = "1";
    clearTimeout(el._t);
    el._t = setTimeout(() => (el.style.opacity = "0"), 4000);
  }

  function start(shopId) {
    if (!window._sb || !shopId) return;
    stop();
    channel = window._sb
      .channel("sbp-bill-payments-" + shopId)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "sbp_bill_payments", filter: `shop_id=eq.${shopId}` },
        (payload) => {
          const rupees = Math.round((payload?.new?.amount_paise || 0) / 100);
          toast(`✓ ₹${rupees.toLocaleString("en-IN")} received`);
          if (window.SBPAnnounce) window.SBPAnnounce.announce(rupees);
          // Optional: refresh the bills list / mark row paid in UI here.
          document.dispatchEvent(new CustomEvent("sbp:payment", { detail: payload.new }));
        }
      )
      .subscribe();
  }

  function stop() {
    if (channel && window._sb) { window._sb.removeChannel(channel); channel = null; }
  }

  window.SBPPayRealtime = { start, stop };
})();
