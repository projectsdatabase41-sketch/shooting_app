// Мост SupabaseSyncService <-> реальная схема Supabase (TASK-sync-mapping.md,
// раздел 9). Сеть не используется — http-клиент подменяется на
// MockClient поверх маленькой имитации PostgREST в памяти: она хранит
// строки по таблицам и понимает upsert по id (Prefer:
// resolution=merge-duplicates) ровно настолько, насколько это нужно
// коду моста.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/models/training_session.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/supabase_auth_service.dart';
import 'package:shooting_app/services/supabase_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

/// Имитация PostgREST: таблицы по имени, upsert по id, GET отдаёт всё
/// как есть (фильтры/select в query string игнорируются — для теста
/// моста этого достаточно, сам мост всегда запрашивает select=*).
class _FakeSupabase {
  final tables = <String, List<Map<String, dynamic>>>{
    'target_faces': [
      for (final f in TargetFace.all)
        {
          'id': 'tf_${f.code}',
          'code': f.code,
          'name': f.name,
          'distance_m': f.distanceM,
          'default_caliber_mm': f.caliberMm,
        },
    ],
  };

  int _seq = 0;

  Future<http.Response> handle(http.Request req) async {
    final path = req.url.path;
    if (path == '/auth/v1/token') {
      return http.Response(
        jsonEncode({
          'access_token': 'fake-token',
          'refresh_token': 'fake-refresh',
          'expires_in': 3600,
          'user': {'id': 'u1', 'email': 'athlete@example.com'},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (!path.startsWith('/rest/v1/')) {
      return http.Response('not found', 404);
    }
    final rest = path.substring('/rest/v1/'.length);
    if (rest.startsWith('rpc/')) {
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    }
    final table = rest;
    final rows = tables.putIfAbsent(table, () => []);
    if (req.method == 'GET') {
      return http.Response(jsonEncode(rows), 200, headers: {'content-type': 'application/json'});
    }
    if (req.method == 'POST') {
      final incoming = (jsonDecode(req.body) as List).cast<Map<String, dynamic>>();
      final returned = <Map<String, dynamic>>[];
      for (final row in incoming) {
        final id = (row['id'] as String?) ?? 'gen_${table}_${_seq++}';
        final full = {...row, 'id': id};
        final idx = rows.indexWhere((r) => r['id'] == id);
        if (idx == -1) {
          rows.add(full);
        } else {
          rows[idx] = full;
        }
        returned.add(rows[idx == -1 ? rows.length - 1 : idx]);
      }
      final wantsRepresentation = (req.headers['Prefer'] ?? '').contains('return=representation');
      return http.Response(
        wantsRepresentation ? jsonEncode(returned) : '',
        200,
        headers: wantsRepresentation ? {'content-type': 'application/json'} : {},
      );
    }
    return http.Response('method not supported by fake', 405);
  }
}

class _Harness {
  final _FakeSupabase fake;
  final AppDataStore store;
  final SupabaseSyncService sync;

  _Harness(this.fake, this.store, this.sync);

  static Future<_Harness> create() async {
    final fake = _FakeSupabase();
    final client = MockClient(fake.handle);
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db);
    store.loadAll();

    final auth = SupabaseAuthService(db)..clientFactory = () => client;
    auth.setBase(url: 'https://fake.test', anonKey: 'anon-key');
    await auth.signIn(email: 'athlete@example.com', password: 'whatever');

    final sync = SupabaseSyncService(auth, clientFactory: () => client);
    return _Harness(fake, store, sync);
  }
}

Exercise _buildExercise() => const Exercise(
      id: 'ex1',
      name: 'Тестовое упражнение',
      targetFaceCode: 'rifle_10m',
      totalShots: 3,
      seriesSize: 3,
    );

TrainingSession _buildSession(List<Shot> shots) => TrainingSession(
      id: 'se1',
      exerciseId: 'ex1',
      targetFaceCode: 'rifle_10m',
      status: SessionStatus.finished,
      startedAt: DateTime.utc(2026, 9, 1, 10, 0),
      finishedAt: DateTime.utc(2026, 9, 1, 10, 20),
      shots: shots,
      extra: {'источник': 'тест'},
    );

void main() {
  test('round-trip: количество, координаты, результаты, серии, counts, extra, статус, время', () async {
    final h = await _Harness.create();
    h.store.exercises = [_buildExercise()];
    final shots = [
      Shot(id: 'sh1', shotNumber: 1, seriesNo: 1, xMm: 1.234567, yMm: -2.345678, score: 10.4, time: DateTime.utc(2026, 9, 1, 10, 1)),
      Shot(id: 'sh2', shotNumber: 2, seriesNo: 1, xMm: -3.0, yMm: 4.0, score: 9.8, time: DateTime.utc(2026, 9, 1, 10, 2)),
      Shot(id: 'sh3', shotNumber: 3, seriesNo: 1, xMm: 0.0, yMm: 0.0, score: 10.9, time: DateTime.utc(2026, 9, 1, 10, 3), counts: false),
    ];
    h.store.upsertSession(_buildSession(shots));

    final pushed = await h.sync.push(h.store);
    expect(pushed, 1);

    final fresh = await _Harness.create();
    fresh.fake.tables.addAll(h.fake.tables); // тот же "сервер"
    final result = await fresh.sync.pull(fresh.store);

    expect(result.pulledSessions, 1);
    final session = fresh.store.sessions.single;
    expect(session.shots.length, 3, reason: 'количество выстрелов');
    expect(session.status, SessionStatus.finished, reason: 'статус');
    expect(session.startedAt, DateTime.utc(2026, 9, 1, 10, 0), reason: 'время начала');
    expect(session.finishedAt, DateTime.utc(2026, 9, 1, 10, 20), reason: 'время конца');
    expect(session.extra, {'источник': 'тест'}, reason: 'содержимое extra');

    final byId = {for (final s in session.shots) s.id: s};
    expect(byId['sh1']!.xMm, closeTo(1.234567, 1e-6));
    expect(byId['sh1']!.yMm, closeTo(-2.345678, 1e-6));
    expect(byId['sh1']!.score, 10.4);
    expect(byId['sh1']!.seriesNo, 1);
    expect(byId['sh3']!.counts, isFalse, reason: 'флаг counts');
    expect(byId['sh1']!.counts, isTrue);
  });

  test('знак Y: выстрел выше центра остаётся выше центра после round-trip', () async {
    final h = await _Harness.create();
    h.store.exercises = [_buildExercise()];
    h.store.upsertSession(_buildSession([
      Shot(id: 'sh1', shotNumber: 1, seriesNo: 1, xMm: 0, yMm: 7.5, score: 10.0, time: DateTime.utc(2026, 9, 1, 10, 1)),
    ]));
    await h.sync.push(h.store);

    final fresh = await _Harness.create();
    fresh.fake.tables.addAll(h.fake.tables);
    await fresh.sync.pull(fresh.store);

    expect(fresh.store.sessions.single.shots.single.yMm, greaterThan(0), reason: 'выше центра — Y должен остаться положительным, не перевернуться');
  });

  test('повторная отправка той же тренировки не создаёт дубликатов', () async {
    final h = await _Harness.create();
    h.store.exercises = [_buildExercise()];
    h.store.upsertSession(_buildSession([
      Shot(id: 'sh1', shotNumber: 1, seriesNo: 1, xMm: 0, yMm: 0, score: 10.0, time: DateTime.utc(2026, 9, 1, 10, 1)),
    ]));
    await h.sync.push(h.store);
    // Симулируем повторную синхронизацию той же тренировки (например,
    // пользователь нажал "Синхронизировать" ещё раз до появления новых
    // данных) — сбрасываем локальный флаг напрямую, минуя обычный путь.
    h.store.db.db.execute('UPDATE training_sessions SET synced_to_cloud = 0 WHERE id = ?', ['se1']);
    h.store.sessions = [h.store.sessions.single.copyWith(syncedToCloud: false)];

    await h.sync.push(h.store);

    expect(h.fake.tables['shots']!.where((r) => r['id'] == 'sh1').length, 1);
    expect(h.fake.tables['training_packages']!.where((r) => r['id'] == 'se1').length, 1);
    expect(h.fake.tables['exercises']!.where((r) => r['id'] == 'se1').length, 1);
  });

  test('правленый вручную выстрел не пересчитывается при чтении', () async {
    final h = await _Harness.create();
    h.store.exercises = [_buildExercise()];
    // Координаты дают один результат геометрией, но "истинный" результат
    // (например, с прибора) намеренно другой — он должен вернуться как есть.
    final manual = Shot(
      id: 'sh1',
      shotNumber: 1,
      seriesNo: 1,
      xMm: 20,
      yMm: 20,
      score: 10.4, // заведомо не совпадает с тем, что даст scoreForRadius для этой точки
      time: DateTime.utc(2026, 9, 1, 10, 1),
      isManuallyEdited: true,
    );
    h.store.upsertSession(_buildSession([manual]));
    await h.sync.push(h.store);

    final fresh = await _Harness.create();
    fresh.fake.tables.addAll(h.fake.tables);
    await fresh.sync.pull(fresh.store);

    final pulled = fresh.store.sessions.single.shots.single;
    expect(pulled.score, 10.4, reason: 'final_score читается как есть, без пересчёта по координатам');
    expect(pulled.isManuallyEdited, isTrue);
  });
}
