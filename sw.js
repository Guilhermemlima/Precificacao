/* Service worker do Precifica 3D.
   A página é um arquivo só, então a estratégia é simples:
   - navegação (o HTML): rede primeiro, cache como reserva. Assim uma
     atualização publicada chega na próxima abertura com internet, e o app
     continua abrindo offline com a última versão que funcionou.
   - ícones e manifesto: cache primeiro, que não mudam. */

var CACHE = 'precifica3d-v1';
var ESSENCIAIS = ['./', './index.html', './manifest.webmanifest', './icons/icon192.png', './icons/icon512.png'];

self.addEventListener('install', function(e){
  e.waitUntil(
    caches.open(CACHE)
      .then(function(c){ return c.addAll(ESSENCIAIS); })
      .then(function(){ return self.skipWaiting(); })
      .catch(function(){})
  );
});

self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys()
      .then(function(ks){
        return Promise.all(ks.map(function(k){ return k === CACHE ? null : caches.delete(k); }));
      })
      .then(function(){ return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function(e){
  var req = e.request;
  if(req.method !== 'GET') return;

  var url;
  try{ url = new URL(req.url); }catch(err){ return; }
  if(url.origin !== self.location.origin) return;

  if(req.mode === 'navigate'){
    e.respondWith(
      fetch(req)
        .then(function(res){
          var copia = res.clone();
          caches.open(CACHE).then(function(c){ c.put('./index.html', copia); });
          return res;
        })
        .catch(function(){
          return caches.match('./index.html').then(function(r){ return r || caches.match('./'); });
        })
    );
    return;
  }

  e.respondWith(
    caches.match(req).then(function(hit){
      return hit || fetch(req).then(function(res){
        if(res && res.ok){
          var copia = res.clone();
          caches.open(CACHE).then(function(c){ c.put(req, copia); });
        }
        return res;
      });
    })
  );
});
