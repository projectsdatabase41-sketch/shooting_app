/// Настройки Firebase — ТОЛЬКО для push-уведомлений чата (FCM), одна
/// на всё приложение (тот же принцип, что у ключа OpenRouter или общей
/// базы книг): пользователю свой аккаунт Firebase не нужен.
///
/// ПОКА пустые строки — проект ещё не создан. Значения берутся из
/// `google-services.json`, который выдаёт Firebase Console при
/// добавлении Android-приложения (Project settings → General →
/// Your apps), без физического файла в проекте: `Firebase.initializeApp`
/// вызывается с явными `FirebaseOptions` (см. `PushService`), поэтому
/// ни сам JSON-файл, ни Gradle-плагин google-services в проект
/// добавлять не нужно.
///
/// Откуда брать значения из google-services.json:
/// - apiKey            → client[0].api_key[0].current_key
/// - appId             → client[0].client_info.mobilesdk_app_id
/// - messagingSenderId → project_info.project_number
/// - projectId         → project_info.project_id
class FirebaseSettings {
  static const String apiKey = 'AIzaSyBiZRhBcIh87nBwX5mFCOucuKmQso95XJc';
  static const String appId = '1:817306839283:android:a47d69761a1d8cd2d7af86';
  static const String messagingSenderId = '817306839283';
  static const String projectId = 'shooting-app-chat';

  static bool get isConfigured => apiKey.isNotEmpty && appId.isNotEmpty && messagingSenderId.isNotEmpty && projectId.isNotEmpty;
}
