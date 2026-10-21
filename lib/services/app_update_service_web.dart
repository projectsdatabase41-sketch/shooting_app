/// Заглушка для веба — обновление одной кнопкой имеет смысл только для APK.
import 'local_db_service.dart';
import '../i18n/i18n.dart';

class AppUpdateInfo {
  const AppUpdateInfo({required this.downloadUrl, required this.sha, this.publishedAt, this.version});
  final String? version;
  final DateTime? publishedAt;
  final String downloadUrl;
  final String sha;
}

class AppUpdateService {
  static const bool supported = false;
  static const String currentSha = '';
  static const String appVersion = String.fromEnvironment('APP_VERSION');
  static Future<List<AppUpdateInfo>> previousVersions() async => const [];
  static void skipNotifying(LocalDbService db, String sha) {}

  /// Время сборки (ISO 8601, UTC) — подставляется в CI при деплое на
  /// GitHub Pages (--dart-define=BUILD_TIME), в локальной сборке пусто.
  /// Обновлений одной кнопкой на вебе нет (сайт и так всегда последняя
  /// версия — см. кеш в firebase-messaging-sw.js), но время сборки
  /// полезно, чтобы свериться, что кеш не отдаёт старое.
  static const String buildTime = String.fromEnvironment('BUILD_TIME');

  static Future<AppUpdateInfo?> check({bool strict = false}) async => null;
  static Future<bool> downloadActive() async => false;
  static Future<void> cleanupStale({String? keepSha}) async {}
  static Future<AppUpdateInfo?> checkDaily(LocalDbService db, {Future<void> Function(AppUpdateInfo info)? notify}) async => null;
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
