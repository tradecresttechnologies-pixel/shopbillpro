// ═══════════════════════════════════════════════════════════════════════
// SERVICE WORKER — push additions for ShopBill Pro v9
//
// MERGE these into the EXISTING service-worker.js (currently v1.6.0 minimal
// pass-through). DO NOT replace the file and DO NOT add any cache logic —
// the existing file documents a real stale-cache disaster (v1.4.0) and the
// pass-through fetch handler must stay exactly as-is.
//
// STEPS:
//   1. Bump the version string:
//        const SW_VERSION = 'v1.7.0-pwa-push';
//   2. Paste the two listeners below at the END of service-worker.js
//      (after the existing 'message' listener). Leave the empty
//      'fetch' pass-through handler untouched.
//   3. Confirm the icon path — vercel.json caches /icons/* immutably, and
//      manifest icons use the /icons/ prefix, so use /icons/... below.
//
// Audio note: the SW cannot play audio. In-app sound comes from
// lib/pay-announce.js (app open). This handles the app-closed case with the
// OS notification (its own sound) + visible "₹X received".
// ═══════════════════════════════════════════════════════════════════════

// ---- paste at end of service-worker.js ----
self.addEventListener('push', (event) => {
  let data = { title: 'Payment received', body: 'Payment received' };
  try { data = event.data ? event.data.json() : data; } catch (_) {}
  event.waitUntil(
    self.registration.showNotification(data.title || 'Payment received', {
      body: data.body || '',
      icon: '/icons/icon-192.png',     // confirm against manifest.json icon names
      badge: '/icons/icon-192.png',
      vibrate: [180, 80, 180],
      tag: 'sbp-payment',
      renotify: true,
      data: { url: '/bills' }
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      for (const w of wins) { if ('focus' in w) return w.focus(); }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});
// ---- end paste ----
