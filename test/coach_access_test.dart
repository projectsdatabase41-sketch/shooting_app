// Дневник тренера по токену — на реальной базе изначально не было ни
// одной из функций get_shared_*/add_shared_comment (только
// validate_share_token/hash_share_token, см. docs/db-schema-actual.md),
// поэтому переход в "Дневник" у тренера падал с PGRST202. Тест гоняет
// весь путь через имитацию PostgREST в памяти: спортсмен пушит
// тренировку и выпускает токен, тренер тем же токеном читает дневник и
// пишет комментарий — сеть не используется.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/training_session.dart';
import 'package:shooting_app/services/coach_access_service.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/supabase_auth_service.dart';
import 'package:shooting_app/services/supabase_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

/// Имитация PostgREST — таблицы + пять RPC из sql/schema.sql, ровно
/// настолько, насколько их логику использует мост:
/// hash_share_token/validate_share_token хранят и сверяют токен без
/// настоящего bcrypt (для теста достаточно, что тот же токен даёт тот
/// же "хеш"), get_shared_*/add_shared_comment читают/пишут по правилу
/// "проект один — токен либо годный на весь проект, либо нет".
class _FakeSupabase {
  final tables = <String, List<Map<String, dynamic>>>{};

  int _seq = 0;

  String? _matchToken(String token) {
    final hash = 'hash_of_$token';
    for (final g in tables['share_grants'] ?? const []) {
      if (g['token_hash'] == hash && g['revoked_at'] == null) return '${g['id']}';
    }
    return null;
  }

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
    if (!path.startsWith('/rest/v1/')) return http.Response('not found', 404);
    final rest = path.substring('/rest/v1/'.length);

    if (rest.startsWith('rpc/')) {
      final fn = rest.substring('rpc/'.length);
      final args = jsonDecode(req.body) as Map<String, dynamic>;
      return _rpc(fn, args);
    }

