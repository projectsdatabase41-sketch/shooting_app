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
  return await firebase.messaging(app).getToken({ vapidKey: vapidKey, serviceWorkerRegistration: reg });
};
