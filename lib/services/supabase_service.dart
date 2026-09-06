import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/comment.dart';
import '../models/share_grant.dart';
import '../state/app_data_store.dart';
import 'comments_repository.dart';
import 'supabase_auth_service.dart';

class SupabaseSyncException implements Exception {
  final String message;
  const SupabaseSyncException(this.message);
  @override
  String toString() => message;
}

/// Итог одного прогона синхронизации — для сообщения на экране настроек.
class SyncResult {
  final int pushedSessions;
  final int pulledExercises;
  final int pulledSessions;
  final int pulledComments;

  const SyncResult({
    this.pushedSessions = 0,
    this.pulledExercises = 0,
    this.pulledSessions = 0,
    this.pulledComments = 0,
  });

  bool get isEmpty =>
      pushedSessions == 0 && pulledExercises == 0 && pulledSessions == 0 && pulledComments == 0;
}

/// Реальная синхронизация с личной базой Supabase — обычный `http` и
/// PostgREST, тем же способом, что и `SupabaseAuthService` (см. её
/// комментарий "Почему REST, а не пакет supabase_flutter" — причины те
/// же самые здесь).
///
/// Правило слияния при pull — НЕ перезаписывать существующее локально,
/// только довешивать недостающее: локальная тренировка завершена и
/// больше не редактируется (`canEdit` требует `status != finished`), а
/// комментарии в принципе неизменяемы после создания. Настоящая
/// двусторонняя правка одной тренировки с двух устройств не
/// предполагается — синхронизация ручная, кнопкой, раз в какое-то время
/// (раздел 14 ТЗ), а не живые совместные правки.
class SupabaseSyncService {
  final SupabaseAuthService auth;
  final http.Client Function() clientFactory;

  SupabaseSyncService(this.auth, {http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;

  Future<String> _requireToken() async {
    final token = await auth.ensureFreshToken();
    if (token == null) {
      throw const SupabaseSyncException('Сначала войдите в базу — Настройки → Учётная запись');
    }
    return token;
  }

  Map<String, String> _headers(String token, {bool upsert = false}) => {
        'apikey': auth.anonKey,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        if (upsert) 'Prefer': 'resolution=merge-duplicates,return=minimal',
      };

  Future<void> _upsert(String token, String table, List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${auth.url}/rest/v1/$table?on_conflict=id'),
            headers: _headers(token, upsert: true),
            body: jsonEncode(rows),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw SupabaseSyncException('$table: ${_errorMessage(res.body, res.statusCode)}');
      }
    } finally {
      client.close();
    }
  }

  Future<List<Map<String, dynamic>>> _selectMine(String token, String table) async {
    final client = clientFactory();
    try {
      final res = await client
          .get(Uri.parse('${auth.url}/rest/v1/$table?select=*'), headers: _headers(token))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw SupabaseSyncException('$table: ${_errorMessage(res.body, res.statusCode)}');
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return (decoded as List).cast<Map<String, dynamic>>();
    } finally {
      client.close();
    }
  }

