import '../services/secret_box.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;

import '../services/local_db_service.dart';

/// Папка или файл на Google Диске (по ответу моста docs/gdrive-script.gs).
class DriveItem {
  final String id;
  final String name;
  final String mime;
  final int size;
  final DateTime modified;
  final String url;
  final bool isFolder;

  const DriveItem({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.modified,
    required this.url,
    required this.isFolder,
  });

  factory DriveItem.fromJson(Map<String, dynamic> j) => DriveItem(
        id: '${j['id']}',
        name: '${j['name']}',
        mime: '${j['mime']}',
        size: (j['size'] as num?)?.toInt() ?? 0,
        modified: DateTime.fromMillisecondsSinceEpoch((j['modified'] as num?)?.toInt() ?? 0),
        url: '${j['url'] ?? ''}',
        isFolder: j['isFolder'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mime': mime,
        'size': size,
        'modified': modified.millisecondsSinceEpoch,
        'url': url,
        'isFolder': isFolder,
      };

  bool get isImage => mime.startsWith('image/');
  bool get isText => mime.startsWith('text/') || const {'application/json', 'application/xml'}.contains(mime);
}

class DriveListing {
  final String id;
  final String name;
  final String? parent;
  final List<DriveItem> folders;
  final List<DriveItem> files;

  /// Время последнего изменения самой папки (мс) на момент загрузки — по нему находят обновлённое.
  final int stamp;
  const DriveListing({required this.id, required this.name, this.parent, required this.folders, required this.files, this.stamp = 0});

  factory DriveListing.fromJson(Map<String, dynamic> d) => DriveListing(
        id: '${d['id']}',
        name: '${d['name']}',
        stamp: (d['stamp'] as num?)?.toInt() ?? 0,
        parent: d['parent'] as String?,
        folders: [for (final f in (d['folders'] as List)) DriveItem.fromJson(f as Map<String, dynamic>)],
        files: [for (final f in (d['files'] as List)) DriveItem.fromJson(f as Map<String, dynamic>)],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'stamp': stamp,
        'parent': parent,
        'folders': [for (final f in folders) f.toJson()],
        'files': [for (final f in files) f.toJson()],
      };
}

class DriveFile {
  final String name;
  final String mime;
  final Uint8List bytes;
  final String url;
  const DriveFile({required this.name, required this.mime, required this.bytes, required this.url});
}

class GDriveException implements Exception {
  final String message;
  GDriveException(this.message);
  @override
  String toString() => message;
}

/// Клиент моста к Google Диску пользователя: веб-приложение Google Apps Script
/// (docs/gdrive-script.gs), выполняющееся от имени самого пользователя. Адрес и пароль моста
/// хранятся только на устройстве.
class GDriveService {
  static const _urlKey = 'gdrive_url';
  static const _secretKey = 'gdrive_secret';
  static const chunkBytes = 3 * 1024 * 1024;

  final LocalDbService db;
  final http.Client Function() clientFactory;

  GDriveService(this.db, {http.Client Function()? clientFactory}) : clientFactory = clientFactory ?? http.Client.new;

  static String? _get(LocalDbService db, String key) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(LocalDbService db, String key, String v) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [key, v]);

  static String get _empty => '';
  static String url(LocalDbService db) => _get(db, _urlKey) ?? _empty;
  static String secret(LocalDbService db) => SecretBox.open(_get(db, _secretKey) ?? _empty);
  static bool configured(LocalDbService db) => url(db).startsWith('https://') && secret(db).isNotEmpty;

  static void save(LocalDbService db, {required String url, required String secret}) {
    _put(db, _urlKey, url.trim());
    _put(db, _secretKey, SecretBox.seal(secret.trim()));
  }

  static void disconnect(LocalDbService db) {
    _put(db, _urlKey, '');
    _put(db, _secretKey, '');
    clearCache(db);
  }

