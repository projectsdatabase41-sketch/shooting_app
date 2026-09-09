import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../logic/scoring.dart';
import '../models/comment.dart';
import '../models/exercise.dart';
import '../models/share_grant.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
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

/// Мост между локальной моделью приложения и РЕАЛЬНОЙ схемой Supabase —
/// см. `docs/db-schema-actual.md` для точной таблицы соответствия полей
/// и обоснования каждого решения. Коротко, что здесь непохоже на
/// локальную модель и почему:
///
/// - Одна `TrainingSession` раскладывается в ДВЕ облачные строки:
///   `training_packages` (сам пакет) и ОДНУ дочернюю `exercises` —
///   реальная схема допускает несколько упражнений на пакет,
///   приложение сейчас пишет ровно одно. Обе строки используют один и
///   тот же `id` (пакет и его единственное дочернее упражнение), это
///   валидно — они в разных таблицах.
/// - `Exercise` (шаблон) отдельно живёт в `exercise_templates` — ссылки
///   от дочерней `exercises` к шаблону в реальной схеме НЕТ, поэтому
///   при push связь сохраняется явно в `exercises.extra.template_id`,
///   а при pull восстанавливается либо оттуда, либо (если строка
///   пришла не от этого моста и `extra` пуст) подбором по имени и
///   мишени — тем же приёмом, что `SessionImport._findOrCreateExercise`.
/// - Мишень (`target_face_code`) хранится СТРОКОЙ только локально; в
///   реальной схеме это `uuid`-внешний ключ на `target_faces` — код
///   заводит или находит строку-справочник по `code` при каждом push.
/// - Не синхронизируется (нет колонок и вне обязательного списка
///   раздела 9 задания): `pauseIntervals`, `Shot.isFavorite`,
///   `Exercise.gender`, `Exercise.series` (гибкие серии), корзина
///   выстрелов. Всё это остаётся только на устройстве, где записано.
///
/// Правило слияния при pull — НЕ перезаписывать существующее локально,
/// только довешивать недостающее: локальная тренировка завершена и
/// больше не редактируется (`canEdit` требует `status != finished`), а
/// комментарии в принципе неизменяемы после создания.
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

  Future<void> _deleteWhere(String token, String table, String column, String value) async {
    final client = clientFactory();
    try {
      final res = await client
          .delete(Uri.parse('${auth.url}/rest/v1/$table?$column=eq.$value'), headers: _headers(token))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw SupabaseSyncException('$table: ${_errorMessage(res.body, res.statusCode)}');
      }
    } finally {
      client.close();
    }
  }

  /// Удаляет в облаке тренировки, помеченные локально на удаление
  /// (`AppDataStore.pendingDeletionIds`, пункт 6 списка правок), и
  /// только ПОСЛЕ успеха стирает тромбстоун локально
  /// (`confirmSessionDeleted`) — если сеть оборвётся посередине, строка
  /// остаётся помеченной и попытка повторится на следующей
  /// синхронизации, вместо того чтобы тренировка "потерялась" с
  /// телефона, а в облаке осталась висеть.
  ///
  /// Порядок — от дочерних таблиц к родительской, тем же путём, что и
  /// связи в push (shots.exercise_id / comments.package_id — общий id
  /// с training_packages, см. _shotJson/_commentJson).
  Future<int> pushDeletions(AppDataStore store) async {
    final token = await _requireToken();
    var count = 0;
    for (final id in store.pendingDeletionIds()) {
      await _deleteWhere(token, 'comments', 'package_id', id);
      await _deleteWhere(token, 'shots', 'exercise_id', id);
      await _deleteWhere(token, 'exercises', 'id', id);
      await _deleteWhere(token, 'training_packages', 'id', id);
      store.confirmSessionDeleted(id);
      count++;
    }
    return count;
  }

  Future<List<Map<String, dynamic>>> _select(String token, String path) async {
    final client = clientFactory();
    try {
      final res = await client
          .get(Uri.parse('${auth.url}/rest/v1/$path'), headers: _headers(token))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        throw SupabaseSyncException(_errorMessage(res.body, res.statusCode));
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

  // ---- Справочник мишеней: код (локальный) <-> uuid (облачный) ----

  Future<Map<String, String>> _targetFaceIdsByCode(String token) async {
    final rows = await _select(token, 'target_faces?select=id,code');
    return {for (final r in rows) '${r['code']}': '${r['id']}'};
  }

  /// Находит или заводит строку-справочник мишени по коду. Сидируется
  /// схемой при первом применении `sql/schema.sql`, поэтому обычно уже
  /// на месте — заведение здесь только на случай, если справочник
  /// почему-то пуст.
  Future<String> _resolveTargetFaceId(
    String token,
    String code,
    Map<String, String> cache,
  ) async {
    final cached = cache[code];
    if (cached != null) return cached;
    final face = TargetFace.byCode(code);
    final client = clientFactory();
    try {
      final res = await client
          .post(
            Uri.parse('${auth.url}/rest/v1/target_faces?on_conflict=code'),
            headers: _headers(token, upsert: true)..['Prefer'] = 'resolution=merge-duplicates,return=representation',
            body: jsonEncode([
              {
                'code': face.code,
                'name': face.name,
                'distance_m': face.distanceM,
                'default_caliber_mm': face.caliberMm,
                'scoring_type': 'decimal',
                'max_score': 10.9,
                'ring_config': face.toJson(),
                'is_system': true,
                'is_active': true,
              }
            ]),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) {
        throw SupabaseSyncException('target_faces: ${_errorMessage(res.body, res.statusCode)}');
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final id = '${(decoded as List).first['id']}';
      cache[code] = id;
      return id;
    } finally {
      client.close();
    }
  }

  // ---- Push ----

  /// Отправляет все ещё не отправленные ЗАВЕРШЁННЫЕ тренировки —
  /// целиком: шаблон упражнения, пакет, дочернее упражнение-снимок, все
  /// АКТИВНЫЕ выстрелы (корзина на сервер не идёт — см. класс) и все
  /// комментарии тренировки. Помечает отправленной ЛОКАЛЬНО только
  /// после того, как она реально уехала.
  Future<int> push(AppDataStore store) async {
    final token = await _requireToken();
    final repo = CommentsRepository(store.db);
    final faceIds = await _targetFaceIdsByCode(token);
    var count = 0;
    for (final session in store.unsyncedSessions) {
      final exercise = store.exerciseFor(session);
      if (exercise == null) continue; // тренировка без упражнения — синхронизировать нечего
      final faceId = await _resolveTargetFaceId(token, session.targetFaceCode, faceIds);
      final face = TargetFace.byCode(session.targetFaceCode);

      await _upsert(token, 'exercise_templates', [_exerciseTemplateJson(exercise, face, faceId)]);
      await _upsert(token, 'training_packages', [_trainingPackageJson(session)]);
      await _upsert(token, 'exercises', [_exerciseSnapshotJson(session, exercise, face, faceId)]);

      final shotRows = [for (final s in session.shots) _shotJson(s, session.id, face, session.startedAt)];
      await _upsert(token, 'shots', shotRows);

      final commentRows = [for (final c in repo.forSessionAll(session.id)) _commentJson(c)];
      await _upsert(token, 'comments', commentRows);

      store.markSessionSynced(session.id);
      count++;
    }
    return count;
  }

  Map<String, dynamic> _exerciseTemplateJson(Exercise ex, TargetFace face, String faceId) => {
        'id': ex.id,
        // У приложения больше нет отдельного поля "код" (убрано — дублировало
        // название). Синтетическое значение только чтобы удовлетворить
        // NOT NULL в облаке, нигде обратно не читается.
        'code': 'custom_${ex.id}',
        'name': ex.name,
        'weapon_type': face.code.startsWith('rifle') ? 'rifle' : 'pistol',
        'ammo_type': face.caliberMm <= 4.5 ? 'air' : 'smallbore',
        'distance_m': face.distanceM,
        'shots_count': ex.totalShots,
        'series_count': (ex.totalShots / ex.seriesSize).ceil(),
        'shots_per_series': ex.seriesSize,
        'target_face_id': faceId,
        'is_custom': true,
        'is_active': !ex.isDeleted,
      };

  Map<String, dynamic> _trainingPackageJson(TrainingSession session) => {
        'id': session.id,
        'started_at': session.startedAt?.toIso8601String(),
        'ended_at': session.finishedAt?.toIso8601String(),
        'time_is_approximate': false,
        // Реальная схема не знает слова 'finished' (единственный статус,
        // до которого доходят синхронизируемые тренировки, — push шлёт
        // только store.unsyncedSessions, а туда попадают ровно
        // SessionStatus.finished) — допустимые слова см.
        // SUPABASE-CREATE.md: draft/active/completed/archived.
        'package_status': 'completed',
        'editor_mode': 'athlete',
        'is_locked_by_athlete': true,
        'local_version': 1,
        'extra': session.extra,
      };

  Map<String, dynamic> _exerciseSnapshotJson(
    TrainingSession session,
    Exercise exercise,
    TargetFace face,
    String faceId,
  ) =>
      {
        // Тот же id, что и у пакета: одно упражнение на тренировку
        // сейчас, отдельный id дочерней строке не нужен (раздел 2
        // задания — при появлении нескольких это первое, что придётся
        // менять).
        'id': session.id,
        'package_id': session.id,
        'exercise_name': exercise.label,
        'discipline': face.code,
        'distance_meters': face.distanceM,
        'target_face_id': faceId,
        'decimal_scoring': true,
        'expected_shots': exercise.totalShots,
        'started_at': session.startedAt?.toIso8601String(),
        'time_is_approximate': false,
        // Явная ссылка на шаблон — в реальной схеме прямого внешнего
        // ключа exercises → exercise_templates нет (см. комментарий
        // класса), поэтому связь для pull храним сами.
        'extra': {'template_id': exercise.id},
      };

  Map<String, dynamic> _shotJson(Shot shot, String sessionId, TargetFace face, DateTime? sessionStart) => {
        'id': shot.id,
        'exercise_id': sessionId,
        'shot_no': shot.shotNumber,
        'series_no': shot.seriesNo,
        'x_mm': shot.xMm,
        'y_mm': shot.yMm,
        'input_angle_degrees': shot.angleDeg,
        // Допустимые слова — см. SUPABASE-CREATE.md ("Значения,
        // ограниченные проверками"): 'tap' у координат, 'manual' у
        // источника — приложение сейчас не различает тап/фото/камеру на
        // уровне модели выстрела, это ближайшее по смыслу из списка.
        'coordinate_source': 'tap',
        'computed_score': scoreForRadius(shot.radiusMm, face),
        'final_score': shot.score,
        'source': 'manual',
        'is_manually_corrected': shot.isManuallyEdited,
        'confirmed': true,
        // ВАЖНО: колонка целая (integer) и хранит СМЕЩЕНИЕ от начала
        // тренировки в миллисекундах, не эпоху — час стрельбы даёт
        // около 1 100 000, а epoch millis (~1.7×10¹²) вылетает за
        // границы integer (ошибка 22003). См. SUPABASE-CREATE.md.
        'shot_time_ms': sessionStart == null ? 0 : shot.time.difference(sessionStart).inMilliseconds,
        'counts': shot.counts,
        'extra': shot.extra,
      };

  Map<String, dynamic> _commentJson(Comment c) => {
        'id': c.id,
        'package_id': c.sessionId,
        'level': c.level.name,
        'shot_id': c.shotId,
        'series_no': c.seriesNo,
        'author_role': c.authorRole.name,
        'text': c.text,
        'created_at': c.createdAt.toIso8601String(),
      };

  // ---- Pull ----

  /// Забирает с сервера то, чего ещё нет на этом устройстве: шаблоны
  /// упражнений, тренировки с выстрелами, комментарии (в т.ч. от
  /// тренера — RLS на `comments` пускает владельца пакета читать
  /// комментарии к нему независимо от того, кто их написал).
  Future<SyncResult> pull(AppDataStore store) async {
    final token = await _requireToken();
    final faceRows = await _select(token, 'target_faces?select=id,code');
    final codeById = {for (final r in faceRows) '${r['id']}': '${r['code']}'};

    final templateRows = await _select(token, 'exercise_templates?select=*');
    final beforeExercises = store.exercises.length;
    for (final row in templateRows) {
      if (store.exercises.any((e) => e.id == row['id'])) continue;
      store.upsertExerciseFromRemote(_exerciseFromTemplateRow(row, codeById));
    }

    final packageRows = await _select(token, 'training_packages?select=*');
    final exerciseChildRows = await _select(token, 'exercises?select=*');
    final childByPackage = {for (final r in exerciseChildRows) '${r['package_id']}': r};

    final shotRows = await _select(token, 'shots?select=*');
    final shotsByExercise = <String, List<Map<String, dynamic>>>{};
    for (final row in shotRows) {
      (shotsByExercise['${row['exercise_id']}'] ??= []).add(row);
    }

    final beforeSessions = store.sessions.length;
    for (final packageRow in packageRows) {
      final id = '${packageRow['id']}';
      if (store.sessions.any((s) => s.id == id)) continue;
      final child = childByPackage[id];
      if (child == null) continue; // пакет без дочернего упражнения — испорченная строка, пропускаем
      final faceCode = codeById['${child['target_face_id']}'];
      if (faceCode == null) continue; // мишень не опознана — восстановить тренировку не из чего

      final exerciseId = _resolveLocalExerciseId(store, child, faceCode);
      final sessionStart = _dateOrNull(packageRow['started_at']);
      final shots = [
        for (final r in shotsByExercise[id] ?? const <Map<String, dynamic>>[]) _shotFromRow(r, sessionStart),
      ]..sort((a, b) => a.shotNumber.compareTo(b.shotNumber));

      store.upsertSessionFromRemote(TrainingSession(
        id: id,
        exerciseId: exerciseId,
        targetFaceCode: faceCode,
        // Реальная схема не знает 'finished' (см. push) — только
        // 'completed' синхронизируется мостом, но читаем терпимо к
        // строкам от стороннего источника (draft/active/archived).
        status: packageRow['package_status'] == 'completed' ? SessionStatus.finished : SessionStatus.notStarted,
        startedAt: sessionStart,
        finishedAt: _dateOrNull(packageRow['ended_at']),
        shots: shots,
        syncedToCloud: true,
        extra: extraFromJson(packageRow['extra']),
      ));
    }

    final commentRows = await _select(token, 'comments?select=*');
    final repo = CommentsRepository(store.db);
    final existingCommentIds = {
      for (final row in store.db.db.select('SELECT id FROM comments')) row['id'] as String,
    };
    var pulledComments = 0;
    for (final row in commentRows) {
      if (existingCommentIds.contains(row['id'])) continue;
      repo.addIfMissing(Comment(
        id: '${row['id']}',
        sessionId: '${row['package_id']}',
        level: CommentLevel.values.firstWhere((l) => l.name == row['level']),
        shotId: row['shot_id'] as String?,
        seriesNo: row['series_no'] as int?,
        authorRole: AuthorRole.values.firstWhere((r) => r.name == row['author_role']),
        text: row['text'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      ));
      pulledComments++;
    }
    if (pulledComments > 0) store.refreshView();

    return SyncResult(
      pulledExercises: store.exercises.length - beforeExercises,
      pulledSessions: store.sessions.length - beforeSessions,
      pulledComments: pulledComments,
    );
  }

  Exercise _exerciseFromTemplateRow(Map<String, dynamic> row, Map<String, String> codeById) {
    final faceCode = codeById['${row['target_face_id']}'] ?? TargetFace.rifle10m.code;
    final shotsCount = (row['shots_count'] as num?)?.toInt() ?? 1;
    final perSeries = (row['shots_per_series'] as num?)?.toInt() ?? shotsCount;
    final isActive = row['is_active'] != false;
    return Exercise(
      id: '${row['id']}',
      name: '${row['name']}',
      targetFaceCode: faceCode,
      totalShots: shotsCount,
      seriesSize: perSeries <= 0 ? shotsCount : perSeries,
      deletedAt: isActive ? null : _dateOrNull(row['updated_at']),
    );
  }

  /// Восстанавливает id локального упражнения-шаблона для дочерней
  /// строки `exercises`. Прямой ссылки на `exercise_templates` в
  /// реальной схеме нет — сначала пробуем явную связь, записанную этим
  /// же мостом при push (`extra.template_id`), а для строк из другого
  /// источника — тем же подбором по имени+мишени, что использует
  /// `SessionImport._findOrCreateExercise`.
  String _resolveLocalExerciseId(AppDataStore store, Map<String, dynamic> child, String faceCode) {
    final extra = extraFromJson(child['extra']);
    final templateId = extra?['template_id'] as String?;
    if (templateId != null && store.exercises.any((e) => e.id == templateId)) {
      return templateId;
    }
    final name = '${child['exercise_name'] ?? ''}';
    final match = store.exercises.where((e) => e.name == name && e.targetFaceCode == faceCode).firstOrNull;
    if (match != null) return match.id;
    final expectedShots = (child['expected_shots'] as num?)?.toInt() ?? 1;
    return store
        .createExercise(
          name: name.isEmpty ? 'Без названия' : name,
          targetFaceCode: faceCode,
          totalShots: expectedShots,
          seriesSize: expectedShots,
        )
        .id;
  }

  Shot _shotFromRow(Map<String, dynamic> r, DateTime? sessionStart) {
    // shot_time_ms — смещение от начала тренировки в миллисекундах, не
    // эпоха (см. _shotJson) — без времени начала самой тренировки
    // абсолютный момент выстрела не восстановить, тогда лучше взять
    // время записи строки, чем спутать смещение с эпохой.
    final offsetMs = (r['shot_time_ms'] as num?)?.toInt();
    final time = (offsetMs != null && sessionStart != null)
        ? sessionStart.add(Duration(milliseconds: offsetMs))
        : DateTime.tryParse('${r['created_at']}') ?? DateTime.now();
    return Shot(
      id: '${r['id']}',
      shotNumber: (r['shot_no'] as num).toInt(),
      seriesNo: (r['series_no'] as num?)?.toInt() ?? 1,
      xMm: (r['x_mm'] as num?)?.toDouble() ?? 0,
      yMm: (r['y_mm'] as num?)?.toDouble() ?? 0,
      score: (r['final_score'] as num).toDouble(),
      time: time,
      isManuallyEdited: r['is_manually_corrected'] == true,
      counts: r['counts'] != false,
      extra: extraFromJson(r['extra']),
    );
  }

  static DateTime? _dateOrNull(Object? v) => v is String ? DateTime.tryParse(v) : null;

  // ---- Токены доступа тренеру ----
  //
  // Реальные имена RPC отличаются от того, что ожидал старый код
  // (`create_share_token`/`revoke_share_token` не существуют — см.
  // docs/db-schema-actual.md): хеширование токена — отдельная функция
  // `hash_share_token`, саму строку в `share_grants` пишет клиент.

  /// Генерирует токен на устройстве, просит базу его захешировать
  /// (`hash_share_token` — чтобы механизм хеширования совпадал с тем,
  /// что использует `validate_share_token` на сервере) и сохраняет
  /// только хеш. Открытый вид токена возвращается вызывающему коду
  /// ОДИН РАЗ и нигде больше не сохраняется.
  Future<String> createShareToken(AppDataStore store, {String athleteLabel = ''}) async {
    final token = await _requireToken();
    final plainToken = _randomToken();
    final client = clientFactory();
    try {
      final hashRes = await client
          .post(
            Uri.parse('${auth.url}/rest/v1/rpc/hash_share_token'),
            headers: _headers(token),
            body: jsonEncode({'p_token': plainToken}),
          )
          .timeout(const Duration(seconds: 20));
      if (hashRes.statusCode >= 400) {
        throw SupabaseSyncException(_errorMessage(hashRes.body, hashRes.statusCode));
      }
      final tokenHash = jsonDecode(utf8.decode(hashRes.bodyBytes));
      await _upsert(token, 'share_grants', [
        {
          'token_hash': tokenHash is String ? tokenHash : '$tokenHash',
          'label': athleteLabel,
          'permissions': ['read'],
        }
      ]);
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
            Uri.parse('${auth.url}/rest/v1/rpc/revoke_share_grant'),
            headers: _headers(token),
            body: jsonEncode({'p_share_grant_id': grantId}),
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
    final rows = await _select(token, 'share_grants?select=id,token_hash,label,created_at,revoked_at');
    store.replaceShareGrants([
      for (final row in rows)
        ShareGrant(
          id: '${row['id']}',
          tokenHash: '${row['token_hash']}',
          athleteLabel: '${row['label'] ?? ''}',
          createdAt: DateTime.parse(row['created_at'] as String),
          revokedAt: _dateOrNull(row['revoked_at']),
        ),
    ]);
  }

  static String _randomToken() {
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
