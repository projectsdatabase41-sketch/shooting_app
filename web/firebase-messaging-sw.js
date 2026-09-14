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