  // ---- Локальный кэш списков папок: интерфейс открывается мгновенно, обновление — в фоне ----
  static const _cachePrefix = 'gdrive_f:';
  static const _indexedKey = 'gdrive_indexed_at';

  static DriveListing? cached(LocalDbService db, String folderId) {
    final v = _get(db, '$_cachePrefix$folderId');
    if (v == null || v.isEmpty) return null;
    try {
      return DriveListing.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static void _cachePut(LocalDbService db, String folderId, DriveListing l) =>
      _put(db, '$_cachePrefix$folderId', jsonEncode(l.toJson()));

  static void clearCache(LocalDbService db) {
    db.db.execute("DELETE FROM color_prefs WHERE key LIKE '$_cachePrefix%' OR key = '$_indexedKey'");
  }

  /// Помечает индекс устаревшим: следующая синхронизация пройдёт заново (уже скачанные папки возьмёт из кэша только при прерывании).
  static void markIndexStale(LocalDbService db) => db.db.execute("DELETE FROM color_prefs WHERE key = '$_indexedKey'");

  static DateTime? indexedAt(LocalDbService db) => DateTime.tryParse(_get(db, _indexedKey) ?? '')?.toLocal();

  /// Поиск по названию в локальном индексе (все закэшированные папки). Мгновенно, без сети.
  static List<DriveItem> searchCached(LocalDbService db, String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final out = <DriveItem>[];
    final seen = <String>{};
    for (final r in db.db.select("SELECT hex FROM color_prefs WHERE key LIKE '$_cachePrefix%'")) {
      try {
        final l = DriveListing.fromJson(jsonDecode('${r['hex']}') as Map<String, dynamic>);
        for (final it in [...l.folders, ...l.files]) {
          if (it.name.toLowerCase().contains(needle) && seen.add(it.id)) out.add(it);
        }
      } catch (_) {}
    }
    return out;
  }

  /// Один вызов моста. Apps Script отвечает на POST переадресацией (302) на страницу с
  /// результатом — её нужно открыть отдельным GET.
  Future<dynamic> _call(String action, [Map<String, dynamic> payload = const {}]) async {
    if (!configured(db)) throw GDriveException('Google Диск не подключён');
    final client = clientFactory();
    try {
      final req = http.Request('POST', Uri.parse(url(db)))
        ..followRedirects = false
        // text/plain — «простой» запрос без предварительной проверки CORS (важно для веба).
        ..headers['Content-Type'] = 'text/plain;charset=utf-8'
        ..body = jsonEncode({'secret': secret(db), 'action': action, ...payload});
      var res = await http.Response.fromStream(await client.send(req).timeout(const Duration(seconds: 60)));
      var hops = 0;
      while ((res.statusCode == 301 || res.statusCode == 302 || res.statusCode == 303 || res.statusCode == 307 || res.statusCode == 308) &&
          res.headers['location'] != null &&
          hops++ < 5) {
        res = await client.get(Uri.parse(res.headers['location']!)).timeout(const Duration(seconds: 60));
      }
      if (res.statusCode != 200) throw GDriveException('Google Диск: код ${res.statusCode}');
      final Map<String, dynamic> body;
      try {
        body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      } catch (_) {
        throw GDriveException('Мост вернул не тот ответ: проверьте адрес и доступ «Все» в развёртывании');
      }
      if (body['ok'] != true) {
        final e = '${body['error']}';
        throw GDriveException(e == 'unauthorized' ? 'Неверный пароль моста' : (e == 'Error: too large' || e.contains('too large') ? 'Файл слишком большой для открытия здесь' : e));
      }
      return body['data'];
    } finally {
      client.close();
    }
  }

  Future<String> ping() async => '${(await _call('ping') as Map)['root']}';

  /// Список папки с сервера; результат кладётся в локальный кэш.
  Future<DriveListing> list([String folderId = 'root']) async {
    final l = DriveListing.fromJson(await _call('list', {'folderId': folderId}) as Map<String, dynamic>);
    _cachePut(db, folderId, l);
    if (folderId != l.id) _cachePut(db, l.id, l);
    return l;
  }

  /// Все закэшированные папки: id -> список.
  static Map<String, DriveListing> _allCached(LocalDbService db) {
    final out = <String, DriveListing>{};
    for (final r in db.db.select("SELECT key, hex FROM color_prefs WHERE key LIKE '$_cachePrefix%'")) {
      try {
        out['${r['key']}'.substring(_cachePrefix.length)] = DriveListing.fromJson(jsonDecode('${r['hex']}') as Map<String, dynamic>);
      } catch (_) {}
    }
    return out;
  }

  /// Скачивает структуру всего Диска (только названия и ссылки, без файлов) в кэш: папки потом
  /// открываются мгновенно. Идёт пакетами по [batch] папок; старый скрипт без пакетного вызова
  /// обслуживается по одной папке. [onProgress] — (сделано папок, всего известно на сейчас).
  Future<int> syncIndex({void Function(int done, int total)? onProgress, int batch = 20, bool Function()? cancelled}) async {
    // Прерванный раньше индекс (нет отметки «готов») продолжается, а не начинается заново.
    final resume = indexedAt(db) == null;
    final n = await _crawl(['root'], onProgress: onProgress, batch: batch, cancelled: cancelled, skipKnown: false, resume: resume);
    if (cancelled?.call() != true) _put(db, _indexedKey, DateTime.now().toUtc().toIso8601String());
    return n;
  }

  /// Быстрое обновление: спрашивает у скрипта только времена изменения закэшированных папок,
  /// перечитывает изменившиеся и новые, убирает исчезнувшие. Нет индекса или скрипт старый —
  /// полный [syncIndex]. Раз в сутки полный индекс всё равно нужен (страховка).
  Future<int> syncChanges({void Function(int done, int total)? onProgress, bool Function()? cancelled}) async {
    if (indexedAt(db) == null) return syncIndex(onProgress: onProgress, cancelled: cancelled);
    final cache = _allCached(db);
    if (cache.isEmpty) return syncIndex(onProgress: onProgress, cancelled: cancelled);
    final ids = cache.keys.toList();
    final changed = <String>[];
    var checked = 0;
    for (var i = 0; i < ids.length; i += 200) {
      if (cancelled?.call() == true) return 0;
      final part = ids.sublist(i, i + 200 > ids.length ? ids.length : i + 200);
      final Map<String, dynamic> st;
      try {
        st = await _call('stamps', {'ids': part}) as Map<String, dynamic>;
      } on GDriveException catch (e) {
        if ('$e'.contains('unknown action')) return syncIndex(onProgress: onProgress, cancelled: cancelled);
        rethrow;
      }
      for (final id in part) {
        final now = (st[id] as num?)?.toInt();
        if (now == null) {
          _remove(db, id); // папки больше нет
        } else if (now != cache[id]!.stamp) {
          changed.add(id);
        }
      }
      checked += part.length;
      onProgress?.call(checked, ids.length);
    }
    if (changed.isEmpty) {
      _pruneUnreachable(db);
      return 0;
    }
    final n = await _crawl(changed, onProgress: onProgress, cancelled: cancelled, skipKnown: true);
    _pruneUnreachable(db);
    return n;
  }

  static void _remove(LocalDbService db, String id) => db.db.execute('DELETE FROM color_prefs WHERE key = ?', ['$_cachePrefix$id']);

  /// Удаляет из кэша папки, до которых больше нет пути от корня (удалены или перемещены в корзину).
  static void _pruneUnreachable(LocalDbService db) {
    final cache = _allCached(db);
    final root = cache['root'];
    if (root == null) return;
    final seen = <String>{root.id, 'root'};
    final stack = [root];
    while (stack.isNotEmpty) {
      final l = stack.removeLast();
      for (final f in l.folders) {
        final c = cache[f.id];
        if (c != null && seen.add(c.id)) stack.add(c);
      }
    }
    for (final id in cache.keys) {
      if (!seen.contains(id) && !seen.contains(cache[id]!.id)) _remove(db, id);
    }
  }

  Future<int> _crawl(List<String> start,
      {void Function(int done, int total)? onProgress, int batch = 20, bool Function()? cancelled, required bool skipKnown, bool resume = false}) async {
    final queue = <String>[...start];
    final done = <String>{};
    var batchMode = true;
    while (queue.isNotEmpty) {
      if (cancelled?.call() == true) return done.length;
      final ids = <String>[];
      final fromCache = <String, DriveListing>{};
      while (queue.isNotEmpty && ids.length < (batchMode ? batch : 1)) {
        final id = queue.removeLast();
        if (!done.add(id)) continue;
        // Продолжение прерванного индекса: что уже скачано — берём из кэша, сеть не трогаем.
        final c = resume ? cached(db, id) : null;
        if (c != null) {
          fromCache[id] = c;
        } else {
          ids.add(id);
        }
      }
      if (fromCache.isNotEmpty) {
        for (final l in fromCache.values) {
          for (final f in l.folders) {
            if (!done.contains(f.id)) queue.add(f.id);
          }
        }
        onProgress?.call(done.length, done.length + queue.length);
      }
      if (ids.isEmpty) continue;
      final listings = <String, DriveListing?>{};
      if (batchMode) {
        try {
          final d = await _call('listMany', {'ids': ids}) as Map<String, dynamic>;
          for (final e in d.entries) {
            listings[e.key] = e.value == null ? null : DriveListing.fromJson(e.value as Map<String, dynamic>);
          }
          // пакет мог оборваться по времени — недоданные вернём в очередь
          for (final id in ids) {
            if (!listings.containsKey(id)) {
              done.remove(id);
              queue.add(id);
            }
          }
        } on GDriveException catch (e) {
          if (!'$e'.contains('unknown action')) rethrow;
          batchMode = false; // скрипт не обновлён: по одной папке
          for (final id in ids) {
            done.remove(id);
            queue.add(id);
          }
          continue;
        }
      } else {
        try {
          listings[ids.first] = DriveListing.fromJson(await _call('list', {'folderId': ids.first}) as Map<String, dynamic>);
        } catch (_) {
          listings[ids.first] = null;
        }
      }
      for (final e in listings.entries) {
        final l = e.value;
        if (l == null) {
          _remove(db, e.key);
          continue;
        }
        _cachePut(db, e.key, l);
        if (e.key != l.id) _cachePut(db, l.id, l);
        for (final f in l.folders) {
          if (done.contains(f.id)) continue;
          if (skipKnown && cached(db, f.id) != null) continue;
          queue.add(f.id);
        }
      }
      onProgress?.call(done.length, done.length + queue.length);
    }
    return done.length;
  }

  Future<List<DriveItem>> search(String q) async {
    final d = await _call('search', {'q': q}) as Map<String, dynamic>;
    return [
      for (final f in (d['folders'] as List)) DriveItem.fromJson(f as Map<String, dynamic>),
      for (final f in (d['files'] as List)) DriveItem.fromJson(f as Map<String, dynamic>),
    ];
  }

  Future<DriveFile> get(String id) async {
    final d = await _call('get', {'id': id}) as Map<String, dynamic>;
    return DriveFile(name: '${d['name']}', mime: '${d['mime']}', bytes: base64Decode('${d['b64']}'), url: '${d['url']}');
  }

  /// Загружает файл; крупнее [chunkBytes] — частями. [overwriteId] — заменить существующий.
  Future<DriveItem> put(String parentId, String name, String mime, List<int> bytes, {String? overwriteId}) async {
    if (bytes.length <= chunkBytes) {
      final d = await _call('put', {
        'parentId': parentId,
        'name': name,
        'mime': mime,
        'b64': base64Encode(bytes),
        if (overwriteId != null) 'overwriteId': overwriteId,
      });
      return DriveItem.fromJson(d as Map<String, dynamic>);
    }
    final uploadId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final total = (bytes.length / chunkBytes).ceil();
    for (var n = 0; n < total; n++) {
      final part = bytes.sublist(n * chunkBytes, (n + 1) * chunkBytes > bytes.length ? bytes.length : (n + 1) * chunkBytes);
      await _call('chunk', {'uploadId': uploadId, 'n': n, 'b64': base64Encode(part)});
    }
    final d = await _call('finish', {
      'uploadId': uploadId,
      'total': total,
      'parentId': parentId,
      'name': name,
      'mime': mime,
      if (overwriteId != null) 'overwriteId': overwriteId,
    });
    return DriveItem.fromJson(d as Map<String, dynamic>);
  }

  Future<DriveItem> mkdir(String parentId, String name) async =>
      DriveItem.fromJson(await _call('mkdir', {'parentId': parentId, 'name': name}) as Map<String, dynamic>);

  /// Id папки по пути от корня Диска (недостающие создаются): `Nexus/Chats/Имя`.
  Future<String> ensurePath(String path) async => '${(await _call('ensurePath', {'path': path}) as Map)['id']}';

  Future<void> rename(String id, String name) => _call('rename', {'id': id, 'name': name});
  Future<void> trash(String id) => _call('trash', {'id': id});
  Future<void> move(String id, String toId) => _call('move', {'id': id, 'toId': toId});
}

/// Фоновая синхронизация структуры Диска: одна на приложение, не зависит от открытого экрана.
/// Уходить с экрана можно — работа продолжается; прерванный индекс продолжается с того же места.
class GDriveSync {
  GDriveSync._();

  /// Прогресс: null — не идёт; 0..1, либо -1 — доля неизвестна. [doneFolders] — сколько папок обработано.
  static final progress = ValueNotifier<double?>(null);
  static int doneFolders = 0;
  static Future<void>? _running;

  static bool get running => _running != null;

  /// Запускает синхронизацию, если не идёт: быстрая сверка изменений; полный индекс — если его нет
  /// или он старше суток ([forceFull] — принудительно).
  static Future<void> run(LocalDbService db, {bool forceFull = false, http.Client Function()? clientFactory}) {
    final cur = _running;
    if (cur != null) return cur;
    final f = _go(db, forceFull, clientFactory);
    _running = f;
    f.whenComplete(() {
      _running = null;
      progress.value = null;
    });
    return f;
  }

  /// При запуске приложения и при открытии модуля: тихо, если Диск подключён.
  static Future<void> runIfConfigured(LocalDbService db) async {
    if (!GDriveService.configured(db)) return;
    await run(db);
  }

  static DateTime? _lastRun;

  static Future<void> _go(LocalDbService db, bool forceFull, http.Client Function()? clientFactory) async {
    final svc = GDriveService(db, clientFactory: clientFactory);
    progress.value = -1;
    doneFolders = 0;
    void onProgress(int done, int total) {
      doneFolders = done;
      progress.value = total > 0 ? (done / total).clamp(0.0, 1.0) : -1;
    }

    try {
      final at = GDriveService.indexedAt(db);
      // Полный индекс — только когда его ещё нет или попросили; иначе достаточно изменений, и не чаще
      // раза в 10 минут (закрыли и снова открыли Диск — не качаем заново).
      if (forceFull || at == null) {
        if (forceFull) GDriveService.markIndexStale(db);
        await svc.syncIndex(onProgress: onProgress);
        _lastRun = DateTime.now();
      } else if (_lastRun == null || DateTime.now().difference(_lastRun!) > const Duration(minutes: 10)) {
        await svc.syncChanges(onProgress: onProgress);
        _lastRun = DateTime.now();
      }
    } catch (_) {
      // сеть пропала — кэш остаётся, в следующий раз продолжим
    }
  }
}
