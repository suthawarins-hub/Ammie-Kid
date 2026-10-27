// Cache only the public/static app shell. Never cache Supabase responses, family images or health data.
const CACHE_NAME = 'pmp-public-shell-pwa-v4';
const CACHE_PREFIX = 'pmp-public-shell-';
const SHELL = [
  './', './index.html', './app.js', './config.js', './theme-pastel.css',
  './install-pwa.js', './install-pwa.css', './manifest.webmanifest',
  './icon.svg', './assets/icon.svg', './assets/icon-192.png',
  './assets/icon-512.png', './assets/icon-maskable-512.png', './assets/apple-touch-icon.png'
];
const ALLOWED = new Set(SHELL.map(file => new URL(file, self.registration.scope).pathname));
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(names => Promise.all(names.filter(name =>
    (name.startsWith(CACHE_PREFIX) || name.startsWith('pmp-shell-')) && name !== CACHE_NAME
  ).map(name => caches.delete(name)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin || !ALLOWED.has(url.pathname)) return;
  event.respondWith(fetch(req).then(response => {
    if (response.ok && response.type === 'basic') {
      const copy = response.clone();
      event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.put(req, copy)));
    }
    return response;
  }).catch(async () => (await caches.match(req)) || Response.error()));
});
