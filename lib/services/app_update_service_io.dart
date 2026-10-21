import '../services/local_db_service.dart';
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
  const AppUpdateInfo({required this.downloadUrl, required this.sha, this.publishedAt, this.version});
  final String downloadUrl;
  final String sha;

  /// Номер версии «0.N» (растёт на 1 с каждой сборкой); у старых сборок без номера — `null`.
  final String? version;

  /// Когда опубликована новая сборка (для показа даты вместо номера).
  final DateTime? publishedAt;
}

/// Одной кнопкой из настроек — проверить и поставить свежий APK, минуя
/// сторы (сборка и так публикуется в GitHub Releases при каждом пуше
/// без [no-apk], см. .github/workflows/build-apk.yml).
class AppUpdateService {
  static const bool supported = true;
  static const _repo = 'projectsdatabase41-sketch/shooting_app';
  static const _taskId = 'app-update';
  static const _fileName = 'pusl-update.apk';
  static const _metaName = 'pusl-update.json';

  /// Скачанный пакет хранится до установки, но не дольше часа и только один.
  static const keepFor = Duration(hours: 1);
  static String? _pendingSha;

  /// SHA коммита, из которого собран ЭТОТ запущенный APK — встраивается
  /// на этапе сборки (--dart-define=GIT_SHA=...), в локальной/дебажной
  /// сборке пусто.
  static const String currentSha = String.fromEnvironment('GIT_SHA');

  /// Номер ЭТОЙ версии («0.N»), встраивается при сборке (--dart-define=APP_VERSION); локально пусто.
  static const String appVersion = String.fromEnvironment('APP_VERSION');

  /// Только у веб-сборки (см. app_update_service_web.dart) — здесь
  /// обновление и так показывает currentSha/дату релиза через check().
  static const String buildTime = String.fromEnvironment('BUILD_TIME');

