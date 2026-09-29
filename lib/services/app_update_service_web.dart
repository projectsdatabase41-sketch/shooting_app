/// Заглушка для веба — обновление одной кнопкой имеет смысл только для APK.
class AppUpdateInfo {
  const AppUpdateInfo({required this.downloadUrl, required this.sha});
  final String downloadUrl;
  final String sha;
}

class AppUpdateService {
  static const bool supported = false;
  static const String currentSha = '';

  static Future<AppUpdateInfo?> check() async => null;
  static Future<bool> downloadActive() async => false;
  static Future<bool> attachToActiveDownload({required void Function(double progress) onProgress}) async => false;

  static Future<void> downloadAndInstall(
    AppUpdateInfo info, {
    required void Function(double progress) onProgress,
  }) async {
    throw UnsupportedError('Обновление APK доступно только на Android');
  }
}
