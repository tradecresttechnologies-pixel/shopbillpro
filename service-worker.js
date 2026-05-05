/* ══════════════════════════════════════════════════════════════════
   ShopBill Pro — Service Worker v1.5.9
   TradeCrest Technologies Pvt. Ltd.
   Offline-first caching strategy

   v1.5.9 changes (Batch 1B-F-Pilot — May 2026):
   - Added mobile drawer (full menu, slides in from right when "More" is tapped)
   - Lib gained mobile-drawer layout: renders ALL items in vertical list with header + footer
   - Mobile users now have access to Website, Services, Appointments, Stylists, History, etc.
   - "More" button on bnav now opens drawer (instead of navigating to settings.html)
   - Drawer has close button, ESC key support, tap-overlay-to-close, body scroll lock
   - Drawer auto-closes on item tap and on viewport crossing to desktop width
   - Lib version: 360 → 445 lines (+85 for drawer support)
   - Dashboard: +18 lines drawer markup + ~60 lines drawer CSS + 3 lines drawer render call
   - All other 15 pages still use their own inline sidebars/bnav — unchanged
   - 1B-C-Scale (rollout drawer + sidebar to remaining 15 pages) is next batch
   - All caching behavior identical to v1.5.8
══════════════════════════════════════════════════════════════════ */

// FIX #20 — Bump version on every release so users get fresh HTML
const CACHE_NAME = 'shopbillpro-v1.5.9-20260505-1bfpilot';
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
  '/marketing.html',
  '/team.html',
  '/subscription.html',
  // Core libs (existing)
  '/lang.js',
  '/scanner.js',
  '/conversion.js',
  '/upgrade-popup.js',
  '/styles.css',
  '/fix.css',
  '/manifest.json',
  // NEW in v1.5.9 — shared libraries (Batch 1A)
  '/lib/sidebar-engine.js',
  '/lib/beta-banner.js',
  '/lib/shop-type-wizard.js',
  // Icons
  '/icons/icon-192x192.png',
  '/icons/icon-512x512.png',
  // External resources
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

  // HTML pages: network-first, fall back to cache, then offline
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

  // All other assets: cache-first
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