  /// `null` — обновлений нет (или сверить не с чем: локальная сборка без
  /// GIT_SHA, либо сеть недоступна — молчим, не тревожим ложной тревогой).
  ///
  /// [strict] — для кнопки «Проверить»: сбой сети/сервера НЕ должен
  /// выглядеть как «у вас последняя версия» (жалоба: после обрыва связи
  /// приложение писало «новых нет»), поэтому бросаем исключение.
  static Future<AppUpdateInfo?> check({bool strict = false}) async {
    if (!Platform.isAndroid || currentSha.isEmpty) return null;
    // 1) Прямая ссылка на version.json рядом с APK — без лимитов api.github.com.
    try {
      final res = await http
          .get(Uri.parse('https://github.com/$_repo/releases/download/latest-apk/version.json'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final info = parseVersionJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>, currentSha, _repo);
        return info;
      }
    } catch (_) {
      // файла ещё нет (сборка до этой правки) или сеть — пробуем API ниже
    }
    // 2) Запасной путь — API релизов.
    try {
      final res = await http
          .get(Uri.parse('https://api.github.com/repos/$_repo/releases/tags/latest-apk'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        if (strict) {
          throw HttpException(res.statusCode == 403 || res.statusCode == 429
              ? tr('GitHub ограничил запросы с вашего адреса (HTTP {c}). Повторите позже или включите VPN.', {'c': res.statusCode})
              : 'HTTP ${res.statusCode}');
        }
        return null;
      }
      return parseRelease(jsonDecode(res.body) as Map<String, dynamic>, currentSha);
    } catch (_) {
      if (strict) rethrow;
      return null;
    }
  }

  /// Разбор version.json: `{"sha": "...", "built": "ISO"}`; `null` — это та же сборка.
  static AppUpdateInfo? parseVersionJson(Map<String, dynamic> j, String currentSha, String repo) {
    final sha = '${j['sha'] ?? ''}';
    if (sha.length < 7 || sha == currentSha) return null;
    return AppUpdateInfo(
      downloadUrl: 'https://github.com/$repo/releases/download/latest-apk/app-release.apk',
      sha: sha,
      publishedAt: DateTime.tryParse('${j['built']}')?.toLocal(),
      version: j['version'] == null ? null : '${j['version']}',
    );
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
    return AppUpdateInfo(
        downloadUrl: url, sha: sha, publishedAt: DateTime.tryParse('${json['published_at']}')?.toLocal());
  }

  static bool _downloaderReady = false;

  /// Уведомление загрузки APK; trackTasks — чтобы загрузка пережила перезапуск приложения.
  /// tapOpensFile: тап по «Готово» сразу открывает установщик.
  static Future<void> _initDownloader() async {
    if (_downloaderReady) return;
    _downloaderReady = true;
    FileDownloader().configureNotificationForGroup(
      'app-update',
      running: TaskNotification(tr('{displayName}'), tr('{progress} · осталось {timeRemaining}')),
      paused: TaskNotification(tr('{displayName}'), tr('Пауза')),
      complete: TaskNotification(tr('{displayName}'), tr('Готово — нажмите, чтобы установить')),
      error: TaskNotification(tr('{displayName}'), tr('Ошибка загрузки')),
      progressBar: true,
      tapOpensFile: true,
    );
    await FileDownloader().trackTasks();
    await FileDownloader().start();
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
  ///
  /// Скачанный и ещё свежий пакет (не старше [keepFor], той же версии [keepSha]) остаётся — его можно
  /// установить без повторной загрузки; устаревший, уже установленный или от другой версии удаляется.
  static Future<void> cleanupStale({String? keepSha}) async {
    try {
      await _initDownloader();
      final active = await FileDownloader().database.recordForId(_taskId);
      final downloading = active != null && (active.status == TaskStatus.running || active.status == TaskStatus.enqueued);
      final meta = await _readMeta();
      final fresh = meta != null &&
          DateTime.now().difference(meta.$2) < keepFor &&
          meta.$1 != currentSha && // уже установлена — пакет не нужен
          (keepSha == null || meta.$1 == keepSha);
      final d = await _dir();
      await for (final f in d.list()) {
        if (f is! File) continue;
        final name = p.basename(f.path);
        if (name == _fileName && (downloading || fresh)) continue;
        if (name == _metaName && fresh) continue;
        if (f.path.endsWith('.apk') || name == _metaName) await f.delete();
      }
    } catch (_) {}
  }

  static Future<(String, DateTime)?> _readMeta() async {
    try {
      final f = File(p.join((await _dir()).path, _metaName));
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final at = DateTime.tryParse('${j['at']}');
      return at == null ? null : ('${j['sha']}', at.toLocal());
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeMeta(String sha) async {
    final f = File(p.join((await _dir()).path, _metaName));
    await f.writeAsString(jsonEncode({'sha': sha, 'at': DateTime.now().toUtc().toIso8601String()}));
  }

  /// Скачанный пакет этой версии, если он есть и не старше часа.
  static Future<File?> _freshPackage(String sha) async {
    final meta = await _readMeta();
    if (meta == null || meta.$1 != sha || DateTime.now().difference(meta.$2) >= keepFor) return null;
    final f = File(p.join((await _dir()).path, _fileName));
    return await f.exists() ? f : null;
  }

  static Future<void> cleanupAfterFailure() async {
    try {
      await FileDownloader().cancelTaskWithId(_taskId);
      await FileDownloader().database.deleteRecordWithId(_taskId);
      final f = File(p.join((await _dir()).path, _fileName));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ---------------- автопроверка раз в сутки ----------------

  static const _kLastCheck = 'update_last_check';
  static const _kNotified = 'update_notified_sha';

  static String? _pref(LocalDbService db, String k) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _setPref(LocalDbService db, String k, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [k, v]);

  /// Не чаще раза в сутки: чистит устаревший пакет и проверяет версию (один маленький запрос к
  /// version.json на GitHub — базы данных не затрагиваются). Есть новая — уведомление с кнопкой
  /// «Обновить» (один раз на версию). Возвращает найденное обновление.
  static Future<AppUpdateInfo?> checkDaily(LocalDbService db, {Future<void> Function(AppUpdateInfo info)? notify}) async {
    if (!Platform.isAndroid || currentSha.isEmpty) return null;
    final last = DateTime.tryParse(_pref(db, _kLastCheck) ?? '');
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) return null;
    _setPref(db, _kLastCheck, DateTime.now().toUtc().toIso8601String());
    await cleanupStale();
    final info = await check();
    if (info != null && notify != null && _pref(db, _kNotified) != info.sha) {
      _setPref(db, _kNotified, info.sha);
      await notify(info);
    }
    return info;
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
    await _initDownloader();
    // Уже скачан и ещё свежий (закрыли уведомление, не нажав «Установить») — ставим тот же файл.
    final ready = await _freshPackage(info.sha);
    if (ready != null) {
      onProgress(1);
      final opened = await FileDownloader().openFile(filePath: ready.path, mimeType: 'application/vnd.android.package-archive');
      if (!opened) throw StateError(tr('Не удалось открыть установщик'));
      return;
    }
    _pendingSha = info.sha;
    final existing = await FileDownloader().database.recordForId(_taskId);
    if (existing != null &&
        (existing.status == TaskStatus.running ||
            existing.status == TaskStatus.enqueued)) {
      return _finishDownload(await _waitFor(_taskId, onProgress));
    }
    // Загрузку прервали (заблокировали телефон, пропала связь) — докачиваем с
    // места остановки, а не начинаем с нуля.
    if (existing != null && existing.task is DownloadTask) {
      var resumed = false;
      try {
        resumed = await FileDownloader().taskCanResume(existing.task) &&
            await FileDownloader().resume(existing.task as DownloadTask);
      } catch (_) {
        // докачка невозможна — ниже обычная загрузка с начала
      }
      if (resumed) return _finishDownload(await _waitFor(_taskId, onProgress));
    }
    await cleanupStale(keepSha: info.sha);
    final task = DownloadTask(
      taskId: _taskId,
      url: info.downloadUrl,
      filename: 'pusl-update.apk',
      baseDirectory: BaseDirectory.applicationSupport,
      directory: 'updates',
      updates: Updates.statusAndProgress,
      // group — своя настройка уведомления (см. _initDownloader), displayName — что показать в нём.
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
      // Если загрузку можно продолжить (сервер отдаёт Range), остаток и запись
      // оставляем: следующее «Обновить» докачает с того же места.
      var canResume = false;
      try {
        canResume = await FileDownloader().taskCanResume(result.task);
      } catch (_) {}
      if (canResume) {
        throw HttpException(tr('Загрузка прервана. Нажмите «Обновить» ещё раз — она продолжится с места остановки.'));
      }
      // Иначе недокачанный файл и запись не оставляем: следующая попытка
      // может упереться в «битый» остаток.
      await cleanupAfterFailure();
      throw HttpException(result.exception?.description ??
          tr('загрузка не удалась ({name})', {'name': result.status.name}));
    }
    final sha = _pendingSha;
    if (sha != null) await _writeMeta(sha); // пакет запомнен: час можно ставить без повторной загрузки
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
