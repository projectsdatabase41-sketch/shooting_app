import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/exercise.dart';
import '../models/series_spec.dart';
import '../models/share_grant.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../models/shot.dart';
import '../services/local_db_service.dart';

enum WorkMode { athlete, coach }

/// Общее хранилище упражнений и тренировок на устройстве. Приложение
/// стартует полностью пустым — ни демо-тренировок, ни готовых
/// упражнений (раздел 10 ТЗ).
class AppDataStore extends ChangeNotifier {
  final LocalDbService db;
  static const _uuid = Uuid();

  AppDataStore(this.db);

  bool isAthlete = true;
  bool isCoach = false;
  WorkMode _workMode = WorkMode.athlete;

  WorkMode get workMode {
    // Если включена только одна роль — workMode жёстко равен ей (C.1).
    if (!(isAthlete && isCoach)) {
      return isAthlete ? WorkMode.athlete : WorkMode.coach;
    }
    return _workMode;
  }

  set workMode(WorkMode mode) {
    if (!(isAthlete && isCoach)) return; // переключатель не рендерится/не действует
    _workMode = mode;
    notifyListeners();
  }

  List<Exercise> exercises = [];
  List<TrainingSession> sessions = [];
  List<ShareGrant> shareGrants = [];
  /// Сколько тренировок держать на устройстве.
  ///
  /// 0 — не держать вовсе (только облако), [keepAll] — держать всё.
  /// Промежуточные значения вводит пользователь сам.
  int storageKeepCount = 200;

  /// Значение «хранить всё». Не `null` и не −1, чтобы поле в базе
  /// оставалось обычным целым и не требовало отдельной проверки при
  /// каждом чтении.
  static const int keepAll = 1000000;

  void loadAll() {
    _loadSettings();
    _loadExercises();
    _loadSessions();
    _loadShareGrants();
    notifyListeners();
  }

  void _loadSettings() {
    final rows = db.db.select('SELECT * FROM project_settings WHERE id = 1');
    if (rows.isNotEmpty) {
      final row = rows.first;
      isAthlete = row['is_athlete'] == 1;
      isCoach = row['is_coach'] == 1;
      _workMode = (row['work_mode'] as String) == 'coach'
          ? WorkMode.coach
          : WorkMode.athlete;
      storageKeepCount = row['storage_keep_count'] as int;
    } else {
      db.db.execute(
        'INSERT INTO project_settings (id, is_athlete, is_coach, work_mode, storage_keep_count) '
        'VALUES (1, 1, 0, ?, 200)',
        ['athlete'],
      );
    }
  }

  void saveSettings() {
    db.db.execute(
      'UPDATE project_settings SET is_athlete = ?, is_coach = ?, work_mode = ?, storage_keep_count = ? WHERE id = 1',
      [isAthlete ? 1 : 0, isCoach ? 1 : 0, _workMode.name, storageKeepCount],
    );
  }

  void _loadExercises() {
    final rows = db.db.select('SELECT * FROM exercises ORDER BY created_at DESC');
    exercises = rows.map((r) => Exercise(
          id: r['id'] as String,
          name: r['name'] as String,
          targetFaceCode: r['target_face_code'] as String,
          totalShots: r['total_shots'] as int,
          seriesSize: r['series_size'] as int,
          gender: ExerciseGender.values.firstWhere(
            (g) => g.name == r['gender'],
            orElse: () => ExerciseGender.mixed,
          ),
          deletedAt: r['deleted_at'] == null
              ? null
              : DateTime.tryParse('${r['deleted_at']}'),
          series: seriesFromJson(r['series']),
        )).toList();
  }

  /// Упражнения для выбора при создании тренировки — без удалённых.
  ///
  /// Сам список `exercises` остаётся полным: истории и ассистенту нужны
  /// названия удалённых упражнений, иначе прошлые тренировки станут
  /// безымянными — а пользователь просил их сохранить.
  List<Exercise> get activeExercises => exercises.where((e) => !e.isDeleted).toList();

