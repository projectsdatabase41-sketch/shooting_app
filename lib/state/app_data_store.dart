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

  List<TrainingSession> get unsyncedSessions =>
      sessions.where((s) => !s.syncedToCloud && s.status == SessionStatus.finished).toList();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
