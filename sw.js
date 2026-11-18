// Eagle Eye: lets the app be installed and opened when the network is poor.
// Always tries the network first, so updates arrive at once; the saved copy is used only offline.
// Requests to other sites (the database) are never cached.
const CACHE='ee-shell-v1';
self.addEventListener('install',e=>{self.skipWaiting();e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['./','./manifest.webmanifest','./icons/icon-192.png'])).catch(()=>{}))});
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==location.origin)return;
 e.respondWith(fetch(e.request).then(r=>{if(r.ok){const cp=r.clone();caches.open(CACHE).then(c=>c.put(e.request.mode==='navigate'?'./':e.request,cp))}return r})
  .catch(()=>caches.match(e.request.mode==='navigate'?'./':e.request).then(m=>m||caches.match('./'))))});
