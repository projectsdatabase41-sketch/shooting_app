// Получение push-токена на вебе с service worker ПО ПРАВИЛЬНОМУ ПУТИ.
// Firebase SDK по умолчанию регистрирует воркер в корне домена
// (/firebase-messaging-sw.js), а сайт на GitHub Pages лежит в подпапке
// (/<репозиторий>/) — корень отдаёт 404 и токен не получается. Поэтому
// воркер регистрируем сами относительно <base href> и отдаём его SDK.
window.nexusWebPushToken = async function (cfg, vapidKey) {
  const swUrl = new URL('firebase-messaging-sw.js', document.baseURI);
  const scope = new URL('./', document.baseURI).pathname;
  const reg = await navigator.serviceWorker.register(swUrl.href, { scope: scope });
  await navigator.serviceWorker.ready;
  let app;
  try { app = firebase.app('nexus-push'); } catch (_) { app = firebase.initializeApp(cfg, 'nexus-push'); }
  const messaging = firebase.messaging(app);
  // Приложение открыто: FCM сам уведомление не показывает — рисуем его здесь.
  if (!window.__nexusFgPush) {
    window.__nexusFgPush = true;
    messaging.onMessage(function (p) {
      const n = p.notification || {};
      const d = p.data || {};
      const title = n.title || d.title || 'Nexus';
      const body = n.body || d.body || '';
      reg.showNotification(title, { body: body, icon: 'icons/Icon-192.png', data: d });
    });
  }
  return await messaging.getToken({ vapidKey: vapidKey, serviceWorkerRegistration: reg });
};

// Можно ли вообще получить push в этом браузере. На iPhone (iOS 16.4+) push
// работает только у сайта, добавленного на домашний экран и открытого оттуда.
window.nexusPushEnv = function () {
  const ua = navigator.userAgent;
  const ios = /iPhone|iPad|iPod/.test(ua) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const standalone = navigator.standalone === true ||
    (window.matchMedia && matchMedia('(display-mode: standalone)').matches);
  if (ios && !standalone) return 'ios-not-installed';
  if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) return 'unsupported';
  return 'ok';
};

// Запрос разрешения прямо в обработчике нажатия: iOS отклоняет его, если
// между нажатием и запросом были await'ы (Firebase init и т.п.).
window.nexusRequestPermission = function () {
  try { return Notification.requestPermission(); } catch (e) { return Promise.resolve('error: ' + e); }
};
