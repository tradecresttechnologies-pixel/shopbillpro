// ShopBill Pro Service Worker — v1.6.0 MINIMAL-PWA-ENABLE (27 May 2026)
//
// PURPOSE
//   Chrome/Edge require an active service worker with a fetch handler for
//   PWA installability (the "Install app" omnibox icon, beforeinstallprompt
//   event, and Add to Home Screen flow on Android). Without a registered
//   active SW these never appear.
//
// HISTORY
//   v1.4.0 (Apr 2026) — first SW with cache logic. Caused stale-HTML/JS
//     bugs because users' browsers kept the cached old SW running long
//     after we deployed fixes.
//   v1.5.0 (12 May 2026) — kill-switch SW that wipes all caches and
//     unregisters itself. Solved the staleness problem but eliminated
//     PWA install capability as a side effect.
//   v1.6.0 (THIS FILE) — minimal pass-through SW that:
//     • Satisfies Chrome's install criteria (presence + fetch handler)
//     • Never caches ANY resource (fetch handler is pure pass-through)
//     • Cannot serve stale assets because it has no cache logic
//     • Activates immediately and claims open tabs
//     • Wipes any lingering caches from earlier SW versions
//
// WHY THIS IS SAFE
//   The stale-asset disaster of v1.4.0 was caused by cache.match() returning
//   old cached responses. v1.6.0 has zero cache code. Every fetch goes to
//   the network exactly as it would without an SW. Vercel CDN + browser
//   HTTP cache handle freshness as normal. The only difference vs
//   no-SW-at-all: the browser knows a SW is registered, which is what
//   the install prompt engine checks for.
//
// DEPLOY NOTES
//   • Cache-Control: no-store on this file (set in vercel.json) — browsers
//     always re-fetch the SW source on update checks
//   • skipWaiting() + clients.claim() — old kill-switch SW gets replaced
//     immediately when users next visit, no waiting for tab close
//   • dashboard.html previously had a block that unregistered any SW on
//     load; that block is REMOVED in this batch (see DEPLOY PATHS)

const SW_VERSION = 'v1.7.0-pwa-push';

self.addEventListener('install', (event) => {
  console.log('[SW ' + SW_VERSION + '] install — skipping waiting');
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  console.log('[SW ' + SW_VERSION + '] activate — claiming clients');
  event.waitUntil((async () => {
    try {
      // Take control of any open tabs
      await self.clients.claim();

      // One-time housekeeping: wipe any lingering caches from v1.4.0 /
      // v1.5.0. After every user has visited once post-v1.6.0, this is
      // a no-op (caches.keys() returns []).
      if (self.caches) {
        const names = await caches.keys();
        if (names.length > 0) {
          console.log('[SW ' + SW_VERSION + '] cleaning legacy caches:', names);
          await Promise.all(names.map((n) => caches.delete(n)));
        }
      }
    } catch (err) {
      console.warn('[SW ' + SW_VERSION + '] activate cleanup error:', err);
    }
  })());
});

// PASS-THROUGH FETCH HANDLER
//
// Chrome's PWA install eligibility check requires the SW to have a fetch
// event listener. This satisfies that requirement while doing NOTHING.
// We do NOT call event.respondWith(), so the browser proceeds with its
// default network fetch exactly as if no SW were present.
//
// THIS IS DELIBERATE. Adding caching here would resurrect the v1.4.0
// staleness bugs. If we ever want real offline support, do it as a
// deliberate new SW version (v1.7+) with explicit cache versioning,
// cache-busting on deploy, and a kill-switch fallback.
self.addEventListener('fetch', (event) => {
  // Intentionally empty — browser handles fetch normally
});

// Allow page-initiated SW updates
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});

// ═══════════════════════════════════════════════════════════════════
// v9 Payments — Web Push handlers (app-closed "₹X received" alert)
// Added in v1.7.0. The pass-through fetch handler above is unchanged:
// no caching is introduced here.
// ═══════════════════════════════════════════════════════════════════
self.addEventListener('push', (event) => {
  let data = { title: 'Payment received', body: 'Payment received' };
  try { data = event.data ? event.data.json() : data; } catch (_) {}
  event.waitUntil(
    self.registration.showNotification(data.title || 'Payment received', {
      body: data.body || '',
      icon: '/icons/icon-192x192.png',
      badge: '/icons/icon-72x72.png',
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