  /// Мягко удаляет упражнение. Тренировки не трогаются.
  void deleteExercise(String id) {
    final now = DateTime.now();
    db.db.execute('UPDATE exercises SET deleted_at = ? WHERE id = ?', [now.toIso8601String(), id]);
    exercises = [
      for (final e in exercises) e.id == id ? e.copyWith(deletedAt: now) : e,
    ];
    notifyListeners();
  }

  /// Возвращает удалённое упражнение обратно в список.
  ///
  /// Нужна для «Отменить» в снекбаре: подтверждение подтверждением, а
  /// промахнуться по кнопке всё равно можно, и восстановление здесь —
  /// одна строка, в отличие от восстановления тренировки.
  void restoreExercise(String id) {
    db.db.execute('UPDATE exercises SET deleted_at = NULL WHERE id = ?', [id]);
    exercises = [
      for (final e in exercises)
        e.id == id
            ? Exercise(
                id: e.id,
                name: e.name,
                targetFaceCode: e.targetFaceCode,
                totalShots: e.totalShots,
                seriesSize: e.seriesSize,
                gender: e.gender,
                series: e.series,
              )
            : e,
    ];
    notifyListeners();
  }

  /// Полностью удаляет тренировку — вместе с выстрелами и заметками.
  ///
  /// Здесь удаление именно физическое, как и просил пользователь:
  /// «вообще удалить и из базы». Выстрелы и комментарии уезжают по
  /// внешнему ключу с `ON DELETE CASCADE`, но полагаться на это нельзя:
  /// в sqlite контроль внешних ключей по умолчанию ВЫКЛЮЧЕН, и без
  /// явного удаления в базе остались бы висячие строки.
  void deleteSession(String id) {
    db.db.execute('BEGIN');
    try {
      db.db.execute('DELETE FROM comments WHERE session_id = ?', [id]);
      db.db.execute('DELETE FROM shots WHERE session_id = ?', [id]);
      db.db.execute('DELETE FROM training_sessions WHERE id = ?', [id]);
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      rethrow;
    }
    sessions = [for (final s in sessions) if (s.id != id) s];
    notifyListeners();
  }

