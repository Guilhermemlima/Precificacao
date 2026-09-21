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

/* ---------- notificações ----------
   Este trecho roda mesmo com o app fechado: o navegador acorda o
   service worker só para entregar o aviso. É o que faz a notificação
   chegar no celular, e não apenas dentro da página aberta. */

self.addEventListener('push', function(e){
  var d = {};
  try{ d = e.data ? e.data.json() : {}; }catch(err){ d = {titulo:'Precifica 3D', corpo: e.data ? e.data.text() : ''}; }

  e.waitUntil(
    self.registration.showNotification(d.titulo || 'Precifica 3D', {
      body: d.corpo || '',
      icon: './icons/icon192.png',
      badge: './icons/icon192.png',
      // A marca agrupa avisos do mesmo pedido: uma atualização
      // substitui a anterior em vez de empilhar três notificações.
      tag: d.marca || 'precifica',
      renotify: true,
      data: { url: d.url || './' }
    })
  );
});

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var destino = (e.notification.data && e.notification.data.url) || './';

  // Se o app já estiver aberto em algum lugar, traz aquela janela para
  // frente em vez de abrir uma segunda cópia.
  e.waitUntil(
    self.clients.matchAll({type:'window', includeUncontrolled:true}).then(function(janelas){
      for(var i = 0; i < janelas.length; i++){
        if(janelas[i].url.indexOf(self.location.origin) === 0 && 'focus' in janelas[i]){
          janelas[i].navigate && janelas[i].navigate(destino);
          return janelas[i].focus();
        }
      }
      return self.clients.openWindow(destino);
    })
  );
});
