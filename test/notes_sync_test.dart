import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/models/coach_note.dart';
import 'package:shooting_app/services/coach_notes_repository.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/notes_sync_service.dart';
import 'package:shooting_app/services/supabase_auth_service.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

/// «Облако» в памяти: ведёт себя как PostgREST для таблицы notes.
class _Cloud {
  final rows = <Map<String, dynamic>>[];
  int n = 0;

  Future<http.Response> handle(http.Request r) async {
    final q = r.url.queryParameters;
    if (r.method == 'POST') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final row = {...body, 'id': 'cloud-${++n}'};
      rows.add(row);
      return http.Response(jsonEncode([row]), 201, headers: _json);
    }
    if (r.method == 'PATCH') {
      final id = q['id']!.replaceFirst('eq.', '');
      final row = rows.firstWhere((x) => x['id'] == id);
      row.addAll(jsonDecode(r.body) as Map<String, dynamic>);
      return http.Response('', 204);
    }
    // GET: только наш источник
    final src = q['source']?.replaceFirst('eq.', '');
    return http.Response(jsonEncode([for (final x in rows) if (x['source'] == src) x]), 200, headers: _json);
  }
}

Future<(LocalDbService, NotesSyncService, _Cloud)> _setup() async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  final auth = SupabaseAuthService(db)..setBase(url: 'https://x.supabase.co', anonKey: 'anon');
  final cloud = _Cloud();
  final svc = NotesSyncService(db, auth, clientFactory: () => MockClient(cloud.handle));
  return (db, svc, cloud);
}

CoachNote _note(String id, String topic, String content) =>
    CoachNote(id: id, topic: topic, content: content, createdAt: DateTime.utc(2026, 10, 16, 12));

void main() {
  test('новая заметка уходит в notes с нашим source, получает cloud_id', () async {
    final (db, svc, cloud) = await _setup();
    CoachNotesRepository(db).add(_note('n1', 'Тема', 'Текст заметки'));
    expect(await svc.sync(), 1);
    expect(cloud.rows.single['source'], 'nexus_app');
    expect(cloud.rows.single['topic'], 'Тема');
    expect(cloud.rows.single['summary'], 'Текст заметки');
    final row = db.db.select('SELECT cloud_id, dirty FROM coach_notes').first;
    expect(row['cloud_id'], 'cloud-1');
    expect(row['dirty'], 0);
    expect(await svc.sync(), 0); // повторно нечего отправлять
  });

  test('правка обновляет облачную строку, а не создаёт новую', () async {
    final (db, svc, cloud) = await _setup();
    final repo = CoachNotesRepository(db);
    repo.add(_note('n1', 'Тема', 'v1'));
    await svc.sync();
    repo.update('n1', topic: 'Тема2', content: 'v2');
    await svc.sync();
    expect(cloud.rows.length, 1);
    expect(cloud.rows.single['content'], 'v2');
  });

  test('удаление архивирует облачную строку, чужие строки таблицы не трогаются', () async {
    final (db, svc, cloud) = await _setup();
    cloud.rows.add({'id': 'old', 'topic': 'Чужая', 'content': 'из airtable', 'source': 'airtable', 'status': 'active'});
    final repo = CoachNotesRepository(db);
    repo.add(_note('n1', 'Тема', 'текст'));
    await svc.sync();
    repo.delete('n1');
    expect(repo.list(), isEmpty); // сразу пропала из списка
    await svc.sync();
    expect(cloud.rows.firstWhere((r) => r['id'] == 'cloud-1')['status'], 'archived');
    expect(cloud.rows.firstWhere((r) => r['id'] == 'old')['status'], 'active'); // чужая не тронута
    expect(db.db.select('SELECT 1 FROM coach_notes'), isEmpty);
  });

  test('заметка с другого устройства подтягивается, архивная — убирается', () async {
    final (db, svc, cloud) = await _setup();
    cloud.rows.add({
      'id': 'c-9',
      'topic': 'С телефона',
      'content': 'написано там',
      'source': 'nexus_app',
      'status': 'active',
      'metadata': {'local_id': 'dev2-1'},
      'created_at': '2026-10-15T10:00:00Z',
      'updated_at': '2026-10-15T10:00:00Z',
    });
    await svc.sync();
    final repo = CoachNotesRepository(db);
    expect(repo.list().single.topic, 'С телефона');
    cloud.rows.single['status'] = 'archived';
    await svc.sync();
    expect(repo.list(), isEmpty);
  });

  test('без подключённой базы синхронизация молча пропускается', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final svc = NotesSyncService(db, SupabaseAuthService(db));
    expect(await svc.sync(), isNull);
  });
}
