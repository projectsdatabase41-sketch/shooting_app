import 'dart:convert';
import 'dart:typed_data';

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

  bool get isImage => mime.startsWith('image/');
  bool get isText => mime.startsWith('text/') || const {'application/json', 'application/xml'}.contains(mime);
}

class DriveListing {
  final String id;
  final String name;
  final String? parent;
  final List<DriveItem> folders;
  final List<DriveItem> files;
  const DriveListing({required this.id, required this.name, this.parent, required this.folders, required this.files});
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
  static String secret(LocalDbService db) => _get(db, _secretKey) ?? _empty;
  static bool configured(LocalDbService db) => url(db).startsWith('https://') && secret(db).isNotEmpty;

  static void save(LocalDbService db, {required String url, required String secret}) {
    _put(db, _urlKey, url.trim());
    _put(db, _secretKey, secret.trim());
  }

  static void disconnect(LocalDbService db) {
    _put(db, _urlKey, '');
    _put(db, _secretKey, '');
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

  Future<DriveListing> list([String folderId = 'root']) async {
    final d = await _call('list', {'folderId': folderId}) as Map<String, dynamic>;
    return DriveListing(
      id: '${d['id']}',
      name: '${d['name']}',
      parent: d['parent'] as String?,
      folders: [for (final f in (d['folders'] as List)) DriveItem.fromJson(f as Map<String, dynamic>)],
      files: [for (final f in (d['files'] as List)) DriveItem.fromJson(f as Map<String, dynamic>)],
    );
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
