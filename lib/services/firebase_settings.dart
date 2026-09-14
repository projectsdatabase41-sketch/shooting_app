/// Настройки Firebase — ТОЛЬКО для push-уведомлений чата (FCM), один
/// проект на всё приложение (тот же принцип, что у ключа OpenRouter или
/// общей базы книг): пользователю свой аккаунт Firebase не нужен.
///
/// `apiKey`/`appId` разные для Android/iOS/веб — Firebase выдаёт их per
/// платформенному приложению внутри одного проекта (`messagingSenderId`
/// и `projectId` общие). Значения без физических файлов
/// (`google-services.json`/`GoogleService-Info.plist`) в проекте —
/// `Firebase.initializeApp` вызывается с явными `FirebaseOptions` (см.
/// `PushService`), поэтому ни сами файлы, ни Gradle-плагин
/// google-services добавлять не нужно.
///
/// Веб — отдельный случай: push там доходит и на iPhone (iOS 16.4+),
/// но ТОЛЬКО если сайт добавлен на домашний экран как приложение
/// ("Добавить на экран Домой" в Safari) — обычная вкладка браузера
/// такого разрешения не получает. Конфиг веб-приложения продублирован
/// в `web/firebase-messaging-sw.js` (service worker, куда Dart-код не
/// достаёт) — при смене здесь поменять и там.
///
/// Откуда брать значения (Project settings → General → Your apps):
/// - apiKey/appId — из google-services.json (Android) или
///   GoogleService-Info.plist (iOS), либо из карточки Web-приложения
///   (веб): API_KEY/GOOGLE_APP_ID там же
/// - messagingSenderId → project_info.project_number (он же GCM_SENDER_ID)
/// - projectId → project_info.project_id
/// - webVapidKey → Project settings → Cloud Messaging → Web
///   configuration → Web Push certificates → Generate key pair
class FirebaseSettings {
  static const String androidApiKey = 'AIzaSyBiZRhBcIh87nBwX5mFCOucuKmQso95XJc';
  static const String androidAppId = '1:817306839283:android:a47d69761a1d8cd2d7af86';
  static const String iosApiKey = 'AIzaSyAVC3QzBmRx62v5BDBX3UNgZ3C2rwqk-WA';
  static const String iosAppId = '1:817306839283:ios:5f53a645d192f172d7af86';
  static const String webApiKey = 'AIzaSyBTqxnypR4_r36WcULRfyC67z48qtosGwg';
  static const String webAppId = '1:817306839283:web:4fc92e4d9bb32d3ad7af86';
  static const String webAuthDomain = 'shooting-app-chat.firebaseapp.com';
  static const String webVapidKey =
      'BEXHkcC8i7AkBsy0BBS_NpWc5JNJ6-3mbXX5XEPldzsElVq5OnRNhSYnNGMm5POLs_wfsdT3yj1cG1SJb-NPymE';
  static const String messagingSenderId = '817306839283';
  static const String projectId = 'shooting-app-chat';

  static bool get isConfigured =>
      androidApiKey.isNotEmpty &&
      androidAppId.isNotEmpty &&
      iosApiKey.isNotEmpty &&
      iosAppId.isNotEmpty &&
      webApiKey.isNotEmpty &&
      webAppId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty;
}
