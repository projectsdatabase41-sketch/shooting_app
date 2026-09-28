import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../i18n/i18n.dart';

/// [downloadUrl] — прямая ссылка на app-release.apk из GitHub Release;
/// [sha] — коммит, из которого он собран (для показа/логов).
class AppUpdateInfo {
  const AppUpdateInfo({required this.downloadUrl, required this.sha});
  final String downloadUrl;
  final String sha;
}

/// Одной кнопкой из настроек — проверить и поставить свежий APK, минуя
/// сторы (сборка и так публикуется в GitHub Releases при каждом пуше
/// без [no-apk], см. .github/workflows/build-apk.yml).
class AppUpdateService {
  static const bool supported = true;
  static const _repo = 'projectsdatabase41-sketch/shooting_app';
  static const _taskId = 'app-update';

  /// SHA коммита, из которого собран ЭТОТ запущенный APK — встраивается
  /// на этапе сборки (--dart-define=GIT_SHA=...), в локальной/дебажной
  /// сборке пусто.
  static const String currentSha = String.fromEnvironment('GIT_SHA');

  /// `null` — обновлений нет (или сверить не с чем: локальная сборка без
  /// GIT_SHA, либо сеть недоступна — молчим, не тревожим ложной тревогой).
  static Future<AppUpdateInfo?> check() async {
    if (!Platform.isAndroid || currentSha.isEmpty) return null;
    try {
      final res = await http
          .get(Uri.parse('https://api.github.com/repos/$_repo/releases/tags/latest-apk'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      return parseRelease(jsonDecode(res.body) as Map<String, dynamic>, currentSha);
    } catch (_) {
      return null;
    }
  }

  /// Чистый разбор ответа GitHub Releases API — вынесено отдельно ради
  /// теста без сети (см. test/app_update_service_test.dart). Тело релиза —
  /// "Автособрано из <sha>" (build-apk.yml); `null` — апдейта нет (сборка
  /// та же, что установлена, или ответ без нужных полей).
  static AppUpdateInfo? parseRelease(Map<String, dynamic> json, String currentSha) {
    final sha = RegExp(r'[0-9a-f]{40}').firstMatch('${json['body']}')?.group(0);
    if (sha == null || sha == currentSha) return null;
    final assets = (json['assets'] as List?) ?? const [];
    String? url;
    for (final a in assets) {
      final m = a as Map<String, dynamic>;
      if ('${m['name']}'.endsWith('.apk')) {
        url = '${m['browser_download_url']}';
        break;
      }
    }
    if (url == null || url.isEmpty) return null;
    return AppUpdateInfo(downloadUrl: url, sha: sha);
  }

  static Future<Directory> _dir() async {
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'updates'));
    await d.create(recursive: true);
    return d;
  }

  /// Старые скачанные APK этой же папки — с прошлых попыток обновления
  /// (после запуска установщика приложение не может узнать, нажал ли
  /// пользователь «Установить»: заново открывшийся апп удаляет то, что
  /// осталось, при следующей проверке).
  static Future<void> cleanupStale() async {
    try {
      final d = await _dir();
      await for (final f in d.list()) {
        if (f is File && f.path.endsWith('.apk')) await f.delete();
      }
    } catch (_) {}
  }

  /// Качает APK и сразу открывает системный установщик поверх него —
  /// подтверждение установки (и один раз — разрешение «Устанавливать из
  /// этого источника») делает сам Android, не приложение.
  static Future<void> downloadAndInstall(
    AppUpdateInfo info, {
    required void Function(double progress) onProgress,
  }) async {
    if (!Platform.isAndroid) throw UnsupportedError('Обновление APK доступно только на Android');
    await cleanupStale();
    final task = DownloadTask(
      taskId: _taskId,
      url: info.downloadUrl,
      filename: 'pusl-update.apk',
      baseDirectory: BaseDirectory.applicationSupport,
      directory: 'updates',
      updates: Updates.statusAndProgress,
    );
    final result = await FileDownloader().download(task, onProgress: (p) => onProgress(p < 0 ? 0 : p));
    if (result.status != TaskStatus.complete) {
      throw HttpException(result.exception?.description ?? tr('загрузка не удалась ({name})', {'name': result.status.name}));
    }
    final opened = await FileDownloader().openFile(task: task, mimeType: 'application/vnd.android.package-archive');
    if (!opened) throw StateError(tr('Не удалось открыть установщик'));
  }
}
