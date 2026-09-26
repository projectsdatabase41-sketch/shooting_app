import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../i18n/i18n.dart';

final bool localAiSupported = Platform.isAndroid || Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

Future<String> modelsDir() async {
  final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'models'));
  await d.create(recursive: true);
  return d.path;
}

/// Общий объём ОЗУ — чтобы подсказать, какая модель потянет.
Future<int?> totalRamBytes() async {
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      final m = RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(await File('/proc/meminfo').readAsString());
      return m == null ? null : int.parse(m.group(1)!) * 1024;
    }
    if (Platform.isWindows) {
      final r = await Process.run(
          'powershell', ['-NoProfile', '-Command', '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory']);
      return int.tryParse('${r.stdout}'.trim());
    }
  } catch (_) {}
  return null;
}

/// Свободное место на диске; `null` — узнать не удалось.
Future<int?> freeDiskBytes(String dir) async {
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      final r = await Process.run('df', ['-k', dir]);
      final cols = '${r.stdout}'.trim().split('\n').last.split(RegExp(r'\s+'));
      return int.parse(cols[3]) * 1024;
    }
    if (Platform.isWindows) {
      final drive = p.rootPrefix(dir).replaceAll(RegExp(r'[:\\/]'), '');
      final r = await Process.run('powershell', ['-NoProfile', '-Command', '(Get-PSDrive $drive).Free']);
      return int.tryParse('${r.stdout}'.trim());
    }
  } catch (_) {}
  return null;
}

int fileLength(String path) {
  final f = File(path);
  return f.existsSync() ? f.lengthSync() : 0;
}

/// Удаляет модель вместе с недокачанным хвостом.
Future<void> deleteFile(String path) async {
  for (final f in [File(path), File('$path.part')]) {
    if (await f.exists()) await f.delete();
  }
}

/// SHA-256 в отдельном изоляте — файл до 5 ГБ, интерфейс не должен вставать.
Future<String> sha256OfFile(String path) =>
    Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());

/// Системный фоновый загрузчик: уведомление с прогрессом, продолжает
/// качать после закрытия приложения, сам возобновляется после обрыва сети
/// или лимита Android (allowPause). Вызвать один раз при запуске.
bool _downloadsReady = false;

Future<void> initModelDownloads() async {
  if (_downloadsReady) return;
  _downloadsReady = true;
  // Без уведомлений в шторке (решение пользователя: две строки прыгали
  // местами). Прогресс виден на экране «Локальная модель»; паузу
  // Android по таймауту загрузчик снимает сам.
  // trackTasks — чтобы состояние загрузки пережило перезапуск приложения.
  await FileDownloader().trackTasks();
  await FileDownloader().start();
}

DownloadTask _task(String id, String url, String fileName, String displayName) => DownloadTask(
      taskId: 'model-$id',
      url: url,
      filename: fileName,
      baseDirectory: BaseDirectory.applicationSupport,
      directory: 'models',
      displayName: displayName,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 10,
    );

/// Скачивает модель в папку [modelsDir]. Если загрузка уже идёт в фоне
/// (например, начата до перезапуска приложения) — подключается к ней.
/// Бросает [DownloadCancelled] при паузе/отмене, исключение — при ошибке.
Future<void> downloadModel({
  required String id,
  required String url,
  required String fileName,
  required String displayName,
  required void Function(double progress) onProgress,
}) async {
  await initModelDownloads();
  final task = _task(id, url, fileName, displayName);
  final existing = await FileDownloader().database.recordForId(task.taskId);
  TaskStatusUpdate result;
  if (existing != null && existing.status == TaskStatus.paused) {
    await FileDownloader().resume(existing.task as DownloadTask);
    result = await _waitFor(task.taskId, onProgress);
  } else if (existing != null && (existing.status == TaskStatus.running || existing.status == TaskStatus.enqueued)) {
    result = await _waitFor(task.taskId, onProgress);
  } else {
    result = await FileDownloader().download(task, onProgress: (p) => onProgress(p < 0 ? 0 : p));
  }
  // Пауза не от пользователя — это Android оборвал долгую фоновую загрузку
  // (лимит ~9 минут); загрузчик продолжает её сам. Раньше это сразу
  // показывалось как «Загрузка приостановлена», хотя файл качался дальше.
  var pausedSince = DateTime.now();
  _userPaused.remove(task.taskId);
  while (result.status == TaskStatus.paused && !_userPaused.contains(task.taskId)) {
    if (DateTime.now().difference(pausedSince) > const Duration(minutes: 1)) {
      final r = await FileDownloader().database.recordForId(task.taskId);
      if (r != null && r.status == TaskStatus.paused) await FileDownloader().resume(r.task as DownloadTask);
      pausedSince = DateTime.now();
    }
    result = await _waitFor(task.taskId, onProgress);
    if (result.status != TaskStatus.paused) pausedSince = DateTime.now();
  }
  switch (result.status) {
    case TaskStatus.complete:
      return;
    case TaskStatus.paused:
    case TaskStatus.canceled:
      throw const DownloadCancelled();
    default:
      throw HttpException(result.exception?.description ?? tr('загрузка не удалась ({name})', {'name': result.status.name}));
  }
}

/// Ждёт окончания уже идущей фоновой загрузки, опрашивая её запись.
Future<TaskStatusUpdate> _waitFor(String taskId, void Function(double) onProgress) async {
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final r = await FileDownloader().database.recordForId(taskId);
    if (r == null) return TaskStatusUpdate(_task('x', '', '', ''), TaskStatus.failed);
    if (r.progress >= 0) onProgress(r.progress);
    if (r.status.isFinalState || r.status == TaskStatus.paused) return TaskStatusUpdate(r.task, r.status);
  }
}

/// Паузы, которые поставил сам пользователь (кнопкой), — их не продолжаем сами.
final Set<String> _userPaused = {};

/// Пауза фоновой загрузки (продолжится с того же места).
Future<void> pauseModelDownload(String id) async {
  _userPaused.add('model-$id');
  await initModelDownloads();
  final r = await FileDownloader().database.recordForId('model-$id');
  if (r != null) await FileDownloader().pause(r.task as DownloadTask);
}

/// Идёт ли сейчас загрузка этой модели (в том числе начатая до перезапуска).
Future<bool> modelDownloadActive(String id) async {
  await initModelDownloads();
  final r = await FileDownloader().database.recordForId('model-$id');
  return r != null && (r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
}