  Exercise createExercise({
    required String name,
    required String targetFaceCode,
    required int totalShots,
    required int seriesSize,
    ExerciseGender gender = ExerciseGender.mixed,
    List<SeriesSpec> series = const [],
  }) {
    final ex = Exercise(
      id: _uuid.v4(),
      name: name,
      targetFaceCode: targetFaceCode,
      totalShots: totalShots,
      seriesSize: seriesSize,
      gender: gender,
      series: series,
    );
    db.db.execute(
      'INSERT INTO exercises (id, code, name, target_face_code, total_shots, series_size, gender, series) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        ex.id,
        // Колонка code осталась в таблице и объявлена NOT NULL: убрать
        // её из sqlite можно только пересозданием таблицы, а ради
        // неиспользуемого поля это лишний риск для чужих баз. Пишем в
        // неё название — модель код больше не читает.
        ex.name,
        ex.name,
        ex.targetFaceCode,
        ex.totalShots,
        ex.seriesSize,
        ex.gender.name,
        ex.series.isEmpty ? null : seriesToJson(ex.series),
      ],
    );
    exercises = [ex, ...exercises];
    notifyListeners();
    return ex;
  }

  void _loadSessions() {
    final sessionRows = db.db.select('SELECT * FROM training_sessions ORDER BY started_at DESC');
    sessions = sessionRows.map((r) {
      final id = r['id'] as String;
      final shotRows = db.db.select(
        'SELECT * FROM shots WHERE session_id = ? AND is_trashed = 0 ORDER BY shot_number',
        [id],
      );
      final trashRows = db.db.select(
        'SELECT * FROM shots WHERE session_id = ? AND is_trashed = 1 ORDER BY shot_number',
        [id],
      );
      return TrainingSession(
        id: id,
        exerciseId: r['exercise_id'] as String,
        targetFaceCode: r['target_face_code'] as String,
        status: SessionStatus.values.firstWhere((s) => s.name == r['status']),
        startedAt: r['started_at'] == null ? null : DateTime.parse(r['started_at'] as String),
        finishedAt: r['finished_at'] == null ? null : DateTime.parse(r['finished_at'] as String),
        shots: shotRows.map(_shotFromRow).toList(),
        trash: trashRows.map(_shotFromRow).toList(),
        syncedToCloud: r['synced_to_cloud'] == 1,
        extra: extraFromJson(r['extra']),
      );
    }).toList();
  }

  Shot _shotFromRow(Map<String, dynamic> r) => Shot(
        id: r['id'] as String,
        shotNumber: r['shot_number'] as int,
        seriesNo: r['series_no'] as int,
        xMm: (r['x_mm'] as num).toDouble(),
        yMm: (r['y_mm'] as num).toDouble(),
        score: (r['score'] as num).toDouble(),
        time: DateTime.parse(r['time'] as String),
        isFavorite: r['is_favorite'] == 1,
        isManuallyEdited: r['is_manually_edited'] == 1,
        counts: r['counts'] == null || r['counts'] == 1,
        extra: extraFromJson(r['extra']),
      );

  /// Полностью заменяет локальное зеркало токенов данными с сервера —
  /// сервер здесь источник истины (токен можно отозвать и с другого
  /// устройства), а не локальная база.
  void replaceShareGrants(List<ShareGrant> grants) {
    db.db.execute('DELETE FROM share_grants');
    for (final g in grants) {
      db.db.execute(
        'INSERT INTO share_grants (id, token_hash, athlete_label, created_at, revoked_at) VALUES (?, ?, ?, ?, ?)',
        [g.id, g.tokenHash, g.athleteLabel, g.createdAt.toIso8601String(), g.revokedAt?.toIso8601String()],
      );
    }
    _loadShareGrants();
    notifyListeners();
  }

  void _loadShareGrants() {
    // UI спортсмена показывает только активные — не запрашиваем
    // отозванные вовсе (C.5), проще SQL без клиентской фильтрации.
    final rows = db.db.select('SELECT * FROM share_grants WHERE revoked_at IS NULL');
    shareGrants = rows
        .map((r) => ShareGrant(
              id: r['id'] as String,
              tokenHash: r['token_hash'] as String,
              athleteLabel: r['athlete_label'] as String? ?? '',
              createdAt: DateTime.parse(r['created_at'] as String),
              revokedAt: null,
            ))
        .toList();
  }

  /// Сохраняет тренировку целиком (используется TargetViewModel при
  /// завершении/уходе с экрана, а также restore из корзины и т.д.).
  /// "Тренировка-призрак" (B.6) — пустая сессия не сохраняется вовсе.
  void upsertSession(TrainingSession session) {
    if (session.shots.isEmpty) {
      // "Тренировка-призрак" (B.6) — активных выстрелов нет, сессия не
      // сохраняется вовсе, даже если в корзине что-то есть.
      return;
    }
    db.db.execute('BEGIN');
    try {
      db.db.execute(
        'INSERT INTO training_sessions (id, exercise_id, target_face_code, status, started_at, finished_at, pause_intervals, synced_to_cloud, extra) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET status=excluded.status, started_at=excluded.started_at, '
        'finished_at=excluded.finished_at, pause_intervals=excluded.pause_intervals, '
        'synced_to_cloud=excluded.synced_to_cloud, extra=excluded.extra',
        [
          session.id,
          session.exerciseId,
          session.targetFaceCode,
          session.status.name,
          session.startedAt?.toIso8601String(),
          session.finishedAt?.toIso8601String(),
          '[]',
          session.syncedToCloud ? 1 : 0,
          session.extra == null ? null : jsonEncode(session.extra),
        ],
      );
      db.db.execute('DELETE FROM shots WHERE session_id = ?', [session.id]);
      for (final shot in session.shots) {
        _insertShot(session.id, shot, trashed: false);
      }
      for (final shot in session.trash) {
        _insertShot(session.id, shot, trashed: true);
      }
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      rethrow;
    }
    final idx = sessions.indexWhere((s) => s.id == session.id);
    if (idx == -1) {
      sessions = [session, ...sessions];
    } else {
      sessions = [...sessions]..[idx] = session;
    }
    notifyListeners();
  }

  void _insertShot(String sessionId, Shot shot, {required bool trashed}) {
    db.db.execute(
      'INSERT INTO shots (id, session_id, shot_number, series_no, x_mm, y_mm, score, time, is_favorite, is_manually_edited, is_trashed, extra, counts) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        shot.id,
        sessionId,
        shot.shotNumber,
        shot.seriesNo,
        shot.xMm,
        shot.yMm,
        shot.score,
        shot.time.toIso8601String(),
        shot.isFavorite ? 1 : 0,
        shot.isManuallyEdited ? 1 : 0,
        trashed ? 1 : 0,
        shot.extra == null ? null : jsonEncode(shot.extra),
        shot.counts ? 1 : 0,
      ],
    );
  }

  /// Тренировка-призрак: если она уже была где-то персистентно
  /// зафиксирована (не должна была быть, но на всякий случай) — удаляет.
  void discardGhost(String sessionId) {
    db.db.execute('DELETE FROM training_sessions WHERE id = ?', [sessionId]);
    sessions.removeWhere((s) => s.id == sessionId);
  }

  TargetFace targetFaceFor(TrainingSession session) =>
      TargetFace.byCode(session.targetFaceCode);

  Exercise? exerciseFor(TrainingSession session) =>
      exercises.where((e) => e.id == session.exerciseId).firstOrNull;

  /// Просит перерисоваться без изменения данных — например, после того
  /// как `SupabaseSyncService` добавил комментарии в обход этого
  /// класса (он читает их напрямую из БД, не через кеш в памяти).
  void refreshView() => notifyListeners();

  List<TrainingSession> get unsyncedSessions =>
      sessions.where((s) => !s.syncedToCloud && s.status == SessionStatus.finished).toList();

  /// Помечает тренировку отправленной — после успешного push, чтобы
  /// `unsyncedSessions` не пыталась отправить её ещё раз.
  void markSessionSynced(String id) {
    db.db.execute('UPDATE training_sessions SET synced_to_cloud = 1 WHERE id = ?', [id]);
    final idx = sessions.indexWhere((s) => s.id == id);
    if (idx != -1) {
      sessions = [...sessions]..[idx] = sessions[idx].copyWith(syncedToCloud: true);
      notifyListeners();
    }
  }

  /// Заводит упражнение, пришедшее с сервера при pull — ТОЛЬКО если его
  /// ещё нет локально по id.
  ///
  /// Не трогаем уже существующее: упражнение могли переименовать на
  /// этом же устройстве уже ПОСЛЕ последней отправки, и слепая
  /// перезапись стёрла бы правку, которую сервер ещё не видел.
  void upsertExerciseFromRemote(Map<String, dynamic> row) {
    if (exercises.any((e) => e.id == row['id'])) return;
    final ex = Exercise(
      id: row['id'] as String,
      name: row['name'] as String,
      targetFaceCode: row['target_face_code'] as String,
      totalShots: row['total_shots'] as int,
      seriesSize: row['series_size'] as int,
      gender: ExerciseGender.values.firstWhere(
        (g) => g.name == (row['gender'] as String? ?? 'mixed'),
        orElse: () => ExerciseGender.mixed,
      ),
      deletedAt: row['deleted_at'] == null ? null : DateTime.parse(row['deleted_at'] as String),
      series: seriesFromJson(row['series']),
    );
    db.db.execute(
      'INSERT INTO exercises (id, code, name, target_face_code, total_shots, series_size, gender, series, deleted_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        ex.id, ex.name, ex.name, ex.targetFaceCode, ex.totalShots, ex.seriesSize,
        ex.gender.name, ex.series.isEmpty ? null : seriesToJson(ex.series), ex.deletedAt?.toIso8601String(),
      ],
    );
    exercises = [ex, ...exercises];
    notifyListeners();
  }

  /// Заводит тренировку и её выстрелы, пришедшие с сервера при pull —
  /// ТОЛЬКО если такой тренировки ещё нет локально. См. причину в
  /// `upsertExerciseFromRemote`: локальные тренировки завершены и не
  /// редактируются (`canEdit` требует `status != finished`), так что
  /// конфликтовать здесь особо нечему, но перезаписывать существующую
  /// запись данными, которые могли устареть по дороге, всё равно не
  /// нужно — это и так уже наша тренировка, локальная копия главнее.
  void upsertSessionFromRemote(Map<String, dynamic> sessionRow, List<Map<String, dynamic>> shotRows) {
    if (sessions.any((s) => s.id == sessionRow['id'])) return;
    final id = sessionRow['id'] as String;
    db.db.execute('BEGIN');
    try {
      db.db.execute(
        'INSERT INTO training_sessions (id, exercise_id, target_face_code, status, started_at, finished_at, pause_intervals, synced_to_cloud, extra) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)',
        [
          id,
          sessionRow['exercise_id'],
          sessionRow['target_face_code'],
          sessionRow['status'],
          sessionRow['started_at'],
          sessionRow['finished_at'],
          jsonEncode(sessionRow['pause_intervals'] ?? []),
          sessionRow['extra'] == null ? null : jsonEncode(sessionRow['extra']),
        ],
      );
      for (final row in shotRows) {
        db.db.execute(
          'INSERT INTO shots (id, session_id, shot_number, series_no, x_mm, y_mm, score, time, is_favorite, is_manually_edited, is_trashed, extra, counts) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            row['id'], id, row['shot_number'], row['series_no'], row['x_mm'], row['y_mm'], row['score'], row['time'],
            row['is_favorite'] == true ? 1 : 0,
            row['is_manually_edited'] == true ? 1 : 0,
            row['is_trashed'] == true ? 1 : 0,
            row['extra'] == null ? null : jsonEncode(row['extra']),
            row['counts'] == false ? 0 : 1,
          ],
        );
      }
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      rethrow;
    }
    final shots = [for (final r in shotRows) if (r['is_trashed'] != true) _shotFromRemoteRow(r)];
    final trash = [for (final r in shotRows) if (r['is_trashed'] == true) _shotFromRemoteRow(r)];
    sessions = [
      TrainingSession(
        id: id,
        exerciseId: sessionRow['exercise_id'] as String,
        targetFaceCode: sessionRow['target_face_code'] as String,
        status: SessionStatus.values.firstWhere((s) => s.name == sessionRow['status']),
        startedAt: sessionRow['started_at'] == null ? null : DateTime.parse(sessionRow['started_at'] as String),
        finishedAt: sessionRow['finished_at'] == null ? null : DateTime.parse(sessionRow['finished_at'] as String),
        shots: shots,
        trash: trash,
        syncedToCloud: true,
        extra: extraFromJson(sessionRow['extra']),
      ),
      ...sessions,
    ];
    notifyListeners();
  }

  Shot _shotFromRemoteRow(Map<String, dynamic> r) => Shot(
        id: r['id'] as String,
        shotNumber: r['shot_number'] as int,
        seriesNo: r['series_no'] as int,
        xMm: (r['x_mm'] as num).toDouble(),
        yMm: (r['y_mm'] as num).toDouble(),
        score: (r['score'] as num).toDouble(),
        time: DateTime.parse(r['time'] as String),
        isFavorite: r['is_favorite'] == true,
        isManuallyEdited: r['is_manually_edited'] == true,
        counts: r['counts'] != false,
        extra: extraFromJson(r['extra']),
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
