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

  /// Только у веб-сборки (см. app_update_service_web.dart) — здесь
  /// обновление и так показывает currentSha/дату релиза через check().
  static const String buildTime = '';

  /// `null` — обновлений нет (или сверить не с чем: локальная сборка без
  /// GIT_SHA, либо сеть недоступна — молчим, не тревожим ложной тревогой).
  ///
  /// [strict] — для кнопки «Проверить»: сбой сети/сервера НЕ должен
  /// выглядеть как «у вас последняя версия» (жалоба: после обрыва связи
  /// приложение писало «новых нет»), поэтому бросаем исключение.
  static Future<AppUpdateInfo?> check({bool strict = false}) async {
    if (!Platform.isAndroid || currentSha.isEmpty) return null;
    try {
      final res = await http
          .get(Uri.parse(
              'https://api.github.com/repos/$_repo/releases/tags/latest-apk'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        if (strict) throw HttpException('HTTP ${res.statusCode}');
        return null;
      }
      return parseRelease(
          jsonDecode(res.body) as Map<String, dynamic>, currentSha);
    } catch (_) {
      if (strict) rethrow;
      return null;
    }
  }

  /// Чистый разбор ответа GitHub Releases API — вынесено отдельно ради
  /// теста без сети (см. test/app_update_service_test.dart). Тело релиза —
  /// "Автособрано из <sha>" (build-apk.yml); `null` — апдейта нет (сборка
  /// та же, что установлена, или ответ без нужных полей).
  static AppUpdateInfo? parseRelease(
      Map<String, dynamic> json, String currentSha) {
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
    final d = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'updates'));
    await d.create(recursive: true);
    return d;
  }

  /// Старые скачанные APK этой же папки — с прошлых попыток обновления
  /// (после запуска установщика приложение не может узнать, нажал ли
  /// пользователь «Установить»: заново открывшийся апп удаляет то, что
  /// осталось, при следующей проверке). Идущую сейчас загрузку не трогает.
  static Future<void> cleanupStale() async {
    try {
      final active = await FileDownloader().database.recordForId(_taskId);
      final skip = active != null &&
              (active.status == TaskStatus.running ||
                  active.status == TaskStatus.enqueued)
          ? 'pusl-update.apk'
          : null;
      final d = await _dir();
      await for (final f in d.list()) {
        if (f is File && f.path.endsWith('.apk') && p.basename(f.path) != skip)
          await f.delete();
      }
    } catch (_) {}
  }

  static Future<void> cleanupAfterFailure() async {
    try {
      await FileDownloader().cancelTaskWithId(_taskId);
      await FileDownloader().database.deleteRecordWithId(_taskId);
      final f = File(p.join((await _dir()).path, 'pusl-update.apk'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Уже идёт (в том числе начатая до пересборки экрана — свернули
  /// приложение во время загрузки, вернулись, а виджет «забыл» про неё и
  /// без этой проверки запустил бы вторую загрузку поверх первой,
  /// жалоба пользователя: «прыгает прогресс, будто загрузка двойная»).
  static Future<bool> downloadActive() async {
    final r = await FileDownloader().database.recordForId(_taskId);
    return r != null &&
        (r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
  }

  /// Качает APK и сразу открывает системный установщик поверх него —
  /// подтверждение установки (и один раз — разрешение «Устанавливать из
  /// этого источника») делает сам Android, не приложение. Если загрузка с
  /// тем же taskId уже идёт (например, начата до пересборки экрана) —
  /// подключается к ней, а не начинает новую поверх (жалоба пользователя:
  /// «прыгает прогресс, будто загрузка двойная»); тот же приём, что у
  /// загрузки моделей ИИ.
  static Future<void> downloadAndInstall(
    AppUpdateInfo info, {
    required void Function(double progress) onProgress,
  }) async {
    if (!Platform.isAndroid)
      throw UnsupportedError(tr('Обновление APK доступно только на Android'));
    final existing = await FileDownloader().database.recordForId(_taskId);
    if (existing != null &&
        (existing.status == TaskStatus.running ||
            existing.status == TaskStatus.enqueued)) {
      return _finishDownload(await _waitFor(_taskId, onProgress));
    }
    await cleanupStale();
    final task = DownloadTask(
      taskId: _taskId,
      url: info.downloadUrl,
      filename: 'pusl-update.apk',
      baseDirectory: BaseDirectory.applicationSupport,
      directory: 'updates',
      updates: Updates.statusAndProgress,
      // group — своя настройка уведомления (см. initModelDownloads в
      // local_ai_platform_io.dart), displayName — что показать в нём.
      group: 'app-update',
      displayName: tr('Обновление Nexus'),
      // Обрыв связи — до 5 автоповторов, догрузка с места остановки
      // (сервер релизов отдаёт Range); пауза нужна для докачки.
      retries: 5,
      allowPause: true,
    );
    final result = await FileDownloader()
        .download(task, onProgress: (p) => onProgress(p < 0 ? 0 : p));
    await _finishDownload(
        TaskStatusUpdate(task, result.status, result.exception));
  }

  /// Экран обновления пересобрался (свернули/открыли приложение) — если
  /// загрузка всё это время шла в фоне, подключается к ней вместо
  /// показа "ничего не происходит". `false` — активной загрузки нет,
  /// экран остаётся в обычном состоянии.
  static Future<bool> attachToActiveDownload(
      {required void Function(double progress) onProgress}) async {
    if (!await downloadActive()) return false;
    await _finishDownload(await _waitFor(_taskId, onProgress));
    return true;
  }

  static Future<void> _finishDownload(TaskStatusUpdate result) async {
    if (result.status != TaskStatus.complete) {
      // Недокачанный файл и запись о задаче не оставляем: иначе следующая
      // попытка может упереться в «битый» остаток.
      await cleanupAfterFailure();
      throw HttpException(result.exception?.description ??
          tr('загрузка не удалась ({name})', {'name': result.status.name}));
    }
    final opened = await FileDownloader().openFile(
        task: result.task, mimeType: 'application/vnd.android.package-archive');
    if (!opened) throw StateError(tr('Не удалось открыть установщик'));
  }

  static Future<TaskStatusUpdate> _waitFor(
      String taskId, void Function(double) onProgress) async {
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final r = await FileDownloader().database.recordForId(taskId);
      if (r == null) {
        return TaskStatusUpdate(
          DownloadTask(taskId: taskId, url: '', filename: 'x'),
          TaskStatus.failed,
        );
      }
      if (r.progress >= 0) onProgress(r.progress);
      if (r.status.isFinalState) return TaskStatusUpdate(r.task, r.status);
    }
  }
}
