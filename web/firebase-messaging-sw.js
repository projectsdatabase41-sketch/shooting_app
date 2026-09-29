// Service worker для фоновых push-уведомлений чата на вебе (в том
// числе iOS Safari 16.4+ — но ТОЛЬКО когда сайт добавлен на домашний
// экран как приложение, обычная вкладка Safari push не получает).
// Firebase JS SDK сам находит и регистрирует этот файл по
// стандартному пути (см. lib/services/push_service.dart) — вручную
// регистрировать не нужно.
//
// Значения ниже — те же публичные (не секретные) параметры Firebase-
// проекта shooting-app-chat, что и в lib/services/firebase_settings.dart,
// только для веб-приложения отдельно (Firebase выдаёт свой apiKey/appId
// на каждую платформу, см. комментарий в firebase_settings.dart).
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyBTqxnypR4_r36WcULRfyC67z48qtosGwg',
  authDomain: 'shooting-app-chat.firebaseapp.com',
  projectId: 'shooting-app-chat',
  storageBucket: 'shooting-app-chat.firebasestorage.app',
  messagingSenderId: '817306839283',
  appId: '1:817306839283:web:4fc92e4d9bb32d3ad7af86',
});

// Обычные сообщения показываются автоматически по notification-полю
// (см. Edge Function). "Позвать" (msg_type='call') шлётся ДАННЫМИ, без
// notification-поля (см. push_service.dart — на Android это нужно для
// отдельного канала с рингтоном/вибрацией) — на вебе такого канала нет,
// но само уведомление всё равно должно быть видно, поэтому здесь оно
// показывается вручную, простым системным уведомлением браузера.
const messaging = firebase.messaging();
messaging.onBackgroundMessage((payload) => {
  if (payload.data && payload.data.type === 'call') {
    self.registration.showNotification(payload.data.title || 'Звонок', {
      body: payload.data.body || 'Вас вызывают',
      icon: '/icons/Icon-192.png',
    });
  }
});

// ---- Кеш тяжёлой статики сборки (CanvasKit ~7 МБ, main.dart.js ~7 МБ,
// sqlite3.wasm) — без него первый заход на каждое посещение скачивает
// эти файлы заново (жалоба: "тормоза в виде долгой задержки, ждать
// приходится"). Этот же файл, а не отдельный Flutter service worker
// (`--pwa-strategy=offline-first`) — намеренно: Firebase JS SDK сам
// регистрирует ровно ЭТОТ файл под push (см. выше), и второй воркер
// того же scope с ним конфликтовал бы (кто последний зарегистрировался
// — тот и главный, гонка). CACHE_NAME со сборки меняется КАЖДЫЙ деплой
// (подставляется в CI, см. deploy-web.yml) — значит меняются и байты
// файла, браузер это видит и проходит цикл обновления воркера.
// skipWaiting/clients.claim — новый воркер встаёт у руля сразу же, а не
// ждёт закрытия всех вкладок со старой версией (та самая причина, из-за
// которой раньше отключили офлайн-кеш целиком: "Anonymous sign-ins are
// disabled" из-за зависшей старой JS ещё долго после деплоя).
const CACHE_NAME = 'pusl-static-__BUILD_SHA__';
const CACHE_SUFFIXES = [
  'main.dart.js',
  'flutter.js',
  'flutter_bootstrap.js',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'sqlite3.wasm',
];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => Promise.all(
      CACHE_SUFFIXES.map((s) => cache.add(s).catch(() => {})),
    )),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (!CACHE_SUFFIXES.some((s) => url.pathname.endsWith(s))) return;
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
      return res;
    })),
  );
});
