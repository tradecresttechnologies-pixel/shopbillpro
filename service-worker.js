// ShopBill Pro Service Worker — v1.5.0 KILL-SWITCH (12 May 2026)
//
// Purpose: An earlier SW (v1.4.0, batch 1A) was registered in browsers but the
// matching code on disk had been emptied. The browser kept the old SW + its
// cache alive, serving stale HTML/JS to users even after we deployed fixes.
// Result: shopkeepers saw "I deployed but nothing changed" repeatedly.
//
// This v1.5.0 SW:
//   1. skipWaiting() — activates immediately, doesn't wait for tabs to close
//   2. clients.claim() — takes over any already-open tabs
//   3. Wipes ALL caches from any prior SW
//   4. Unregisters itself — so the next request goes straight to the network
//   5. Reloads open tabs once so they pick up fresh assets immediately
//
// After every existing user hits this once, no SW is active. Vercel serves
// each request from its CDN. Hard-refreshes work normally. PWA offline
// support is handled at the app layer via localStorage caching of shop +
// customers + bills + products — we don't need a separate SW cache for it.
//
// If we ever want real SW-level offline caching later (precache routing,
// background sync, etc.) we add it back as a NEW SW with a deliberate
// strategy. This file kills the legacy SW and clears the slate.

const SW_VERSION = 'v1.5.0-killswitch';

self.addEventListener('install', (event) => {
  console.log('[SW ' + SW_VERSION + '] install — skipping waiting');
  // Activate immediately, don't wait for existing SW's clients to close
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  console.log('[SW ' + SW_VERSION + '] activate — cleaning up');
  event.waitUntil((async () => {
    try {
      // 1. Take control of all open tabs immediately
      await self.clients.claim();

      // 2. Wipe ALL caches from any prior SW version
      const cacheNames = await caches.keys();
      console.log('[SW ' + SW_VERSION + '] deleting caches:', cacheNames);
      await Promise.all(cacheNames.map((name) => caches.delete(name)));

      // 3. Unregister this SW so future requests skip the SW layer entirely
      if (self.registration) {
        await self.registration.unregister();
        console.log('[SW ' + SW_VERSION + '] unregistered');
      }

      // 4. Force every open tab to reload once so they pick up fresh assets
      //    (cached pages are gone, so reload hits the network — which is what
      //    we want). One-time pain, then everyone's on fresh code.
      const allClients = await self.clients.matchAll({ type: 'window' });
      for (const client of allClients) {
        try {
          client.navigate(client.url);
        } catch (e) {
          // Some browsers reject navigate() in certain states. Non-fatal —
          // user will pick up fresh assets on their next navigation anyway.
        }
      }
    } catch (err) {
      console.warn('[SW ' + SW_VERSION + '] cleanup error:', err);
    }
  })());
});

// Fetch handler: pass-through. We do NOT cache anything. The browser's
// own HTTP cache + Vercel's CDN cache headers are sufficient. The
// `service-worker.js` file itself has Cache-Control: no-store via
// vercel.json so any future SW update is picked up immediately.
self.addEventListener('fetch', (event) => {
  // Intentionally empty — let the browser handle the fetch normally.
});

// Optional: catch messages from the page (e.g. for forced unregister)
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
