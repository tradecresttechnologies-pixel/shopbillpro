/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Service Worker v1.3.0
   TradeCrest Technologies Pvt. Ltd.
   Offline-first caching strategy
══════════════════════════════════════════════════════════════════ */

const CACHE_NAME = 'shopbillpro-v1.3.0-' + '20260427';  // FIX #20 — bump on each release
const OFFLINE_URL = '/index.html';

const STATIC_ASSETS = [
  '/',
  '/index.html',
  '/dashboard.html',
  '/billing.html',
  '/bills.html',
  '/customers.html',
  '/stock.html',
  '/reports.html',
  '/pos-admin.html',
  '/wa-center.html',
  '/cash-register.html',
  '/supplier.html',
  '/recurring.html',
  '/bill-templates.html',
  '/settings.html',
  // FIX #19 — these were missing
  '/marketing.html',
  '/team.html',
  '/subscription.html',
  '/auth.js',
  '/db.js',
  '/db-local.js',
  '/lang.js',
  '/scanner.js',
  '/sync.js',
  '/ui.js',
  '/upgrade-popup.js',
  '/conversion.js',
  '/styles.css',
  '/fix.css',
  '/manifest.json',
  '/icons/icon-192x192.png',
  '/icons/icon-512x512.png',
  'https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700;800;900&family=Noto+Sans:wght@300;400;500;600;700&family=Noto+Sans+Devanagari:wght@400;500;600;700&display=swap',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js',
];

/* ── Install: cache all static assets ── */
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      console.log('[SW] Caching static assets');
      return Promise.allSettled(
        STATIC_ASSETS.map(url => cache.add(url).catch(e => console.warn('[SW] Failed to cache:', url, e)))
      );
    }).then(() => self.skipWaiting())
  );
});

/* ── Activate: clean old caches ── */
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => {
        console.log('[SW] Deleting old cache:', k);
        return caches.delete(k);
      }))
    ).then(() => self.clients.claim())
  );
});

/* ── Fetch: cache-first for static, network-first for API ── */
self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests
  if (request.method !== 'GET') return;

  // Skip Supabase API calls — always network
  if (url.hostname.includes('supabase.co')) return;

  // Skip chrome-extension and other non-http
  if (!url.protocol.startsWith('http')) return;

  // Network-first for HTML pages (to get latest version)
  if (request.destination === 'document' || url.pathname.endsWith('.html')) {
    event.respondWith(
      fetch(request)
        .then(response => {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
          return response;
        })
        .catch(() => caches.match(request).then(r => r || caches.match(OFFLINE_URL)))
    );
    return;
  }

  // Cache-first for fonts, icons, JS libraries
  event.respondWith(
    caches.match(request).then(cached => {
      if (cached) return cached;
      return fetch(request).then(response => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
        }
        return response;
      }).catch(() => cached);
    })
  );
});

/* ── Background sync for offline bills ── */
self.addEventListener('sync', event => {
  if (event.tag === 'sync-bills') {
    event.waitUntil(syncOfflineBills());
  }
});

async function syncOfflineBills() {
  console.log('[SW] Background sync triggered');
  // Notify all clients to process sync queue
  const clients = await self.clients.matchAll();
  clients.forEach(client => client.postMessage({ type: 'SYNC_QUEUE' }));
}

console.log('[SW] ShopBill Pro Service Worker v1.0 loaded');