  static String _errorMessage(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final msg = decoded['message'] ?? decoded['error_description'] ?? decoded['error'];
        if (msg is String && msg.isNotEmpty) return 'HTTP $status: $msg';
      }
    } catch (_) {
      // тело не JSON — покажем как есть, ниже
    }
    return 'HTTP $status: ${body.length > 200 ? '${body.substring(0, 200)}…' : body}';
  }

  /// Отправляет все ещё не отправленные ЗАВЕРШЁННЫЕ тренировки —
  /// целиком: упражнение, саму тренировку, все выстрелы (включая
  /// корзину) и все комментарии тренировки. Помечает отправленной
  /// ЛОКАЛЬНО только после того, как она реально уехала — иначе при
  /// сетевой ошибке половина пути тренировка считалась бы синхронной,
  /// не будучи ей.
  Future<int> push(AppDataStore store) async {
    final token = await _requireToken();
    final repo = CommentsRepository(store.db);
    var count = 0;
    for (final session in store.unsyncedSessions) {
      final exercise = store.exerciseFor(session);
      if (exercise != null) {
        await _upsert(token, 'exercises', [exercise.toJson()]);
      }
      await _upsert(token, 'training_sessions', [
        {
          'id': session.id,
          'exercise_id': session.exerciseId,
          'target_face_code': session.targetFaceCode,
          'status': session.status.name,
          'started_at': session.startedAt?.toIso8601String(),
          'finished_at': session.finishedAt?.toIso8601String(),
          'pause_intervals': session.pauseIntervals.map((p) => p.toJson()).toList(),
          'extra': session.extra,
        }
      ]);
      final shotRows = [
        for (final s in session.shots) {...s.toJson(), 'session_id': session.id, 'is_trashed': false},
        for (final s in session.trash) {...s.toJson(), 'session_id': session.id, 'is_trashed': true},
      ];
      await _upsert(token, 'shots', shotRows);
      final commentRows = [for (final c in repo.forSessionAll(session.id)) c.toJson()];
      await _upsert(token, 'comments', commentRows);

      store.markSessionSynced(session.id);
      count++;
    }
    return count;
  }

  /// Забирает с сервера то, чего ещё нет на этом устройстве: упражнения,
  /// тренировки с выстрелами, комментарии (в т.ч. от тренера — RLS на
  /// `comments` пускает того, кто владеет тренировкой, читать комментарии
  /// к ней независимо от того, кто их написал).
  Future<SyncResult> pull(AppDataStore store) async {
    final token = await _requireToken();

    final exerciseRows = await _selectMine(token, 'exercises');
    final beforeExercises = store.exercises.length;
    for (final row in exerciseRows) {
      store.upsertExerciseFromRemote(row);
    }

    final sessionRows = await _selectMine(token, 'training_sessions');
    final shotRows = await _selectMine(token, 'shots');
    final shotsBySession = <String, List<Map<String, dynamic>>>{};
    for (final row in shotRows) {
      (shotsBySession[row['session_id'] as String] ??= []).add(row);
    }
    final beforeSessions = store.sessions.length;
    for (final row in sessionRows) {
      store.upsertSessionFromRemote(row, shotsBySession[row['id']] ?? const []);
    }

    final commentRows = await _selectMine(token, 'comments');
    final repo = CommentsRepository(store.db);
    final existingCommentIds = {
      for (final row in store.db.db.select('SELECT id FROM comments')) row['id'] as String,
    };
    var pulledComments = 0;
    for (final row in commentRows) {
      if (existingCommentIds.contains(row['id'])) continue;
      repo.addIfMissing(Comment.fromJson(row));
      pulledComments++;
    }
    if (pulledComments > 0) store.refreshView();

    return SyncResult(
      pulledExercises: store.exercises.length - beforeExercises,
      pulledSessions: store.sessions.length - beforeSessions,
      pulledComments: pulledComments,
    );
  }

  /// Создаёт токен доступа тренеру через RPC `create_share_token`:
  /// токен генерируется и хешируется НА СЕРВЕРЕ, приложение видит его
  /// открытый вид только этот единственный раз в ответе. Список токенов
  /// на экране настроек обновляется отдельным вызовом `refreshShareGrants`.
  Future<String> createShareToken(AppDataStore store, {String athleteLabel = ''}) async {
    final token = await _requireToken();
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${auth.url}/rest/v1/rpc/create_share_token'),
            headers: _headers(token),
            body: jsonEncode({'p_athlete_label': athleteLabel}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        throw SupabaseSyncException(_errorMessage(res.body, res.statusCode));
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final plainToken = decoded is String ? decoded : '$decoded';
      await refreshShareGrants(store);
      return plainToken;
    } finally {
      client.close();
    }
  }

  Future<void> revokeShareToken(AppDataStore store, String grantId) async {
    final token = await _requireToken();
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${auth.url}/rest/v1/rpc/revoke_share_token'),
            headers: _headers(token),
            body: jsonEncode({'p_grant_id': grantId}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        throw SupabaseSyncException(_errorMessage(res.body, res.statusCode));
      }
      await refreshShareGrants(store);
    } finally {
      client.close();
    }
  }

  /// Перечитывает список токенов с сервера — источник истины он, не
  /// локальная база: отозвать токен можно и с другого устройства.
  Future<void> refreshShareGrants(AppDataStore store) async {
    final token = await _requireToken();
    final rows = await _selectMine(token, 'share_grants');
    store.replaceShareGrants([for (final row in rows) ShareGrant.fromJson(row)]);
  }
}
