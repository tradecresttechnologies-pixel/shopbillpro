/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Service Worker v1.3.0
   TradeCrest Technologies Pvt. Ltd.
   Offline-first caching strategy
══════════════════════════════════════════════════════════════════ */

// FIX #20 — Bump version on every release so users get fresh HTML
const CACHE_NAME = 'shopbillpro-v1.3.0-20260427';
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
  // FIX #19 — These were missing
  '/marketing.html',
  '/team.html',
  '/subscription.html',
  '/lang.js',
  '/scanner.js',
  '/conversion.js',
  '/upgrade-popup.js',
  '/styles.css',
  '/fix.css',
  '/manifest.json',
  '/icons/icon-192x192.png',
  '/icons/icon-512x512.png',
  'https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700;800;900&family=Noto+Sans:wght@300;400;500;600;700&family=Noto+Sans+Devanagari:wght@400;500;600;700&display=swap',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js',
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return Promise.allSettled(
        STATIC_ASSETS.map(url => cache.add(url).catch(e => console.warn('[SW] cache fail:', url)))
      );
    }).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== 'GET') return;
  if (url.hostname.includes('supabase.co')) return;
  if (!url.protocol.startsWith('http')) return;

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

  event.respondWith(
    caches.match(request).then(cached => {
      if (cached) return cached;
      return fetch(request).then(response => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, clone));
        }
        return response;
      }).catch(() => null);
    })
  );
});

self.addEventListener('message', event => {
  if (event.data === 'skipWaiting') self.skipWaiting();
});
