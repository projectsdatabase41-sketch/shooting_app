import 'package:flutter/services.dart' show rootBundle;
import 'package:sqlite3/common.dart';

import 'db_opener.dart';

/// Обёртка над sqlite3 (без кодогенерации — раздел 0.1 dev-task-spec.md,
/// Dart SDK/build_runner недоступны в среде первичной разработки).
/// Единственная точка доступа к БД — экраны/виджеты никогда не делают
/// SQL напрямую (задача 0.2, DoD структуры проекта).
class LocalDbService {
  /// `CommonDatabase`, а не `Database`: это общий интерфейс пакета
  /// sqlite3, который одинаково реализуют и нативная база (файл на
  /// диске), и wasm-сборка в браузере (файл в IndexedDB). Весь
  /// остальной код работает через `select`/`execute` и о разнице не
  /// знает.
  CommonDatabase? _db;

  CommonDatabase get db {
    final d = _db;
    if (d == null) {
      throw StateError('LocalDbService.open() ещё не вызван');
    }
    return d;
  }

  Future<void> open({String? overridePath}) async {
    if (_db != null) return;
    // Где именно откроется база, решает платформа — см. db_opener.dart.
    _db = await openAppDatabase(overridePath: overridePath);
    await _migrate();
    // Схема только что накатилась — в браузере её надо сразу закрепить
    // в IndexedDB, иначе при быстром закрытии вкладки следующая сессия
    // получит пустую базу и накатит миграцию заново.
    await flush();
  }

  /// Закрепляет записанное в постоянном хранилище.
  ///
  /// На Windows и Android — пустая операция: sqlite пишет в файл сам.
  /// В браузере — реальный сброс IndexedDB, см. `db_opener_web.dart`.
  Future<void> flush() => flushDatabase();

  Future<void> _migrate() async {
    final sqlFile = await _loadSchemaSql();
    // Каждый CREATE TABLE IF NOT EXISTS / INSERT OR IGNORE — идемпотентен
    // (задача 1.3 DoD: повторный накат на существующую БД не падает).
    for (final statement in _splitStatements(sqlFile)) {
      final s = statement.trim();
      if (s.isEmpty) continue;
      db.execute(s);
    }
    _addMissingColumns();
  }

  /// Догоняет схему на УЖЕ СОЗДАННОЙ базе.
  ///
  /// `CREATE TABLE IF NOT EXISTS` на существующей таблице не делает
  /// ничего — новая колонка из схемы к пользователю, который поставил
  /// приложение раньше, так и не доедет. `ALTER TABLE ADD COLUMN`
  /// повторно тоже не выполнить: sqlite ответит «duplicate column».
  /// Поэтому спрашиваем `PRAGMA table_info` и добавляем только то,
  /// чего нет.
  ///
  /// Список ниже — только колонки, добавленные ПОСЛЕ первого релиза.
  /// Всё, что было изначально, приезжает обычным CREATE TABLE.
  void _addMissingColumns() {
    const additions = <String, Map<String, String>>{
      'exercises': {'deleted_at': 'TEXT', 'series': 'TEXT'},
      'shots': {'extra': 'TEXT', 'counts': 'INTEGER NOT NULL DEFAULT 1'},
      'training_sessions': {'extra': 'TEXT'},
    };

    for (final table in additions.keys) {
      final existing = <String>{
        for (final row in db.select('PRAGMA table_info($table)')) '${row['name']}',
      };
      // Таблицы нет вовсе (её создаст схема) — PRAGMA вернёт пусто.
      if (existing.isEmpty) continue;
      additions[table]!.forEach((column, type) {
        if (existing.contains(column)) return;
        db.execute('ALTER TABLE $table ADD COLUMN $column $type');
      });
    }
  }

  Future<String> _loadSchemaSql() async {
    try {
      // lib/db/local_schema.sql упакован как asset (pubspec.yaml) — это
      // единственный источник истины для схемы.
      return await rootBundle.loadString('lib/db/local_schema.sql');
    } catch (_) {
      // Фолбэк на встроенную копию — на случай запуска вне обычного
      // Flutter asset-бандла (например, из unit-теста без binding).
      return _embeddedSchema;
    }
  }

