-- local_schema.sql — локальная БД sqlite3 (LocalDbService).
-- Задача 1.3 dev-task-spec.md. Идемпотентно: IF NOT EXISTS везде,
-- повторный накат на уже существующую БД не падает.

CREATE TABLE IF NOT EXISTS project_settings (
  id                  INTEGER PRIMARY KEY CHECK (id = 1), -- одна строка
  is_athlete          INTEGER NOT NULL DEFAULT 1,
  is_coach            INTEGER NOT NULL DEFAULT 0,
  work_mode           TEXT NOT NULL DEFAULT 'athlete' CHECK (work_mode IN ('athlete','coach')),
  storage_keep_count  INTEGER NOT NULL DEFAULT 200,
  supabase_url        TEXT,
  supabase_anon_key   TEXT,
  connected_email     TEXT,
  -- Сессия Supabase Auth личной базы. Токены лежат здесь, а не в
  -- памяти: иначе каждый запуск приложения требовал бы пароль, а
  -- пользователь просил обратного — вход один раз.
  auth_user_id        TEXT,
  auth_access_token   TEXT,
  auth_refresh_token  TEXT,
  auth_expires_at     TEXT,
  -- Подключение ТРЕНЕРА к базе спортсмена — отдельно от supabase_url/
  -- supabase_anon_key выше (собственная база этого устройства).
  coach_supabase_url       TEXT,
  coach_supabase_anon_key  TEXT,
  coach_share_token        TEXT
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
  series           TEXT,
  -- Время последней правки. Нужно синхронизации: при расхождении
  -- выигрывает более поздняя запись.
  updated_at       TEXT
);

CREATE TABLE IF NOT EXISTS training_sessions (
  id                TEXT PRIMARY KEY,
  exercise_id       TEXT NOT NULL REFERENCES exercises(id),
  target_face_code  TEXT NOT NULL REFERENCES target_faces(code),
  status            TEXT NOT NULL DEFAULT 'notStarted'
                     CHECK (status IN ('notStarted','running','paused','finished')),
  started_at        TEXT,
  finished_at       TEXT,
  pause_intervals   TEXT NOT NULL DEFAULT '[]', -- JSON [{paused_at, resumed_at}]
  synced_to_cloud   INTEGER NOT NULL DEFAULT 0,
  created_at        TEXT NOT NULL DEFAULT (datetime('now')),
  -- Показатели, которых нет в колонках: из SCATT сюда уезжают скорость,
  -- стабильность прицеливания, темп, настройки прибора. JSON-строка.
  -- В интерфейсе не показывается — это материал для ассистента.
  extra             TEXT,
  updated_at        TEXT
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
  is_trashed          INTEGER NOT NULL DEFAULT 0, -- корзина текущей тренировки (B.5)
  -- Показатели выстрела из внешних приборов (время прицеливания,
  -- удержание, скорость). JSON-строка, приложением не толкуется.
  extra               TEXT,
  -- Идёт ли выстрел в зачёт. Пристрелка пишется и видна на мишени, но
  -- в сумму и статистику не входит. Флаг на ВЫСТРЕЛЕ, а не только в
  -- описании упражнения: шаблон могут потом поменять, а уже отстрелянная
  -- тренировка должна остаться такой, какой была.
  counts              INTEGER NOT NULL DEFAULT 1,
  updated_at          TEXT
);

CREATE INDEX IF NOT EXISTS idx_shots_session ON shots(session_id);

