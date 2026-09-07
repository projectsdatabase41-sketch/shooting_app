-- sql/schema.sql — схема ЛИЧНОЙ базы Supabase, КАК ОНА РЕАЛЬНО УСТРОЕНА.
--
-- ВАЖНО, прочитать перед правкой этого файла: до 2026-09-07 этот файл
-- описывал СОВСЕМ ДРУГУЮ, никогда не применённую к живой базе схему
-- (плоские exercises/training_sessions/shots). Реальная база
-- (fiwpmxfonmyadatggtuj) с самого начала была создана по другой,
-- более развёрнутой схеме — training_packages/exercises/
-- exercise_templates и инфраструктура под фото-импорт и дневник
-- тренера через удалённый источник. Расхождение и было причиной
-- ошибки "HTTP 400 PGRST204: Could not find the 'deleted_at' column".
--
-- Реальная структура снята через OpenAPI-описание PostgREST
-- (`GET /rest/v1/` секретным ключом — см. docs/db-schema-actual.md,
-- там же таблица соответствия полей приложения колонкам базы).
-- Этот файл теперь описывает РЕАЛЬНУЮ схему: на уже существующей базе
-- `create table if not exists` ничего не меняет (структура и так
-- совпадает), на свежем проекте — создаёт ровно то же самое с нуля.
--
-- Чего в этом файле НЕТ и почему: RLS-политики и RPC-функции
-- (`is_project_owner`, `hash_share_token`, `revoke_share_grant`,
-- `set_project_status`, `validate_share_token`), которые уже реально
-- работают на живой базе, — их SQL-тела сюда не переписаны, потому что
-- секретный ключ даёт доступ к ОПИСАНИЮ таблиц (OpenAPI), а не к
-- исходному коду функций/политик. `create or replace function` с
-- УГАДАННЫМ телом тут был бы не восстановлением, а подменой рабочей
-- логики — на это в задании прямой запрет (раздел 3.5: "ничего не
-- удалять/трогать лишнее"). Новые таблицы ниже (`comments`,
-- `training_notes`) используют `is_project_owner()` как есть, полагаясь
-- на то, что она уже существует. Ниже также добавлены НОВЫЕ функции
-- `get_shared_*`/`add_shared_comment` (дневник тренера, раздел «Чтение
-- дневника тренером по токену») — имена новые, ничего чужого не
-- переопределяют, построены поверх уже существующей
-- `validate_share_token`.
--
-- Известный открытый вопрос: RLS на всех таблицах требует, чтобы в
-- `project_settings` была строка с `owner_user_id = auth.uid()` —
-- сейчас (2026-09-07) она пуста, и `is_project_owner()` возвращает
-- false для любого запроса. Создать эту первую строку не вышло —
-- колонка `storage_balance` защищена CHECK-ограничением с неизвестным
-- набором допустимых значений (перебор текстом результата не дал).
-- Нужно посмотреть определение ограничения в Table Editor Supabase
-- (project_settings → колонка storage_balance → Constraints) и завести
-- первую строку `project_settings` вручную с подходящим значением —
-- до этого push/pull будут получать HTTP 403 (RLS), это ожидаемо и не
-- баг моста.
--
-- Скрипт идемпотентный: повторный запуск ничего не ломает.
--
-- ВАЖНО: таблица color_prefs сюда НЕ входит — настройки оформления и
-- ассистента чисто локальные и не синхронизируются.

create extension if not exists "pgcrypto";

-- ============================================================
-- Служебное
-- ============================================================

create or replace function touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ============================================================
-- Реальные таблицы — как они уже существуют на живой базе.
-- ============================================================