    final rows = tables.putIfAbsent(rest, () => []);
    if (req.method == 'GET') {
      return http.Response(jsonEncode(rows), 200, headers: {'content-type': 'application/json'});
    }
    if (req.method == 'POST') {
      final incoming = (jsonDecode(req.body) as List).cast<Map<String, dynamic>>();
      final returned = <Map<String, dynamic>>[];
      for (final row in incoming) {
        final id = (row['id'] as String?) ?? 'gen_${rest}_${_seq++}';
        final full = {
          if (rest == 'share_grants') 'created_at': DateTime.now().toIso8601String(),
          ...row,
          'id': id,
        };
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

  http.Response _rpc(String fn, Map<String, dynamic> args) {
    switch (fn) {
      case 'hash_share_token':
        return http.Response(jsonEncode('hash_of_${args['p_token']}'), 200, headers: {'content-type': 'application/json'});
      case 'validate_share_token':
        final ok = _matchToken('${args['p_token']}') != null;
        return http.Response(ok ? '"ok"' : 'null', 200, headers: {'content-type': 'application/json'});
      case 'revoke_share_grant':
        for (final g in tables['share_grants'] ?? const []) {
          if (g['id'] == args['p_share_grant_id']) g['revoked_at'] = DateTime.now().toIso8601String();
        }
        return http.Response('', 200);
      case 'get_shared_packages':
        if (_matchToken('${args['p_token']}') == null) return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        return http.Response(jsonEncode(tables['training_packages'] ?? []), 200, headers: {'content-type': 'application/json'});
      case 'get_shared_exercises':
        if (_matchToken('${args['p_token']}') == null) return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        return http.Response(jsonEncode(tables['exercises'] ?? []), 200, headers: {'content-type': 'application/json'});
      case 'get_shared_shots':
        if (_matchToken('${args['p_token']}') == null) return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        final rows = (tables['shots'] ?? []).where((r) => r['exercise_id'] == args['p_exercise_id']).toList();
        return http.Response(jsonEncode(rows), 200, headers: {'content-type': 'application/json'});
      case 'get_shared_comments':
        if (_matchToken('${args['p_token']}') == null) return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        final rows = (tables['comments'] ?? []).where((r) => r['package_id'] == args['p_package_id']).toList();
        return http.Response(jsonEncode(rows), 200, headers: {'content-type': 'application/json'});
      case 'add_shared_comment':
        if (_matchToken('${args['p_token']}') == null) {
          return http.Response(jsonEncode({'message': 'invalid or revoked token'}), 400, headers: {'content-type': 'application/json'});
        }
        final row = {
          'id': 'gen_comment_${_seq++}',
          'package_id': args['p_package_id'],
          'level': args['p_level'],
          'shot_id': args['p_shot_id'],
          'series_no': args['p_series_no'],
          'author_role': 'coach',
          'text': args['p_text'],
          'created_at': DateTime.now().toIso8601String(),
        };
        (tables['comments'] ??= []).add(row);
        return http.Response(jsonEncode(row), 200, headers: {'content-type': 'application/json'});
      default:
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    }
  }
}

void main() {
  test('тренер по токену видит тренировку спортсмена, её выстрелы и может написать комментарий', () async {
    final fake = _FakeSupabase();
    final client = MockClient(fake.handle);

    // ---- Спортсмен: пушит тренировку и выпускает токен тренеру ----
    final athleteDb = LocalDbService();
    await athleteDb.open(overridePath: ':memory:');
    final athleteStore = AppDataStore(athleteDb);
    athleteStore.loadAll();
    athleteStore.exercises = [
      const Exercise(id: 'ex1', name: 'Тестовое упражнение', targetFaceCode: 'rifle_10m', totalShots: 1, seriesSize: 1),
    ];
    athleteStore.upsertSession(TrainingSession(
      id: 'se1',
      exerciseId: 'ex1',
      targetFaceCode: 'rifle_10m',
      status: SessionStatus.finished,
      startedAt: DateTime.utc(2026, 9, 1, 10),
      finishedAt: DateTime.utc(2026, 9, 1, 10, 20),
      shots: [Shot(id: 'sh1', shotNumber: 1, seriesNo: 1, xMm: 1, yMm: 2, score: 9.5, time: DateTime.utc(2026, 9, 1, 10, 1))],
    ));

    final athleteAuth = SupabaseAuthService(athleteDb)..clientFactory = () => client;
    athleteAuth.setBase(url: 'https://fake.test', anonKey: 'anon-key');
    await athleteAuth.signIn(email: 'athlete@example.com', password: 'whatever');
    final sync = SupabaseSyncService(athleteAuth, clientFactory: () => client);

    await sync.push(athleteStore);
    final plainToken = await sync.createShareToken(athleteStore, athleteLabel: 'Вася');

    // ---- Тренер: подключается тем же токеном к "чужой" базе ----
    final coachDb = LocalDbService();
    await coachDb.open(overridePath: ':memory:');
    final access = CoachAccessService(coachDb)..clientFactory = () => client;
    access.setConnection(url: 'https://fake.test', anonKey: 'anon-key', token: plainToken);

    final sessions = await access.fetchSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single['id'], 'se1');

    final exercises = await access.fetchExercises();
    final match = exercises.singleWhere((e) => e['package_id'] == 'se1');
    expect(match['exercise_name'], 'Тестовое упражнение');

    final shots = await access.fetchShots('se1');
    expect(shots, hasLength(1));
    expect((shots.single['final_score'] as num).toDouble(), 9.5);

    await access.addComment(sessionId: 'se1', level: 'coach', text: 'Хорошая тренировка!');
    final comments = await access.fetchComments('se1');
    expect(comments, hasLength(1));
    expect(comments.single['text'], 'Хорошая тренировка!');
    expect(comments.single['author_role'], 'coach');
  });

  test('отозванный токен не даёт доступа к дневнику', () async {
    final fake = _FakeSupabase();
    final client = MockClient(fake.handle);

    final athleteDb = LocalDbService();
    await athleteDb.open(overridePath: ':memory:');
    final athleteStore = AppDataStore(athleteDb);
    athleteStore.loadAll();
    final athleteAuth = SupabaseAuthService(athleteDb)..clientFactory = () => client;
    athleteAuth.setBase(url: 'https://fake.test', anonKey: 'anon-key');
    await athleteAuth.signIn(email: 'athlete@example.com', password: 'whatever');
    final sync = SupabaseSyncService(athleteAuth, clientFactory: () => client);

    final plainToken = await sync.createShareToken(athleteStore);
    final grantId = fake.tables['share_grants']!.single['id'] as String;
    await sync.revokeShareToken(athleteStore, grantId);

    final coachDb = LocalDbService();
    await coachDb.open(overridePath: ':memory:');
    final access = CoachAccessService(coachDb)..clientFactory = () => client;
    access.setConnection(url: 'https://fake.test', anonKey: 'anon-key', token: plainToken);

    expect(await access.fetchSessions(), isEmpty);
  });
}