-- 'coach' — отдельный от 'session' уровень: страница "Тренер" читает и
-- пишет ИМЕННО его, без фильтра по автору. Раньше страница фильтровала
-- 'session' по author_role=coach, и сообщение спортсмена, отправленное
-- прямо оттуда, тут же пропадало из вида (не от того автора) и
-- всплывало в общей ленте "Заметки" — при том, что задумывался
-- двусторонний чат.
CREATE TABLE IF NOT EXISTS comments (
  id           TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL REFERENCES training_sessions(id) ON DELETE CASCADE,
  level        TEXT NOT NULL CHECK (level IN ('shot','series','session','coach')),
  shot_id      TEXT REFERENCES shots(id) ON DELETE CASCADE,
  series_no    INTEGER,
  author_role  TEXT NOT NULL CHECK (author_role IN ('athlete','coach')),
  text         TEXT NOT NULL,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_comments_session ON comments(session_id);
CREATE INDEX IF NOT EXISTS idx_comments_shot ON comments(shot_id);

-- Заметки — самостоятельный дневник, не привязанный к тренировке.
-- Имя с приставкой training_ — чтобы совпадать с облачной схемой, где
-- простое «notes» слишком легко сталкивается с чужой таблицей.
-- Тема придумывается ассистентом при сохранении, но остаётся обычным
-- редактируемым текстом. Удаление двухступенчатое: сначала корзина,
-- очистка корзины удаляет строку насовсем.
CREATE TABLE IF NOT EXISTS training_notes (
  id           TEXT PRIMARY KEY,
  topic        TEXT NOT NULL DEFAULT '',
  body         TEXT NOT NULL DEFAULT '',
  is_favorite  INTEGER NOT NULL DEFAULT 0,
  is_trashed   INTEGER NOT NULL DEFAULT 0,
  trashed_at   TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT
);

CREATE INDEX IF NOT EXISTS idx_training_notes_trashed ON training_notes(is_trashed);

CREATE TABLE IF NOT EXISTS share_grants (
  id            TEXT PRIMARY KEY,
  token_hash    TEXT NOT NULL,
  athlete_label TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  revoked_at    TEXT
);

-- color_prefs — ЧИСТО ЛОКАЛЬНАЯ таблица (часть A.2 логики-спека), не
-- входит в sql/schema.sql (Supabase) и не синхронизируется в облако.
CREATE TABLE IF NOT EXISTS color_prefs (
  key  TEXT PRIMARY KEY,
  hex  TEXT NOT NULL -- формат #RRGGBB или #AARRGGBB
);

-- Справочник мишеней — сидируется один раз при первом запуске
-- (см. LocalDbService.seedTargetFaces), приложение стартует иначе
-- полностью пустым (раздел 10 ТЗ: без демо-тренировок и упражнений).
INSERT OR IGNORE INTO target_faces (code, name, distance_m, caliber_mm, bullseye_diameter_mm, blank_size_mm) VALUES
  ('rifle_10m', '№ 8, пневматическая винтовка 10 м', 10, 4.5, 30.5, 80),
  ('pistol_10m', '№ 9, пневматический пистолет 10 м', 10, 4.5, 59.5, 170),
  ('rifle_50m', '№ 7, малокалиберная винтовка 50 м', 50, 5.6, 112.4, 250),
  ('pistol_25m', '№ 4, пистолет 25 м', 25, 5.6, 200, 550);

-- Правка чисел в уже созданных базах: INSERT OR IGNORE существующие
-- строки не трогает, а в первых версиях сюда попали неверные значения
-- (бланк № 8 — 170 вместо 80, яблоко пистолетной — 26.5 вместо 59.5,
-- мишень 50 м была подписана «№ 12» вместо «№ 7»). На расчёты это не
-- влияет — геометрия живёт в константах TargetFace, — но справочник,
-- который врёт, однажды кто-нибудь прочитает.
UPDATE target_faces SET name = '№ 8, пневматическая винтовка 10 м', bullseye_diameter_mm = 30.5, blank_size_mm = 80
  WHERE code = 'rifle_10m';

UPDATE target_faces SET name = '№ 9, пневматический пистолет 10 м', bullseye_diameter_mm = 59.5, blank_size_mm = 170
  WHERE code = 'pistol_10m';

UPDATE target_faces SET name = '№ 7, малокалиберная винтовка 50 м'
  WHERE code = 'rifle_50m';
