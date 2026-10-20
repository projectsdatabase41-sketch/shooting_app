import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/gdrive/gdrive_service.dart';
import 'package:shooting_app/services/local_db_service.dart';

Future<LocalDbService> _db() async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  GDriveService.save(db, url: 'https://script.google.com/macros/s/X/exec', secret: 'pass');
  return db;
}

void main() {
  test('POST на мост идёт с паролем, ответ берётся с адреса переадресации', () async {
    final db = await _db();
    final calls = <String>[];
    final svc = GDriveService(db, clientFactory: () => MockClient((req) async {
          calls.add('${req.method} ${req.url.host}');
          if (req.method == 'POST') {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            expect(body['secret'], 'pass');
            expect(body['action'], 'list');
            return http.Response('', 302, headers: {'location': 'https://script.googleusercontent.com/result'});
          }
          return http.Response(
              jsonEncode({
                'ok': true,
                'data': {
                  'id': 'root',
                  'name': 'Мой диск',
                  'parent': null,
                  'folders': [
                    {'id': 'f1', 'name': 'Nexus', 'mime': 'folder', 'size': 0, 'modified': 1, 'url': 'u', 'isFolder': true}
                  ],
                  'files': [
                    {'id': 'a', 'name': 'a.txt', 'mime': 'text/plain', 'size': 5, 'modified': 2, 'url': 'u', 'isFolder': false}
                  ],
                }
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    final l = await svc.list();
    expect(calls, ['POST script.google.com', 'GET script.googleusercontent.com']);
    expect(l.folders.single.name, 'Nexus');
    expect(l.files.single.isText, isTrue);
  });

  test('неверный пароль и чужой ответ понятно сообщаются', () async {
    final db = await _db();
    var wrong = true;
    final svc = GDriveService(db, clientFactory: () => MockClient((req) async => wrong
        ? http.Response(jsonEncode({'ok': false, 'error': 'unauthorized'}), 200)
        : http.Response('<html>login</html>', 200)));
    await expectLater(svc.ping(), throwsA(predicate((e) => '$e'.contains('пароль'))));
    wrong = false;
    await expectLater(svc.ping(), throwsA(predicate((e) => '$e'.contains('адрес'))));
  });

  test('крупный файл уходит частями, затем finish', () async {
    final db = await _db();
    final actions = <String>[];
    final svc = GDriveService(db, clientFactory: () => MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          actions.add('${body['action']}');
          final data = body['action'] == 'finish'
              ? {'id': 'n', 'name': 'big', 'mime': 'x', 'size': 1, 'modified': 1, 'url': 'u', 'isFolder': false}
              : true;
          return http.Response(jsonEncode({'ok': true, 'data': data}), 200);
        }));
    await svc.put('root', 'big', 'application/octet-stream', List.filled(GDriveService.chunkBytes * 2 + 10, 1));
    expect(actions, ['chunk', 'chunk', 'chunk', 'finish']);
  });

  test('без подключения вызов отклоняется', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    expect(GDriveService.configured(db), isFalse);
    await expectLater(GDriveService(db).ping(), throwsA(isA<GDriveException>()));
  });

  test('индекс: пакетный список папок кладётся в кэш, поиск идёт по кэшу, старый скрипт — по одной папке', () async {
    Map<String, dynamic> listing(String id, String name, {List<String> sub = const [], List<String> files = const []}) => {
          'id': id,
          'name': name,
          'parent': null,
          'folders': [for (final f in sub) {'id': f, 'name': 'Папка $f', 'mime': 'folder', 'size': 0, 'modified': 1, 'url': 'u', 'isFolder': true}],
          'files': [for (final f in files) {'id': 'file-$f', 'name': f, 'mime': 'text/plain', 'size': 1, 'modified': 1, 'url': 'u', 'isFolder': false}],
        };
    final tree = {
      'root': listing('root', 'Мой диск', sub: ['a']),
      'a': listing('a', 'Папка a', files: ['отчёт.txt']),
    };
    for (final oldScript in [false, true]) {
      final db = await _db();
      final svc = GDriveService(db, clientFactory: () => MockClient((req) async {
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            if (body['action'] == 'listMany') {
              if (oldScript) return http.Response(jsonEncode({'ok': false, 'error': 'unknown action'}), 200);
              return http.Response.bytes(utf8.encode(jsonEncode({'ok': true, 'data': {for (final id in body['ids']) id: tree[id]}})), 200);
            }
            return http.Response.bytes(utf8.encode(jsonEncode({'ok': true, 'data': tree[body['folderId']]})), 200);
          }));
      var last = 0;
      final n = await svc.syncIndex(onProgress: (c) => last = c);
      expect(n, 2);
      expect(last, 2);
      expect(GDriveService.cached(db, 'a')?.files.single.name, 'отчёт.txt');
      expect(GDriveService.indexedAt(db), isNotNull);
      expect(GDriveService.searchCached(db, 'ОТЧЁТ').map((e) => e.id), ['file-отчёт.txt']);
      GDriveService.disconnect(db);
      expect(GDriveService.cached(db, 'a'), isNull);
    }
  });
}
