/// Настройки Firebase — ТОЛЬКО для push-уведомлений чата (FCM), один
/// проект на всё приложение (тот же принцип, что у ключа OpenRouter или
/// общей базы книг): пользователю свой аккаунт Firebase не нужен.
///
/// `apiKey`/`appId` разные для Android и iOS — Firebase выдаёт их per
/// платформенному приложению внутри одного проекта (`messagingSenderId`
/// и `projectId` общие). Значения без физических файлов
/// (`google-services.json`/`GoogleService-Info.plist`) в проекте —
/// `Firebase.initializeApp` вызывается с явными `FirebaseOptions` (см.
/// `PushService`), поэтому ни сами файлы, ни Gradle-плагин
/// google-services добавлять не нужно.
///
/// Откуда брать значения (Project settings → General → Your apps):
/// - apiKey/appId — из google-services.json (Android) или
///   GoogleService-Info.plist (iOS): API_KEY/GOOGLE_APP_ID там же
/// - messagingSenderId → project_info.project_number (он же GCM_SENDER_ID)
/// - projectId → project_info.project_id
class FirebaseSettings {
  static const String androidApiKey = 'AIzaSyBiZRhBcIh87nBwX5mFCOucuKmQso95XJc';
  static const String androidAppId = '1:817306839283:android:a47d69761a1d8cd2d7af86';
  static const String iosApiKey = 'AIzaSyAVC3QzBmRx62v5BDBX3UNgZ3C2rwqk-WA';
  static const String iosAppId = '1:817306839283:ios:5f53a645d192f172d7af86';
  static const String messagingSenderId = '817306839283';
  static const String projectId = 'shooting-app-chat';

  static bool get isConfigured =>
      androidApiKey.isNotEmpty &&
      androidAppId.isNotEmpty &&
      iosApiKey.isNotEmpty &&
      iosAppId.isNotEmpty &&
      messagingSenderId.isNotEmpty &&
      projectId.isNotEmpty;
}
