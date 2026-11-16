/* রিসেল হাব: অ্যাপ হিসেবে ইনস্টলের জন্য সার্ভিস ওয়ার্কার। সবসময় আগে নেট থেকে আনে, তাই আপডেট সাথে সাথে আসে। */
const C='rh-v4';
self.addEventListener('install',()=>{self.skipWaiting();});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.method!=='GET'||new URL(r.url).origin!==location.origin)return;
  e.respondWith(fetch(r).then(res=>{if(res.ok){const cp=res.clone();caches.open(C).then(c=>c.put(r,cp));}return res;})
    .catch(()=>caches.match(r).then(m=>m||caches.match('./index.html'))));
});