  List<String> _splitStatements(String sql) {
    // Простой сплиттер по ';' в конце строки — схема не использует
    // сложные хранимые процедуры/триггеры с внутренними ';'.
    return sql.split(';\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  void close() {
    _db?.close();
    _db = null;
  }

  static const String _embeddedSchema = r'''
CREATE TABLE IF NOT EXISTS project_settings (
  id                  INTEGER PRIMARY KEY CHECK (id = 1),
  is_athlete          INTEGER NOT NULL DEFAULT 1,
  is_coach            INTEGER NOT NULL DEFAULT 0,
  work_mode           TEXT NOT NULL DEFAULT 'athlete' CHECK (work_mode IN ('athlete','coach')),
  storage_keep_count  INTEGER NOT NULL DEFAULT 200,
  supabase_url        TEXT,
  supabase_anon_key   TEXT,
  connected_email     TEXT
);

CREATE TABLE IF NOT EXISTS target_faces (
  code                  TEXT PRIMARY KEY,
  name                  TEXT NOT NULL,
  distance_m            REAL NOT NULL,
  caliber_mm            REAL NOT NULL,
  bullseye_diameter_mm  REAL NOT NULL,
  blank_size_mm         REAL
);

CREATE TABLE IF NOT EXISTS exercises (
  id               TEXT PRIMARY KEY,
  code             TEXT NOT NULL,
  name             TEXT NOT NULL,
  target_face_code TEXT NOT NULL REFERENCES target_faces(code),
  total_shots      INTEGER NOT NULL,
  series_size      INTEGER NOT NULL,
  gender           TEXT NOT NULL DEFAULT 'mixed' CHECK (gender IN ('male','female','mixed')),
  created_at       TEXT NOT NULL DEFAULT (datetime('now')),
  -- Мягкое удаление: упражнение уходит из выбора при создании
  -- тренировки, но остаётся в базе, чтобы прошлые тренировки не
  -- потеряли название. Прямое удаление строки невозможно —
  -- training_sessions.exercise_id ссылается на неё.
  deleted_at       TEXT,
  -- Описание серий: JSON-массив {name, shot_count, time_limit_s,
  -- counts}. Пусто — упражнение старого вида, все серии одинаковы.
  series           TEXT
);

CREATE TABLE IF NOT EXISTS training_sessions (
  id                TEXT PRIMARY KEY,
  exercise_id       TEXT NOT NULL REFERENCES exercises(id),
  target_face_code  TEXT NOT NULL REFERENCES target_faces(code),
  status            TEXT NOT NULL DEFAULT 'notStarted' CHECK (status IN ('notStarted','running','paused','finished')),
  started_at        TEXT,
  finished_at       TEXT,
  pause_intervals   TEXT NOT NULL DEFAULT '[]',
  synced_to_cloud   INTEGER NOT NULL DEFAULT 0,
  created_at        TEXT NOT NULL DEFAULT (datetime('now')),
  -- Показатели, которых нет в колонках: из SCATT сюда уезжают скорость,
  -- стабильность прицеливания, темп, настройки прибора. JSON-строка.
  extra             TEXT
);

CREATE TABLE IF NOT EXISTS shots (
  id                  TEXT PRIMARY KEY,
  session_id          TEXT NOT NULL REFERENCES training_sessions(id) ON DELETE CASCADE,
  shot_number         INTEGER NOT NULL,
  series_no           INTEGER NOT NULL,
  x_mm                REAL NOT NULL,
  y_mm                REAL NOT NULL,
  score                REAL NOT NULL,
  time                TEXT NOT NULL,
  is_favorite         INTEGER NOT NULL DEFAULT 0,
  is_manually_edited  INTEGER NOT NULL DEFAULT 0,
  is_trashed          INTEGER NOT NULL DEFAULT 0,
  extra               TEXT,
  -- Идёт ли выстрел в зачёт. Пристрелка пишется и видна на мишени, но
  -- в сумму и статистику не входит. Флаг на ВЫСТРЕЛЕ, а не только в
  -- описании упражнения: шаблон могут потом поменять, а уже отстрелянная
  -- тренировка должна остаться такой, какой была.
  counts              INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_shots_session ON shots(session_id);

CREATE TABLE IF NOT EXISTS comments (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL REFERENCES training_sessions(id) ON DELETE CASCADE,
  level        TEXT NOT NULL CHECK (level IN ('shot','series','session')),
  shot_id      TEXT REFERENCES shots(id) ON DELETE CASCADE,
  series_no    INTEGER,
  author_role  TEXT NOT NULL CHECK (author_role IN ('athlete','coach')),
  text         TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_comments_session ON comments(session_id);
CREATE INDEX IF NOT EXISTS idx_comments_shot ON comments(shot_id);

CREATE TABLE IF NOT EXISTS share_grants (
  id            TEXT PRIMARY KEY,
  token_hash    TEXT NOT NULL,
  athlete_label TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  revoked_at    TEXT
);

CREATE TABLE IF NOT EXISTS color_prefs (
  key  TEXT PRIMARY KEY,
  hex  TEXT NOT NULL
);

INSERT OR IGNORE INTO target_faces (code, name, distance_m, caliber_mm, bullseye_diameter_mm, blank_size_mm) VALUES
  ('rifle_10m', '№ 8, пневматическая винтовка 10 м', 10, 4.5, 30.5, 170),
  ('pistol_10m', 'Пневматический пистолет 10 м', 10, 4.5, 26.5, NULL),
  ('rifle_50m', '№ 12, малокалиберная винтовка 50 м', 50, 5.6, 112.4, 250),
  ('pistol_25m', '№ 4, пистолет 25 м', 25, 5.6, 200, 550);
''';
}
