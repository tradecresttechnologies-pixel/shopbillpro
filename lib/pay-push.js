/* ============================================================================
 * lib/pay-push.js  —  ShopBill Pro v9
 * Registers the shop's device for Web Push so the "₹X received" alert fires
 * even when the app is CLOSED. Stores the subscription in sbp_push_subscriptions
 * (RLS: owner-only). Android Chrome: full support. iOS: 16.4+ AND installed PWA.
 *
 * Requires: window._sb, a service worker already registered (your SW),
 *           and VAPID_PUBLIC_KEY (same keypair as the webhook env).
 * Call: await SBPPayPush.enable(shopId, VAPID_PUBLIC_KEY)
 * ========================================================================== */
(function () {
  function urlB64ToUint8(base64) {
    const pad = "=".repeat((4 - (base64.length % 4)) % 4);
    const b64 = (base64 + pad).replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(b64);
    return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
  }

  async function enable(shopId, vapidPublicKey) {
    if (!("serviceWorker" in navigator) || !("PushManager" in window))
      return { ok: false, error: "push_unsupported" };
    if (!window._sb || !shopId) return { ok: false, error: "missing_context" };

    const perm = await Notification.requestPermission();
    if (perm !== "granted") return { ok: false, error: "permission_denied" };

    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if (!sub) {
      sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlB64ToUint8(vapidPublicKey),
      });
    }
    const j = sub.toJSON();
    const { error } = await window._sb
      .from("sbp_push_subscriptions")
      .upsert(
        { shop_id: shopId, endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth },
        { onConflict: "endpoint" }
      );
    if (error) return { ok: false, error: error.message };
    return { ok: true };
  }

  async function disable() {
    if (!("serviceWorker" in navigator)) return { ok: true };
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) {
      const ep = sub.endpoint;
      await sub.unsubscribe();
      if (window._sb) await window._sb.from("sbp_push_subscriptions").delete().eq("endpoint", ep);
    }
    return { ok: true };
  }

  window.SBPPayPush = { enable, disable };
})();