create table if not exists project_settings (
  id                          uuid primary key default gen_random_uuid(),
  owner_user_id               uuid not null references auth.users(id) on delete cascade,
  project_name                text,
  status                      text not null default 'active',
  paused_at                   timestamptz,
  pause_reason                text,
  is_athlete                  boolean not null default true,
  is_coach                    boolean not null default false,
  keep_local_packages_count   int not null default 200,
  keep_files_after_sync       boolean not null default true,
  sync_only_wifi              boolean not null default false,
  storage_balance             text not null,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create table if not exists target_faces (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null,
  name                text not null,
  distance_m          numeric not null,
  default_caliber_mm  numeric not null,
  scoring_type        text not null default 'decimal',
  max_score           numeric not null default 10.9,
  ring_config         jsonb not null,
  is_system           boolean not null default true,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Уникальность кода — таблица была пуста на момент добавления
-- ограничения, конфликтов со старыми данными нет.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'target_faces_code_key'
  ) then
    alter table target_faces add constraint target_faces_code_key unique (code);
  end if;
end
$$;

create table if not exists exercise_templates (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null,
  name                text not null,
  weapon_type         text not null,
  ammo_type           text not null,
  distance_m          numeric not null,
  shots_count         int not null,
  series_count        int,
  shots_per_series    int,
  target_face_id      uuid references target_faces(id),
  time_limit_minutes  int,
  official_code       text,
  is_custom           boolean not null default true,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Снимок ОДНОГО исполнения упражнения внутри пакета — не то же самое,
-- что exercise_templates (справочник-каталог). У пакета в этой схеме
-- может быть несколько таких строк, приложение пишет ровно одну на
-- тренировку (см. docs/db-schema-actual.md).
create table if not exists exercises (
  id                    uuid primary key default gen_random_uuid(),
  package_id            uuid not null references training_packages(id) on delete cascade,
  exercise_name         text,
  discipline            text not null,
  distance_meters       numeric not null,
  target_face_id        uuid references target_faces(id),
  decimal_scoring       boolean not null default true,
  expected_shots        int,
  started_at            timestamptz,
  time_is_approximate   boolean not null default false,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create table if not exists training_packages (
  id                          uuid primary key default gen_random_uuid(),
  started_at                  timestamptz not null,
  ended_at                    timestamptz,
  time_is_approximate         boolean not null default false,
  local_time_offset_minutes   int,
  title                       text,
  location                    text,
  note                        text,
  package_status              text not null,
  editor_mode                 text not null default 'athlete',
  is_locked_by_athlete        boolean not null default true,
  local_version               int not null default 1,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create table if not exists shots (
  id                     uuid primary key default gen_random_uuid(),
  exercise_id            uuid not null references exercises(id) on delete cascade,
  shot_no                int not null,
  series_no              int,
  x_mm                   numeric,
  y_mm                   numeric,
  input_angle_degrees    numeric,
  coordinate_source      text not null default 'app',
  reported_score         numeric,
  computed_score         numeric,
  final_score            numeric not null,
  source                 text not null default 'app',
  photo_import_id        uuid references photo_import_jobs(id),
  is_manually_corrected  boolean not null default false,
  confirmed              boolean not null default true,
  shot_time_ms           bigint,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index if not exists idx_shots_exercise on shots(exercise_id);

create table if not exists remote_athlete_sources (
  id                       uuid primary key default gen_random_uuid(),
  athlete_label            text not null,
  project_url              text not null,
  access_token_reference   text,
  status                   text not null default 'active',
  last_fetched_at          timestamptz,
  last_error               text,
  archive_enabled          boolean not null default false,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create table if not exists archived_packages (
  id                    uuid primary key default gen_random_uuid(),
  remote_source_id      uuid references remote_athlete_sources(id),
  original_package_id   uuid not null,
  athlete_label         text,
  source_project_url    text,
  started_at            timestamptz,
  fetched_at            timestamptz not null default now(),
  package_json          jsonb not null,
  checksum              text,
  note                  text,
  created_at            timestamptz not null default now()
);

create table if not exists file_assets (
  id                       uuid primary key default gen_random_uuid(),
  package_id               uuid not null references training_packages(id) on delete cascade,
  exercise_id              uuid references exercises(id) on delete cascade,
  kind                     text not null,
  usage                    text not null,
  local_path               text,
  remote_path              text,
  file_name                text,
  mime_type                text,
  size_bytes               bigint,
  upload_status            text not null default 'pending',
  processing_status        text not null default 'pending',
  keep_after_processing    boolean not null default false,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create table if not exists photo_import_jobs (
  id                      uuid primary key default gen_random_uuid(),
  package_id              uuid not null references training_packages(id) on delete cascade,
  exercise_id             uuid references exercises(id) on delete cascade,
  file_asset_id           uuid not null references file_assets(id) on delete cascade,
  status                  text not null default 'pending',
  detected_shots_count    int not null default 0,
  confirmed_at            timestamptz,
  error_message           text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create table if not exists share_grants (
  id             uuid primary key default gen_random_uuid(),
  token_hash     text not null,
  label          text,
  description    text,
  permissions    text[] not null default array['read']::text[],
  created_by     uuid,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz,
  revoked_at     timestamptz,
  revoked_by     uuid,
  last_used_at   timestamptz
);

create table if not exists share_events (
  id               uuid primary key default gen_random_uuid(),
  share_grant_id   uuid references share_grants(id) on delete cascade,
  event_type       text not null,
  details          jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);

-- ============================================================
-- Догоняющая миграция: чего не хватало для моста приложения
-- (раздел 5 TASK-sync-mapping.md).
-- ============================================================

alter table shots              add column if not exists counts  boolean not null default true;
alter table shots              add column if not exists extra   jsonb;
alter table training_packages  add column if not exists extra   jsonb;
alter table exercises          add column if not exists extra   jsonb;
alter table exercise_templates add column if not exists extra   jsonb;

-- Единая лента комментариев — тренировка/серия/выстрел, и отдельный
-- чат с тренером ('coach'): страница "Тренер" читает и пишет именно
-- этот уровень, без фильтра по автору (та же логика, что в локальной
-- схеме, lib/db/local_schema.sql).
create table if not exists comments (
  id           uuid primary key default gen_random_uuid(),
  package_id   uuid not null references training_packages(id) on delete cascade,
  level        text not null check (level in ('shot', 'series', 'session', 'coach')),
  shot_id      uuid references shots(id) on delete cascade,
  series_no    int,
  author_role  text not null check (author_role in ('athlete', 'coach')),
  text         text not null,
  created_at   timestamptz not null default now()
);

alter table comments drop constraint if exists comments_level_fields;
alter table comments add constraint comments_level_fields check (
  (level = 'shot' and shot_id is not null and series_no is null) or
  (level = 'series' and series_no is not null and shot_id is null) or
  ((level = 'session' or level = 'coach') and shot_id is null and series_no is null)
);

create index if not exists idx_comments_package on comments(package_id);

-- Заметки — самостоятельный дневник, не привязанный к тренировке.
-- Уже существует ЛОКАЛЬНО (lib/db/local_schema.sql), но ни один экран
-- её пока не использует — таблица здесь только чтобы быть готовой,
-- синхронизация для нёе мостом пока не написана (раздел 5.3 задания:
-- "заведена на будущее").
create table if not exists training_notes (
  id           uuid primary key default gen_random_uuid(),
  topic        text not null default '',
  body         text not null default '',
  is_favorite  boolean not null default false,
  is_trashed   boolean not null default false,
  trashed_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ============================================================
-- Триггеры отметки времени — только на таблицах, которые заводит
-- этот блок (comments/training_notes). На остальных триггеры уже
-- есть на живой базе (updated_at там уже проставляется), трогать их
-- не нужно.
-- ============================================================

drop trigger if exists touch_training_notes on training_notes;
create trigger touch_training_notes before update on training_notes
  for each row execute function touch_updated_at();

-- ============================================================
-- RLS для НОВЫХ таблиц — используем уже существующую is_project_owner().
-- На остальных таблицах RLS уже включён и работает (см. предупреждение
-- в шапке файла) — здесь его не трогаем.
-- ============================================================

alter table comments enable row level security;
alter table training_notes enable row level security;

drop policy if exists "owner comments" on comments;
create policy "owner comments" on comments
  for all using (is_project_owner()) with check (is_project_owner());

drop policy if exists "owner training_notes" on training_notes;
create policy "owner training_notes" on training_notes
  for all using (is_project_owner()) with check (is_project_owner());

-- ============================================================
-- Справочник мишеней ISSF — сидируется один раз, дальше мост сам
-- находит строку по коду (get-or-create), сюда не пишет повторно.
-- ============================================================

insert into target_faces (code, name, distance_m, default_caliber_mm, scoring_type, max_score, ring_config, is_system, is_active)
select v.code, v.name, v.distance_m, v.caliber_mm, 'decimal', 10.9, v.ring_config::jsonb, true, true
from (values
  ('rifle_10m',  '№ 8, пневматическая винтовка 10 м', 10::numeric, 4.5::numeric,
    '{"ring_diameters_mm":[0.5,5.5,10.5,15.5,20.5,25.5,30.5,35.5,40.5,45.5],"bullseye_diameter_mm":30.5,"blank_size_mm":80,"inner_ten_diameter_mm":null,"gauging":"inward"}'),
  ('pistol_10m', '№ 9, пневматический пистолет 10 м', 10::numeric, 4.5::numeric,
    '{"ring_diameters_mm":[11.5,27.5,43.5,59.5,75.5,91.5,107.5,123.5,139.5,155.5],"bullseye_diameter_mm":59.5,"blank_size_mm":170,"inner_ten_diameter_mm":5.0,"gauging":"inward"}'),
  ('rifle_50m',  '№ 7, малокалиберная винтовка 50 м', 50::numeric, 5.6::numeric,
    '{"ring_diameters_mm":[10.4,26.4,42.4,58.4,74.4,90.4,106.4,122.4,138.4,154.4],"bullseye_diameter_mm":112.4,"blank_size_mm":250,"inner_ten_diameter_mm":5.0,"gauging":"inward"}'),
  ('pistol_25m', '№ 4, пистолет 25 м', 25::numeric, 5.6::numeric,
    '{"ring_diameters_mm":[50,100,150,200,250,300,350,400,450,500],"bullseye_diameter_mm":200,"blank_size_mm":550,"inner_ten_diameter_mm":25,"gauging":"inward"}')
) as v(code, name, distance_m, caliber_mm, ring_config)
on conflict (code) do nothing;

-- ============================================================
-- Чтение дневника тренером по токену.
--
-- На живой базе уже была `validate_share_token(p_token)` — проверяет
-- токен (bcrypt через `hash_share_token`) и отдаёт null на неверный
-- или отозванный, что угодно не-null на годный. САМИ данные она не
-- читает — функций ниже не было вовсе, тренер получал PGRST202 на
-- каждый переход в дневник. Имена НОВЫЕ (`get_shared_packages` и т.д.),
-- ничего существующего не переопределяют.
--
-- Без фильтра по владельцу внутри: в этой схеме один проект — один
-- спортсмен, `share_grants` не хранит `athlete_id` для сравнения (и не
-- нужен) — годный токен открывает весь проект целиком.
-- ============================================================

create or replace function get_shared_packages(p_token text)
returns setof training_packages
language plpgsql
security definer
set search_path = public
as $$
begin
  if validate_share_token(p_token) is null then return; end if;
  return query select * from training_packages order by started_at desc nulls last;
end;
$$;

-- "exercises" здесь — реальная таблица-снимок (package_id +
-- exercise_name), не каталог exercise_templates: дневнику тренера
-- каталог не нужен.
create or replace function get_shared_exercises(p_token text)
returns setof exercises
language plpgsql
security definer
set search_path = public
as $$
begin
  if validate_share_token(p_token) is null then return; end if;
  return query select * from exercises order by created_at;
end;
$$;

create or replace function get_shared_shots(p_token text, p_exercise_id uuid)
returns setof shots
language plpgsql
security definer
set search_path = public
as $$
begin
  if validate_share_token(p_token) is null then return; end if;
  return query select * from shots where exercise_id = p_exercise_id order by shot_no;
end;
$$;

create or replace function get_shared_comments(p_token text, p_package_id uuid)
returns setof comments
language plpgsql
security definer
set search_path = public
as $$
begin
  if validate_share_token(p_token) is null then return; end if;
  return query select * from comments where package_id = p_package_id order by created_at;
end;
$$;

-- Тренер комментирует наравне со спортсменом — автор проставляется
-- сервером ('coach'), не приходит из клиента.
create or replace function add_shared_comment(
  p_token text,
  p_package_id uuid,
  p_level text,
  p_shot_id uuid,
  p_series_no int,
  p_text text
) returns comments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row comments;
begin
  if validate_share_token(p_token) is null then
    raise exception 'invalid or revoked token';
  end if;
  insert into comments (package_id, level, shot_id, series_no, author_role, text)
  values (p_package_id, p_level, p_shot_id, p_series_no, 'coach', p_text)
  returning * into v_row;
  return v_row;
end;
$$;

-- ============================================================
-- Сброс кеша схемы — обязательно последней строкой.
-- ============================================================

notify pgrst, 'reload schema';
