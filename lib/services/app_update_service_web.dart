/// Заглушка для веба — обновление одной кнопкой имеет смысл только для APK.
import '../i18n/i18n.dart';

class AppUpdateInfo {
  const AppUpdateInfo({required this.downloadUrl, required this.sha});
  final String downloadUrl;
  final String sha;
}

class AppUpdateService {
  static const bool supported = false;
  static const String currentSha = '';

  /// Время сборки (ISO 8601, UTC) — подставляется в CI при деплое на
  /// GitHub Pages (--dart-define=BUILD_TIME), в локальной сборке пусто.
  /// Обновлений одной кнопкой на вебе нет (сайт и так всегда последняя
  /// версия — см. кеш в firebase-messaging-sw.js), но время сборки
  /// полезно, чтобы свериться, что кеш не отдаёт старое.
  static const String buildTime = String.fromEnvironment('BUILD_TIME');

  static Future<AppUpdateInfo?> check() async => null;
  static Future<bool> downloadActive() async => false;
  static Future<bool> attachToActiveDownload(
          {required void Function(double progress) onProgress}) async =>
      false;

  static Future<void> downloadAndInstall(
    AppUpdateInfo info, {
    required void Function(double progress) onProgress,
  }) async {
    throw UnsupportedError(tr('Обновление APK доступно только на Android'));
  }
}
