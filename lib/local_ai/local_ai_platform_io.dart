import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

/// Скачивание с докачкой: недокачанное лежит в `<path>.part`, обрыв сети
/// или закрытие приложения не теряют уже скачанное.
Future<void> downloadResumable(
  Uri url,
  String path, {
  required void Function(int got, int total) onProgress,
  required bool Function() cancelled,
}) async {
  final part = File('$path.part');
  var have = await part.exists() ? await part.length() : 0;
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    final res = await req.close();
    if (res.statusCode != 416) {
      // 416 — «диапазон за концом файла»: всё уже скачано.
      if (res.statusCode == 200) {
        have = 0; // сервер не умеет докачку — начинаем заново
      } else if (res.statusCode != 206) {
        throw HttpException('Сервер ответил ${res.statusCode}');
      }
      final total = have + (res.contentLength > 0 ? res.contentLength : 0);
      final sink = part.openWrite(mode: have == 0 ? FileMode.write : FileMode.append);
      try {
        await for (final chunk in res) {
          if (cancelled()) throw const DownloadCancelled();
          sink.add(chunk);
          have += chunk.length;
          onProgress(have, total);
        }
      } finally {
        await sink.close();
      }
    }
  } finally {
    client.close(force: true);
  }
  await part.rename(path);
}
