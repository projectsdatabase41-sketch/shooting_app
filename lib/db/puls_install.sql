-- ============================================================================
-- puls_install.sql — ПОЛНАЯ установка базы Puls ОДНИМ файлом.
--
-- Что делает: создаёт все таблицы приложения, защиту, права, таблицу заметок
-- notes с эмбеддингами и поиском, инструкции для ИИ (table_docs) и сразу
-- проверяет себя — внизу появится таблица "проверка / ok / детали".
--
-- Как использовать: Supabase -> SQL Editor -> New query -> вставить ВЕСЬ файл
-- -> Run. Один раз. Идемпотентно — повторный запуск ничего не портит.
--
-- Расширенная версия с комментариями по каждой части — в файлах
-- 01_schema.sql / 02_ai_notes_embeddings_keepalive.sql / 03_ai_instructions.sql /
-- 99_verify.sql этой же папки (тот же код, просто разложен по смыслу).
-- ============================================================================


-- ============================== 01_schema.sql ==============================

-- ============================================================================
-- 01_schema.sql — ОСНОВНАЯ схема личной базы приложения Puls (Supabase).
--
-- Что делает: создаёт все таблицы приложения, функции защиты и права доступа.
-- Запускать ПЕРВЫМ, целиком, в Supabase → SQL Editor → New query → Run.
-- Идемпотентно: повторный запуск ничего не ломает и не стирает.
--
-- ВАЖНО про безопасность (прочитать):
--  * Одна база = один владелец. «Владелец» — тот, кто первым вошёл в
--    приложение под своей почтой: приложение само создаёт строку в
--    project_settings. ВТОРОЙ человек, даже зарегистрировавшись в этом же
--    проекте, владельцем стать НЕ МОЖЕТ (см. project_has_owner ниже) и ничего
--    не увидит: вся защита строится на is_project_owner().
--  * Роль anon (запросы с одним публичным ключом, без входа) не имеет доступа
--    к таблицам приложения. Ей открыты только функции чтения дневника ТРЕНЕРОМ
--    по токену (они проверяют токен внутри).
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Предохранитель: установка рассчитана на ПУСТОЙ проект Supabase. Ниже она
-- закрывает права роли anon на все таблицы схемы public — на базе, где уже
-- есть чужие таблицы (например, открытые для чтения другим ИИ), это бы их
-- сломало. Если посторонние таблицы найдены — останавливаемся, ничего не меняя.
-- ---------------------------------------------------------------------------
do $$
declare
  v_extra text;
begin
  select string_agg(tablename, ', ' order by tablename) into v_extra
  from pg_tables
  where schemaname = 'public'
    and tablename <> all (array[
      'project_settings', 'target_faces', 'exercise_templates', 'training_packages',
      'exercises', 'file_assets', 'photo_import_jobs', 'shots', 'remote_athlete_sources',
      'archived_packages', 'share_grants', 'share_events', 'comments', 'training_notes',
      'ai_conversation_summaries', 'notes', 'keepalive_log', 'table_docs'
    ]);
  if v_extra is not null then
    raise exception
      'Установка рассчитана на ПУСТОЙ проект Supabase. В схеме public уже есть посторонние таблицы: %. Ничего не изменено. Создайте новый проект (или уберите эти таблицы), затем запустите файл снова.',
      v_extra;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Служебное
-- ---------------------------------------------------------------------------

create or replace function touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Таблицы (порядок важен из-за внешних ключей)
-- ---------------------------------------------------------------------------

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
  storage_balance             text not null default 'balanced',
  -- Пароль служебной учётной записи чата (отдельный проект чата разработчика).
  -- Генерирует и читает само приложение; хранится тут, в ВАШЕЙ базе.
  chat_password               text,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
alter table project_settings add column if not exists chat_password text;

-- Приложение делает upsert по owner_user_id — нужен уникальный индекс.
create unique index if not exists project_settings_owner_user_id_key
  on project_settings (owner_user_id);

alter table project_settings drop constraint if exists project_settings_storage_balance_check;
alter table project_settings add constraint project_settings_storage_balance_check
  check (storage_balance in ('local_first', 'balanced', 'cloud_first'));

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
create unique index if not exists target_faces_code_key on target_faces (code);

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
  extra               jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
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
  package_status              text not null default 'active',
  editor_mode                 text not null default 'athlete',
  is_locked_by_athlete        boolean not null default true,
  local_version               int not null default 1,
  extra                       jsonb,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
-- Только 'completed' приложение считает завершённой тренировкой.
alter table training_packages drop constraint if exists training_packages_package_status_check;
alter table training_packages add constraint training_packages_package_status_check
  check (package_status in ('draft', 'active', 'completed', 'archived'));

-- Снимок ОДНОГО исполнения упражнения внутри тренировки. НЕ каталог упражнений
-- (каталог — exercise_templates). Приложение пишет ровно одну строку на
-- тренировку и её id РАВЕН id тренировки (так оно потом находит выстрелы).
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
  extra                 jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
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

create table if not exists shots (
  id                     uuid primary key default gen_random_uuid(),
  exercise_id            uuid not null references exercises(id) on delete cascade,
  shot_no                int not null,
  series_no              int,
  x_mm                   numeric,
  y_mm                   numeric,
  input_angle_degrees    numeric,
  coordinate_source      text not null default 'tap',
  reported_score         numeric,
  computed_score         numeric,
  final_score            numeric not null,
  source                 text not null default 'manual',
  photo_import_id        uuid references photo_import_jobs(id),
  is_manually_corrected  boolean not null default false,
  confirmed              boolean not null default true,
  -- Смещение от начала упражнения в миллисекундах (НЕ epoch).
  shot_time_ms           bigint,
  counts                 boolean not null default true,
  extra                  jsonb,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index if not exists idx_shots_exercise on shots (exercise_id);

-- Значения ограничены: имя прибора в них писать нельзя (оно живёт в extra).
alter table shots drop constraint if exists shots_coordinate_source_check;
alter table shots add constraint shots_coordinate_source_check
  check (coordinate_source in ('tap', 'score_angle', 'file_import', 'pdf', 'photo', 'auto', 'manual_corrected'));
alter table shots drop constraint if exists shots_source_check;
alter table shots add constraint shots_source_check
  check (source in ('manual', 'file_import', 'pdf', 'photo', 'auto', 'manual_corrected'));

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
create index if not exists idx_share_grants_hash on share_grants (token_hash);

create table if not exists share_events (
  id               uuid primary key default gen_random_uuid(),
  share_grant_id   uuid references share_grants(id) on delete cascade,
  event_type       text not null,
  details          jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);

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
create index if not exists idx_comments_package on comments (package_id);

-- Самостоятельный дневник, не привязанный к тренировке.
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

-- Память встроенного ассистента: одна строка = один обмен вопрос-ответ
-- (короткая выдержка, не полный текст). Пишет и читает приложение.
create table if not exists ai_conversation_summaries (
  id                    uuid primary key default gen_random_uuid(),
  period_start          timestamptz not null,
  period_end            timestamptz not null,
  summary               text not null,
  training_package_ids  uuid[] not null default '{}',
  shot_refs             jsonb,
  extra                 jsonb,
  created_at            timestamptz not null default now()
);
create index if not exists idx_ai_summaries_period on ai_conversation_summaries (period_start desc);

-- Триггеры времени последней правки (updated_at ставит БАЗА, не телефон).
do $$
declare t text;
begin
  foreach t in array array[
    'project_settings', 'target_faces', 'exercise_templates', 'training_packages',
    'exercises', 'file_assets', 'photo_import_jobs', 'shots',
    'remote_athlete_sources', 'training_notes'
  ] loop
    execute format('drop trigger if exists touch_%1$s on %1$I', t);
    execute format('create trigger touch_%1$s before update on %1$I for each row execute function touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Функции защиты
-- ---------------------------------------------------------------------------

-- Есть ли в проекте владелец. SECURITY DEFINER — чтобы видеть таблицу
-- в обход RLS (иначе не-владелец «видел бы» пустую таблицу и мог стать вторым).
create or replace function project_has_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from project_settings);
$$;

-- Я — владелец этой базы? На этой функции держатся ВСЕ политики доступа.
create or replace function is_project_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from project_settings where owner_user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------------
-- Политики доступа (RLS)
-- ---------------------------------------------------------------------------

alter table project_settings enable row level security;

-- Читать, менять и удалять свою строку. INSERT здесь НАМЕРЕННО не разрешён:
-- политики RLS складываются по «или», и общий «for all» дал бы любому
-- зарегистрированному вставить свою строку и стать вторым владельцем.
drop policy if exists "project_settings_owner_all" on project_settings;
drop policy if exists "project_settings_owner_select" on project_settings;
create policy "project_settings_owner_select" on project_settings
  for select to authenticated using (owner_user_id = auth.uid());
drop policy if exists "project_settings_owner_update" on project_settings;
create policy "project_settings_owner_update" on project_settings
  for update to authenticated
  using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());
drop policy if exists "project_settings_owner_delete" on project_settings;
create policy "project_settings_owner_delete" on project_settings
  for delete to authenticated using (owner_user_id = auth.uid());

-- Единственный путь вставки: первый вошедший становится владельцем; когда
-- владелец уже есть — новых нет. (Повторный вход владельца тоже проходит
-- проверку: приложение при каждом входе делает insert ... on conflict do nothing.)
drop policy if exists "bootstrap own project_settings" on project_settings;
create policy "bootstrap own project_settings" on project_settings
  for insert to authenticated
  with check (owner_user_id = auth.uid() and (not project_has_owner() or is_project_owner()));

-- Остальные таблицы приложения — только владельцу.
do $$
declare t text;
begin
  foreach t in array array[
    'target_faces', 'exercise_templates', 'training_packages', 'exercises',
    'file_assets', 'photo_import_jobs', 'shots', 'remote_athlete_sources',
    'archived_packages', 'share_grants', 'share_events', 'comments',
    'training_notes', 'ai_conversation_summaries'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "%1$s_owner_all" on %1$I', t);
    execute format(
      'create policy "%1$s_owner_all" on %1$I for all to authenticated using (is_project_owner()) with check (is_project_owner())',
      t);
  end loop;
end $$;

-- Права на таблицы: вошедшему — полные (дальше режет RLS), анониму — никаких.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;

-- ---------------------------------------------------------------------------
-- Справочник мишеней ISSF (приложение само находит строку по code)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Токены доступа тренера
--
-- Спортсмен в приложении создаёт токен: приложение генерирует случайную строку,
-- просит у базы её хеш (hash_share_token) и сохраняет ТОЛЬКО хеш в share_grants.
-- Открытый токен показывается один раз. Тренер вводит токен у себя — и читает
-- дневник через функции get_shared_* ниже (доступны БЕЗ входа, но только по
-- действующему токену). Отозвать токен: revoke_share_grant.
-- ---------------------------------------------------------------------------

create or replace function hash_share_token(p_token text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(digest(p_token, 'sha256'), 'hex');
$$;

-- Возвращает id токена, если он действует, иначе null.
create or replace function validate_share_token(p_token text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if p_token is null or length(p_token) < 8 then
    return null;
  end if;
  select id into v_id
  from share_grants
  where token_hash = encode(digest(p_token, 'sha256'), 'hex')
    and revoked_at is null
    and (expires_at is null or expires_at > now())
  limit 1;
  if v_id is not null then
    update share_grants set last_used_at = now() where id = v_id;
  end if;
  return v_id;
end;
$$;

create or replace function revoke_share_grant(p_share_grant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_project_owner() then
    raise exception 'only the project owner can revoke tokens';
  end if;
  update share_grants
     set revoked_at = now(), revoked_by = auth.uid()
   where id = p_share_grant_id and revoked_at is null;
end;
$$;

-- Пауза/возобновление проекта владельцем (status: active | paused | archived).
create or replace function set_project_status(p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_project_owner() then
    raise exception 'only the project owner can change project status';
  end if;
  if p_status not in ('active', 'paused', 'archived') then
    raise exception 'invalid status: %', p_status;
  end if;
  update project_settings
     set status = p_status,
         paused_at = case when p_status = 'active' then null else now() end
   where owner_user_id = auth.uid();
end;
$$;

-- Чтение дневника тренером по токену. Внутри проверяют токен; без действующего
-- токена возвращают пусто. Один проект = один спортсмен, поэтому годный токен
-- открывает весь дневник.
create or replace function get_shared_packages(p_token text)
returns setof training_packages
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if validate_share_token(p_token) is null then return; end if;
  return query select * from training_packages order by started_at desc nulls last;
end;
$$;

create or replace function get_shared_exercises(p_token text)
returns setof exercises
language plpgsql
security definer
set search_path = public, extensions
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
set search_path = public, extensions
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
set search_path = public, extensions
as $$
begin
  if validate_share_token(p_token) is null then return; end if;
  return query select * from comments where package_id = p_package_id order by created_at;
end;
$$;

-- Тренер комментирует наравне со спортсменом; автор ('coach') ставится сервером.
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
set search_path = public, extensions
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

-- Список таблиц базы — для «Настройки → Учётная запись → Таблицы для ИИ».
create or replace function list_public_tables()
returns table(table_name text)
language sql
stable
as $$
  select tablename::text as table_name
  from pg_tables
  where schemaname = 'public'
  order by tablename;
$$;

-- Права на функции: по умолчанию Postgres даёт EXECUTE всем — закрываем и
-- выдаём точечно.
revoke execute on function
  project_has_owner(), is_project_owner(), hash_share_token(text),
  validate_share_token(text), revoke_share_grant(uuid), set_project_status(text),
  get_shared_packages(text), get_shared_exercises(text), get_shared_shots(text, uuid),
  get_shared_comments(text, uuid),
  add_shared_comment(text, uuid, text, uuid, int, text), list_public_tables()
from public;

-- Только вошедший владелец:
grant execute on function
  project_has_owner(), is_project_owner(), hash_share_token(text),
  revoke_share_grant(uuid), set_project_status(text), list_public_tables()
to authenticated;
-- Тренер (без входа, по токену) и владелец:
grant execute on function
  validate_share_token(text), get_shared_packages(text), get_shared_exercises(text),
  get_shared_shots(text, uuid), get_shared_comments(text, uuid),
  add_shared_comment(text, uuid, text, uuid, int, text)
to anon, authenticated;

-- Обновить кеш схемы PostgREST — иначе новые таблицы/колонки не видны по API.

-- ============================== 02_ai_notes_embeddings_keepalive.sql ==============================

-- ============================================================================
-- 02_ai_notes_embeddings_keepalive.sql — заметки для ИИ, эмбеддинги, «пульс» базы.
--
-- Запускать ВТОРЫМ (после 01_schema.sql), целиком. Идемпотентно.
--
-- Что внутри:
--  A) notes — пример таблицы знаний (структура, которую читает встроенный
--     ассистент и внешние ИИ): текст, теги, полнотекстовый поиск, эмбеддинг.
--  B) Эмбеддинги: колонки embedding / embedding_model / embedding_created_at и
--     правило «свежести»: эмбеддинг считается актуальным, только если
--     embedding_created_at РАВНО updated_at записи (дате последнего изменения её
--     содержимого). Правка текста двигает updated_at — эмбеддинг автоматически
--     становится устаревшим и пересчитывается воркером (см. github/).
--  C) Гибридный поиск search_notes (слова + смысл).
--  D) puls_keepalive — «пульс», чтобы бесплатный проект Supabase не ушёл в паузу
--     после недели без активности (дёргается из GitHub раз в пару дней).
--
-- РАЗМЕРНОСТЬ ЭМБЕДДИНГА: ниже 1536 — это модель text-embedding-3-small
-- (OpenAI). Другая модель — другая размерность: найдите в файле «1536» и
-- замените во всех местах на свою ДО первого запуска (3-large = 3072 и
-- требует halfvec, см. 00_START_HERE.md, раздел «Эмбеддинги»).
-- ============================================================================

create extension if not exists vector;

-- ---------------------------------------------------------------------------
-- Общий триггер: любое изменение СОДЕРЖИМОГО записи двигает updated_at.
-- Изменения только служебных полей эмбеддинга updated_at НЕ трогают —
-- иначе запись сама делала бы свой эмбеддинг устаревшим. Подходит для любой
-- таблицы с колонками embedding / embedding_model / embedding_created_at:
--   create trigger touch_<таблица>_content before update on <таблица>
--     for each row execute function touch_updated_at_on_content_change();
-- ---------------------------------------------------------------------------

create or replace function touch_updated_at_on_content_change()
returns trigger
language plpgsql
as $$
begin
  if (to_jsonb(new) - 'updated_at' - 'embedding' - 'embedding_model' - 'embedding_created_at' - 'search_vector')
     is distinct from
     (to_jsonb(old) - 'updated_at' - 'embedding' - 'embedding_model' - 'embedding_created_at' - 'search_vector')
  then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- A) notes — пример структуры «заметки/знания»
-- ---------------------------------------------------------------------------

create table if not exists notes (
  id                    uuid primary key default gen_random_uuid(),
  topic                 text not null,                       -- заголовок / тема
  summary               text,                                -- краткая суть (часто главный текст)
  content               text,                                -- подробный текст (может быть пуст)
  category              text,
  tags                  text[] not null default '{}',
  source                text not null default 'manual',      -- откуда: manual | airtable | ai | import ...
  status                text not null default 'active'
                          check (status in ('active', 'archived', 'superseded')),
  version               int not null default 1,              -- версионность записи
  supersedes            uuid references notes(id) on delete set null,   -- какую запись заменяет
  parent_note_id        uuid references notes(id) on delete set null,   -- родитель (иерархия)
  confidence            text not null default 'normal'
                          check (confidence in ('low', 'normal', 'confirmed')),
  metadata              jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),  -- дата последнего изменения СОДЕРЖИМОГО
  -- Полнотекстовый поиск: вычисляется базой сам, поддерживать не нужно.
  search_vector         tsvector generated always as (
                          to_tsvector('russian',
                            coalesce(topic, '') || ' ' || coalesce(summary, '') || ' ' ||
                            coalesce(content, '') || ' ' || coalesce(category, ''))
                        ) stored,
  -- Эмбеддинг (смысловой вектор). Заполняет воркер, не человек.
  embedding             vector(1536),
  embedding_model       text,                                -- чем посчитан, например text-embedding-3-small
  embedding_created_at  timestamptz                          -- = updated_at, если эмбеддинг свежий
);

create index if not exists idx_notes_search_vector on notes using gin (search_vector);
create index if not exists idx_notes_tags on notes using gin (tags);
create index if not exists idx_notes_status on notes (status);
create index if not exists idx_notes_embedding on notes using hnsw (embedding vector_cosine_ops);

drop trigger if exists touch_notes_content on notes;
create trigger touch_notes_content before update on notes
  for each row execute function touch_updated_at_on_content_change();

alter table notes enable row level security;
drop policy if exists "notes_owner_all" on notes;
create policy "notes_owner_all" on notes
  for all to authenticated using (is_project_owner()) with check (is_project_owner());
grant select, insert, update, delete on notes to authenticated;
revoke all on notes from anon;

-- Два примера, чтобы структура была видна на живых данных (можно удалить).
insert into notes (topic, summary, content, category, tags, source, confidence)
select 'Пример: как записана заметка',
       'Кратко: тема + суть + теги. Подробный текст можно оставить пустым.',
       null,
       'пример',
       array['пример', 'структура'],
       'example',
       'confirmed'
where not exists (select 1 from notes where source = 'example');

insert into notes (topic, summary, content, category, tags, source, confidence)
select 'Пример: подробная заметка',
       'Заметка с длинным текстом в поле content.',
       'Здесь может быть любой длинный текст: разбор тренировки, выписка из правил, мысли после стрельбы. ' ||
       'Встроенный ассистент ищет по полям topic, summary, content и показывает теги и дату записи.',
       'пример',
       array['пример', 'разбор'],
       'example',
       'confirmed'
where (select count(*) from notes where source = 'example') = 1;

-- ---------------------------------------------------------------------------
-- B) Эмбеддинги: что нужно пересчитать и как записать результат
-- ---------------------------------------------------------------------------

-- Записи, у которых эмбеддинга нет, он устарел (embedding_created_at <> updated_at)
-- или посчитан другой моделью. p_model — модель, которой пользуется воркер.
create or replace function notes_needing_embedding(p_model text, p_limit int default 50)
returns table (id uuid, topic text, summary text, content text, tags text[], category text, updated_at timestamptz)
language sql
stable
as $$
  select n.id, n.topic, n.summary, n.content, n.tags, n.category, n.updated_at
  from notes n
  where n.status = 'active'
    and (n.embedding is null
         or n.embedding_created_at is distinct from n.updated_at
         or n.embedding_model is distinct from p_model)
  order by n.updated_at
  limit greatest(p_limit, 1);
$$;

-- Записывает эмбеддинг. Работает только если запись за время расчёта НЕ менялась
-- (p_expected_updated_at должен совпасть с текущим updated_at) — иначе вернёт
-- false и запись пересчитается на следующем круге. embedding_created_at
-- ставится РАВНЫМ updated_at: это и есть отметка «эмбеддинг свежий».
create or replace function set_note_embedding(
  p_id uuid,
  p_embedding vector(1536),
  p_model text,
  p_expected_updated_at timestamptz
) returns boolean
language plpgsql
as $$
begin
  update notes
     set embedding = p_embedding,
         embedding_model = p_model,
         embedding_created_at = updated_at
   where id = p_id and updated_at = p_expected_updated_at;
  return found;
end;
$$;

revoke execute on function notes_needing_embedding(text, int) from public, anon;
revoke execute on function set_note_embedding(uuid, vector, text, timestamptz) from public, anon;
grant execute on function notes_needing_embedding(text, int) to authenticated;
grant execute on function set_note_embedding(uuid, vector, text, timestamptz) to authenticated;
-- Воркер на GitHub ходит с секретным ключом (роль service_role) — ему тоже нужно.
grant execute on function notes_needing_embedding(text, int) to service_role;
grant execute on function set_note_embedding(uuid, vector, text, timestamptz) to service_role;
grant select, update on notes to service_role;

-- ---------------------------------------------------------------------------
-- C) Гибридный поиск: слова (FTS) + смысл (вектор), объединение по рангу (RRF).
-- p_embedding можно не передавать — тогда ищет только по словам.
-- ---------------------------------------------------------------------------

create or replace function search_notes(
  p_query text,
  p_embedding vector(1536) default null,
  p_limit int default 8
) returns table (id uuid, topic text, summary text, content text, tags text[], updated_at timestamptz, score double precision)
language sql
stable
set search_path = public, extensions
as $$
  with fts as (
    select n.id, row_number() over (order by ts_rank_cd(n.search_vector, q) desc) as rk
    from notes n, websearch_to_tsquery('russian', p_query) q
    where n.status = 'active' and n.search_vector @@ q
    limit 50
  ),
  vec as (
    select n.id, row_number() over (order by n.embedding <=> p_embedding) as rk
    from notes n
    where p_embedding is not null and n.embedding is not null and n.status = 'active'
    order by n.embedding <=> p_embedding
    limit 50
  )
  select n.id, n.topic, n.summary, n.content, n.tags, n.updated_at,
         (coalesce(1.0 / (60 + fts.rk), 0) + coalesce(1.0 / (60 + vec.rk), 0))::double precision as score
  from notes n
  left join fts on fts.id = n.id
  left join vec on vec.id = n.id
  where fts.id is not null or vec.id is not null
  order by score desc
  limit greatest(p_limit, 1);
$$;

revoke execute on function search_notes(text, vector, int) from public, anon;
grant execute on function search_notes(text, vector, int) to authenticated;

-- ---------------------------------------------------------------------------
-- D) «Пульс» базы. Бесплатный проект Supabase засыпает после недели без
-- активности. GitHub раз в пару дней вызывает puls_keepalive() — это настоящая
-- запись в базу (счётчик), поэтому засчитывается как активность.
-- Может вызвать кто угодно с публичным ключом — это безопасно: функция только
-- двигает счётчик и больше ничего не делает и ничего не возвращает наружу.
-- ---------------------------------------------------------------------------

create table if not exists keepalive_log (
  id         int primary key default 1 check (id = 1),
  last_ping  timestamptz not null default now(),
  pings      bigint not null default 0
);
insert into keepalive_log (id) values (1) on conflict (id) do nothing;

alter table keepalive_log enable row level security;   -- политик нет: напрямую не читается
revoke all on keepalive_log from anon, authenticated;

create or replace function puls_keepalive()
returns timestamptz
language sql
security definer
set search_path = public
as $$
  update keepalive_log set last_ping = now(), pings = pings + 1 where id = 1
  returning last_ping;
$$;

revoke execute on function puls_keepalive() from public;
grant execute on function puls_keepalive() to anon, authenticated;


-- ============================== 03_ai_instructions.sql ==============================

-- ============================================================================
-- 03_ai_instructions.sql — ИНСТРУКЦИЯ ДЛЯ ВНЕШНИХ ИИ, лежащая ПРЯМО В БАЗЕ.
--
-- Зачем: к базе подключаются разные ИИ (Qwen, Claude, ChatGPT, встроенный
-- ассистент, помощник в редакторе). Каждый без инструкции догадывается о
-- правилах — про знак оси Y, про то, что очки не пересчитываются, про
-- пристрелку, про то, что нельзя удалять. Догадки расходятся, данные портятся
-- ТИХО. Пусть правила лежат там же, где данные:
--     select entry_key, title, body from table_docs;     -- читается публичным ключом
--
-- Запускать ТРЕТЬИМ (после 01 и 02), целиком. Идемпотентно (повторный запуск
-- обновляет тексты, не плодя строк). Файл собран из трёх частей:
--   1) смысл каждой таблицы и общие правила (координаты, очки, extra…);
--   2) пошаговая инструкция «как занести тренировку из PDF/фото» + формула
--      координат + проверки + предупреждение о слабых моделях;
--   3) защита: что нельзя удалять и менять + живой отчёт table_protection.
-- ============================================================================

-- ============================================================================
-- Часть 1. Смысл таблиц и общие правила
-- ============================================================================

-- Внутренняя инструкция по базе — прямо в самой базе.
--
-- Зачем: к этой базе подключаются разные ИИ (ассистент приложения,
-- помощник в редакторе кода, разбор отчётов), и каждый заново
-- догадывается о правилах — про знак оси Y, про то, что очки не
-- пересчитываются, про пристрелку. Догадки расходятся, данные портятся
-- тихо. Пусть правила лежат там же, где данные: `select * from
-- table_docs` — и правила известны.
--
-- Идемпотентно: повторный прогон обновляет тексты, не плодя строк.

create table if not exists table_docs (
  id          uuid primary key default gen_random_uuid(),
  entry_key   text not null unique,
  kind        text not null check (kind in ('table', 'rule')),
  title       text not null,
  body        text not null,
  updated_at  timestamptz not null default now()
);

comment on table table_docs is
  'Инструкция по работе с этой базой: назначение таблиц и общие правила. Читать перед записью данных.';

alter table table_docs enable row level security;

drop policy if exists "owner table_docs" on table_docs;
create policy "owner table_docs" on table_docs
  for all using (is_project_owner()) with check (is_project_owner());

-- Читать инструкцию может любой вошедший: она не содержит данных
-- спортсмена, только правила.
drop policy if exists "read table_docs" on table_docs;
create policy "read table_docs" on table_docs
  for select using (true);

insert into table_docs (entry_key, kind, title, body) values
  ('training_packages', 'table', 'Тренировка целиком', 'Одна строка = одна тренировка (в приложении это TrainingSession).
Может содержать несколько упражнений; приложение сейчас пишет ровно одно.
started_at/ended_at — время стрельбы. time_is_approximate=true, если время
восстановлено из отчёта прибора, а не записано живьём.
extra — что это была за стрельба: {"event":{"kind":"championship","stage":"final","title":"..."}}.
kind: training | control | regional | championship | final.
ВНИМАНИЕ: title и note приложение пока не читает — для видимого текста
используйте комментарий уровня session.'),
  ('exercises', 'table', 'Снимок исполнения упражнения внутри пакета', 'НЕ каталог упражнений — каталог это exercise_templates.
package_id — к какой тренировке относится. Ссылка на шаблон лежит в
extra.template_id; без неё приложение при синхронизации не свяжет
тренировку с упражнением и заведёт локальный дубликат.
discipline = target_faces.code.'),
  ('exercise_templates', 'table', 'Каталог упражнений (шаблоны)', 'Ищется по name + target_face_id перед вставкой и ПЕРЕИСПОЛЬЗУЕТСЯ между
тренировками. Плодить новую строку на каждый файл нельзя — иначе история
распадётся на десяток одинаковых упражнений и срез «по упражнению»
перестанет что-либо значить.'),
  ('shots', 'table', 'Выстрел', 'x_mm/y_mm — миллиметры от центра мишени. Ось X вправо, ось Y ВВЕРХ.
Перевёрнутый знак Y зеркалит группу, при этом сумма очков сходится
идеально и ошибка не видна.
final_score — результат из прибора/протокола КАК ЕСТЬ, по координатам не
пересчитывается: на границе десятой доли пересчёт даст 10.5 там, где
написано 10.4.
counts=false — пристрелка: выстрел виден на мишени, но в сумму и
статистику не идёт. Флаг живёт на выстреле, а не вычисляется из
упражнения при чтении.
coordinate_source: tap | score_angle | file_import | pdf | photo | auto |
manual_corrected. source: manual | file_import | pdf | photo | auto |
manual_corrected. Значения ограничены CHECK — своё слово (например scatt)
не пройдёт: имя прибора идёт в extra, а не в источник.
shot_time_ms — СМЕЩЕНИЕ от начала упражнения в миллисекундах, тип integer.
Epoch-время туда не влезает (переполнение int4).
extra — показатели прибора структурой: {"scatt":{"aim_time_s":18.4,...}}.'),
  ('comments', 'table', 'Заметки людей', 'Текст спортсмена и тренера. level: shot | series | session | coach.
Показатели приборов сюда писать НЕЛЬЗЯ, даже с пометкой: по строке
«время прицеливания 18.4 с» ассистент ничего не посчитает, а личные
заметки утонут в машинном потоке. Числа — в shots.extra.'),
  ('training_notes', 'table', 'Самостоятельный дневник', 'Записи, не привязанные к тренировке. Тема придумывается ассистентом при
сохранении, но остаётся обычным редактируемым текстом.
Удаление двухступенчатое: is_trashed, затем настоящее удаление.
Не путать с таблицей notes — это отдельная база знаний для ИИ (см. protect:notes).'),
  ('target_faces', 'table', 'Справочник мишеней ISSF', 'Геометрию приложение берёт из своих констант (lib/models/target_face.dart),
эта таблица — якорь для внешних ключей и читаемая расшифровка кода.
Рабочие коды (у них заполнен ring_config): rifle_10m (№ 8), pistol_10m
(№ 9), rifle_50m (№ 7), pistol_25m (№ 4).
В базе лежат ещё четыре строки от первой версии схемы —
air_rifle_10m, air_pistol_10m, sb_rifle_50m, sb_pistol_25m, у них
ring_config пустой и приложение таких кодов не знает. На них НЕ
ссылаться (заводские шаблоны ВП-60, ПП-60, МВ-60, МВ 3х20 ссылались и
показывали мишень без колец — исправлено 2026-09-08 скриптом
sql/fix-legacy-target-faces.sql). Сейчас на них не ссылается ничто;
удалять без спроса всё равно не надо.
Строки ищутся по code и не дублируются.'),
  ('project_settings', 'table', 'Владелец базы и его настройки', 'Ровно одна строка на владельца, owner_user_id = auth.uid().
БЕЗ НЕЁ RLS закрывает всё: is_project_owner() возвращает false и на
чтение тоже. Создаётся ПРИЛОЖЕНИЕМ автоматически при первом входе владельца (первый вошедший
становится владельцем; второй стать им не может).
storage_balance: local_first | balanced | cloud_first.
status: active | paused | archived.'),
  ('file_assets', 'table', 'Файлы: фото мишеней, отчёты', 'Привязка к пакету и (необязательно) к упражнению. upload_status и
processing_status ведут файл от загрузки до разбора.'),
  ('photo_import_jobs', 'table', 'Разбор фотографии мишени', 'Одна работа = один снимок. detected_shots_count — сколько пробоин нашли,
confirmed_at — когда человек подтвердил результат разбора.
Тип мишени в разбор ПРИХОДИТ из упражнения, а не определяется по фото:
тренировка создаётся раньше съёмки. Кольца ищутся ради центра, масштаба,
поворота и перспективы; номера колец 1–8 снимают неоднозначность
масштаба. После калибровки диаметр пробоины сверяется с калибром
упражнения — расхождение означает неверную калибровку.'),
  ('remote_athlete_sources', 'table', 'Базы спортсменов у тренера', 'project_url + ссылка на токен доступа. Тренер подключается к базе
спортсмена на чтение и комментарии.'),
  ('archived_packages', 'table', 'Копия чужой тренировки у тренера', 'package_json — снимок целиком на момент выгрузки. Нужен, чтобы дневник
тренера не рассыпался, если спортсмен отозвал доступ.'),
  ('share_grants', 'table', 'Токены доступа тренера', 'Хранится только token_hash — исходный токен показывается один раз и
восстановлению не подлежит.
revoked_at обязан проверяться ПРИ КАЖДОМ обращении: отозванный токен
перестаёт отдавать данные немедленно. Если есть expires_at — проверять и
его.'),
  ('share_events', 'table', 'Журнал обращений по токену', 'Кто и когда читал дневник. Для разбора «почему тренер видит не то».'),
  ('rule:coordinates', 'rule', 'Координаты', 'Ось X вправо, ось Y ВВЕРХ, начало — центр мишени, единицы — миллиметры.
Выстрел хранится не числом, а точкой: из координат считаются очки, СТП,
кучность и направление увода.'),
  ('rule:score', 'rule', 'Очки', 'Считаются по краю пробоины, ближайшему к центру: R_calc = R − калибр/2,
далее номер кольца по официальным границам и десятая доля как
floor((граница − R_calc)/шаг), 0..9. Граница принадлежит более высокому
достоинству. Шкала 10.9…0.
Сумма «целыми» отбрасывает десятые У КАЖДОГО выстрела отдельно:
10.9+10.9+9.9 = 31.7 десятыми и 29 целыми.'),
  ('rule:sources', 'rule', 'Откуда брать координаты', 'Лестница по убыванию точности:
A. Настоящие координаты (векторные пробоины в PDF SCATT, CSV прибора) —
   брать как есть.
B. Результат + картинка: радиус ИЗ РЕЗУЛЬТАТА (точность ~0.08 мм), угол
   С КАРТИНКИ. Восемь секторов дают ошибку до 5.3 мм — как итоговый угол
   не годятся.
C. Только результаты — писать результат, координат нет. Это честнее
   выдуманного положения.'),
  ('rule:extra', 'rule', 'Что писать в extra', 'Всё, чему нет колонки: показатели приборов, разметка события. Структурой,
под ключом с именем источника. Заводить новые колонки под каждый прибор —
тупик, приборов со временем станет больше.'),
  ('rule:idempotency', 'rule', 'Повторная запись', 'Идентификаторы детерминированные — md5(ключ_источника || '':'' || номер)::uuid, вставка
через on conflict do nothing. Повторный прогон импорта не должен плодить
дубликаты. Обратная сторона: перезалить исправленные данные поверх старых
не выйдет — сначала удалить.'),
  ('rule:schema-changes', 'rule', 'Изменения схемы', 'Схема меняется ТОЛЬКО через установочные файлы 01/02/03 (папка Puls-Database-Setup/sql).
create table if not exists на существующей таблице НЕ добавляет колонок —
для них alter table ... add column if not exists.
Последней строкой любой правки: notify pgrst, ''reload schema'' — иначе
PostgREST продолжит отдавать ошибку про несуществующую колонку.')
on conflict (entry_key) do update
  set title = excluded.title,
      body = excluded.body,
      updated_at = now();


-- ============================================================================
-- Часть 2. Как занести тренировку из PDF/фото/таблицы
-- ============================================================================

-- Инструкция по СОЗДАНИЮ записей — для стороннего ИИ (например Qwen), который
-- читает PDF/фото/таблицу с результатом тренировки и сам заносит её в базу.
-- Пользователь присылает файл в любом виде — ИИ читает table_docs, понимает
-- структуру и пишет куда нужно.
--
-- Дополняет sql/table-docs.sql (смысл таблиц и общие правила) и
-- sql/table-protection.sql (что нельзя трогать). Идемпотентно. Сверено с тем,
-- как приложение Puls ЧИТАЕТ данные (lib/services/supabase_service.dart,
-- _pull): запись, сделанная иначе, будет молча пропущена приложением.
--
-- Запускать в SQL Editor ЛИЧНОЙ базы.

insert into table_docs (entry_key, kind, title, body) values

  ('rule:import-access', 'rule', 'Доступ при записи — читать первым',
'Читать table_docs можно по публичному ключу (anon). ПИСАТЬ в таблицы тренировок
(training_packages, exercises, exercise_templates, shots, comments, file_assets)
публичный ключ НЕ позволяет: политики требуют is_project_owner(), то есть вход
под аккаунтом владельца базы (email+пароль -> JWT, заголовок Authorization: Bearer).
service_role-ключ (обходит защиту) для импорта НЕ использовать и в чате не
просить: им можно снести всю базу. Нет JWT владельца -> ничего не записывать,
сообщить человеку, что нужен вход, а не пытаться обойти.'),

  ('rule:import-procedure', 'rule', 'Как занести тренировку из PDF/фото/таблицы — по шагам',
'ШАГ 0. Прочитать: select entry_key,body from table_docs (все rule:* и таблицы),
       и справочник мишеней target_faces (code, id).
ШАГ 1. СПРОСИТЬ у человека, а не угадывать: какое упражнение и МИШЕНЬ (код из
       target_faces: rifle_10m, pistol_10m, rifle_50m, pistol_25m), дату и время
       начала, сколько выстрелов зачётных и есть ли пристрелка. Мишень — входной
       параметр, по картинке её не определять (см. rule:sources).
ШАГ 2. Разобрать источник в список выстрелов: номер, серия, результат КАК НАПИСАН
       (с десятыми: 10.6), координаты если они есть в источнике (уровень A).
ШАГ 3. Проверить ДО записи (см. rule:import-checks). Не сошлось — не писать,
       показать человеку расхождение.
ШАГ 4. Записать в таком порядке (каждая строка — вставка с детерминированным id,
       Prefer: resolution=ignore-duplicates, см. rule:idempotency):
  4.1 exercise_templates — сначала ПОИСК по exercise_name + target_face_id, создавать
      только если нет (не плодить дубликаты). Поля: code = ''custom_'' || id,
      name, weapon_type (''rifle'' для rifle_*, ''pistol'' для pistol_*),
      ammo_type (''air'' для 4.5 мм, ''smallbore'' для 5.6 мм), distance_m,
      shots_count, shots_per_series, target_face_id, is_custom=true.
  4.2 training_packages — id = X (новый детерминированный uuid), started_at (с
      часовым поясом), ended_at если известно, package_status = ''completed''
      (только completed приложение считает завершённой тренировкой; draft/active
      покажутся как «не начата»), time_is_approximate=true если время восстановлено.
      extra: {"event":{"kind":"training"},"import":{"by":"<имя ИИ>","source":"pdf|photo|csv"}}.
  4.3 exercises — РОВНО ОДНА строка на пакет, и её id ДОЛЖЕН РАВНЯТЬСЯ id пакета
      (id = X, package_id = X). Иначе приложение не найдёт выстрелы (оно ищет их
      по exercise_id = id пакета) и тренировка придёт пустой. Поля: exercise_name,
      discipline = код мишени, distance_meters, target_face_id, decimal_scoring=true,
      expected_shots.
  4.4 shots — exercise_id = X. shot_no сквозной 1..N по всему упражнению, series_no,
      final_score = результат из источника КАК ЕСТЬ (не пересчитывать по
      координатам), reported_score = то же, x_mm/y_mm (Y вверх положительный),
      counts=false для пристрелки, confirmed=true, coordinate_source и source из
      разрешённых: pdf | photo | file_import (см. shots), shot_time_ms — смещение
      от начала в мс (integer) или null, extra — показатели прибора структурой.
  4.5 comments — только человеческий текст (level: shot|series|session|coach).
      Показатели приборов — в shots.extra, не сюда.
ШАГ 5. Прочитать записанное обратно (GET по id) и показать человеку сводку: мишень,
       дата, число выстрелов, сумма по сериям и общая. Попросить открыть приложение
       и сверить; расхождение — исправлять, а не игнорировать.
Если чего-то не хватает (нет мишени, нет даты, нечитаемо) — остановиться и
спросить. Пропущенное поле лучше пустым, чем выдуманным.'),

  ('rule:import-checks', 'rule', 'Проверки перед записью (обязательны, ловят ошибки любой модели)',
'1. Число выстрелов совпало с expected_shots (+ пристрелка отдельно, counts=false).
2. Сумма результатов совпала с итогом, напечатанным в источнике, — и по каждой
   серии, и общая. Десятые суммируются как десятые; «целыми» — отбрасываются у
   КАЖДОГО выстрела отдельно (rule:score).
3. Каждый результат в допустимом диапазоне: 0..10.9 для десятичного зачёта.
4. Нумерация выстрелов сплошная, без дыр и повторов; серии по порядку.
5. Фото: диаметр пробоины по калибру упражнения (4.5 / 5.6 мм) сходится с
   заявленным — иначе масштаб неверен, координатам не верить (DATA-INGEST §3).
6. Знак оси Y: выстрел выше центра на бумаге -> y_mm > 0. Перевёрнутый знак
   зеркалит группу, а сумма при этом сходится — единственный способ заметить
   ошибку — сверить 2-3 выстрела с картинкой.
7. Координат в источнике нет: НЕ писать null и НЕ 0/0 (приложение читает пустое
   как 0 — все выстрелы лягут в центр, тренировка «пустая»). Радиус берётся из
   результата (rule:radius-formula), направление — из источника (стрелка, часы,
   рисунок) или, если его нигде нет, углы раскладываются по золотому углу
   (i*137.5 градусов), в shots.extra пишется {"координаты":"направление
   неизвестно (условное)"}, а человеку говорится, что точки условные.
Любая проверка не прошла -> НЕ писать молча и НЕ подгонять цифры, показать
расхождение человеку.'),

  ('rule:radius-formula', 'rule', 'Координаты из результата и направления (формула)',
'Если пишете x_mm/y_mm сами. Направление: 0 градусов = вверх, по часовой; 3 часа = 90,
6 часов = 180; часы: час*30 + минуты*0.5; стрелки: ↑0 ↗45 →90 ↘135 ↓180 ↙225 ←270 ↖315.
Результат ring.decimal (10.6 -> ring=10, decimal=6):
  d = max(0, R10 + W*(10 - ring) - (decimal + 0.5) * W/10 + K)
  x_mm = d * sin(угол);  y_mm = d * cos(угол)      -- ось Y ВВЕРХ
По мишеням (R10, W, K, мм): rifle_10m 0.25/2.5/2.25; pistol_10m 5.75/8/2.25;
rifle_50m 5.2/8/2.8; pistol_25m 25/25/2.8. Ниже единицы (промах) — за внешнее кольцо.
Проверка: rifle_50m 10.6 -> 2.8; rifle_10m 10.6 -> 0.875; pistol_25m 9.0 -> 51.55.
Проще не считать: файл импорта приложения принимает результат + направление и считает сам
(см. публичную таблицу инструкций: «Puls: как определить координаты выстрела»).
Устаревший пример «5.2 - 1.1 = 4.1» (старая модель) — НЕ использовать.'),

  ('rule:import-model', 'rule', 'Какую модель использовать для импорта (предупреждение)',
'Импорт из PDF/фото — задача, где дешёвая или маленькая модель ошибается ТИХО:
путает знак оси Y, сдвигает номер кольца, теряет десятые, «додумывает» строки,
которых нет в источнике. Ошибка при этом не видна: суммы могут сходиться.
Рекомендация (проверить нельзя, база модель не видит — это договорённость):
 - для разбора ФОТО и сканов использовать сильную модель с хорошим зрением и
   арифметикой; дешёвые/бесплатные — только для чистого текста/CSV и всё равно
   с проверками из rule:import-checks;
 - если модель не уверена в источнике — остановиться и спросить человека,
   а не писать «наиболее вероятное»;
 - результат каждого импорта показывать человеку на сверку (шаг 5).
Главная защита — не выбор модели, а проверки и сверка человеком: они ловят
ошибку любой модели.')

on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();


-- ============================================================================
-- Часть 3. Защита таблиц — чтобы через полгода никто (ни человек, ни ИИ) не
-- «почистил» права или данные как якобы ненужные.
-- ============================================================================

insert into table_docs (entry_key, kind, title, body) values
  ('rule:protection', 'rule', 'Защита таблиц — читать перед любой правкой прав или удалением',
'1. НЕ удалять таблицы, колонки, строки и НЕ менять политики RLS/права (grant/revoke)
   "потому что похоже на ненужное". Сначала select * from table_protection и
   запись protect:<таблица> в table_docs.
2. Все таблицы приложения: доступ только владельцу базы через is_project_owner().
   Роль anon (публичный ключ без входа) к таблицам доступа НЕ имеет — не выдавать.
   Исключения: table_docs (читается всеми — в ней нет данных, только правила) и
   функции чтения дневника тренером по токену (проверяют токен внутри).
3. Схема меняется только через файлы 01/02/03 установочного пакета
   (см. rule:schema-changes).
4. Изменили защиту — обновите protect:<таблица> и эту запись.'),

  ('protect:notes', 'table', 'notes — база знаний для ИИ',
'Заметки/знания: topic, summary, content (часто пуст — текст в summary), tags (text[]),
source, status (active|archived|superseded), version/supersedes, confidence, metadata,
search_vector (полнотекстовый, вычисляется сам), embedding + embedding_model +
embedding_created_at (смысловой вектор).
ПРАВИЛО СВЕЖЕСТИ ЭМБЕДДИНГА: эмбеддинг актуален, только если embedding_created_at РАВНО
updated_at. Правка содержимого двигает updated_at (триггер), эмбеддинг становится
устаревшим и пересчитывается воркером. Эмбеддинг вручную не править.
Доступ: только владелец (политика notes_owner_all). Встроенный ассистент приложения
читает эту таблицу, если подключить её в «Настройки → Учётная запись → Таблицы для ИИ».
Писать заметки можно и внешнему ИИ — под входом владельца. НЕ удалять таблицу и не
переименовывать колонки topic/summary/content: их читает приложение.'),

  ('protect:ai_conversation_summaries', 'table', 'ai_conversation_summaries — память ассистента',
'Одна строка = один обмен вопрос-ответ (краткая выдержка, не полный текст). Пишет и
читает приложение (AiMemoryService), хранит не более 1000 строк — лишние стирает само.
Доступ: только владелец. Удаление таблицы = ассистент забывает прошлые разговоры.'),

  ('protect:keepalive_log', 'table', 'keepalive_log — пульс базы',
'Одна строка (id = 1): время и счётчик последнего вызова puls_keepalive(). Её дёргает
GitHub раз в пару дней, чтобы бесплатный проект Supabase не уходил в паузу. Прямого
доступа нет ни у кого (политик нет) — только через функцию. НЕ удалять таблицу и функцию:
проект уснёт, а первый запрос после паузы придётся ждать минутами.'),

  ('protect:table_docs', 'table', 'table_docs — эта самая инструкция',
'Пишет только владелец, читает любой. Это память проекта о смысле таблиц и о том, что
трогать нельзя. НЕ удалять и не «упрощать»: по ней следующий ИИ узнаёт правила.')
on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();

-- ЖИВОЙ отчёт: RLS и политики прямо из системного каталога — не устаревает.
-- Смотреть: select * from table_protection;  documented = false → описания нет, проверить.
create or replace view table_protection with (security_invoker = on) as
select c.relname                                   as table_name,
       c.relrowsecurity                            as rls_enabled,
       coalesce((
         select string_agg(p.policyname || ' [' || p.cmd || ' → ' || array_to_string(p.roles, ',') || ']',
                           '; ' order by p.policyname)
         from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
       ), '— нет политик —')                       as policies,
       exists (
         select 1 from table_docs d
         where d.entry_key = c.relname or d.entry_key = 'protect:' || c.relname
       )                                           as documented
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;

revoke all on table_protection from anon;
grant select on table_protection to authenticated;

-- Права на table_docs: читать могут все (в ней только правила), менять — владелец.
grant select on table_docs to anon;
grant select, insert, update, delete on table_docs to authenticated;


notify pgrst, 'reload schema';

-- ============================== Проверка (99_verify.sql) ==============================

with required_tables(name) as (values
  ('project_settings'), ('target_faces'), ('exercise_templates'), ('training_packages'),
  ('exercises'), ('file_assets'), ('photo_import_jobs'), ('shots'),
  ('remote_athlete_sources'), ('archived_packages'), ('share_grants'), ('share_events'),
  ('comments'), ('training_notes'), ('ai_conversation_summaries'),
  ('notes'), ('keepalive_log'), ('table_docs')
),
required_functions(name) as (values
  ('touch_updated_at'), ('touch_updated_at_on_content_change'),
  ('project_has_owner'), ('is_project_owner'), ('hash_share_token'), ('validate_share_token'),
  ('revoke_share_grant'), ('set_project_status'), ('get_shared_packages'), ('get_shared_exercises'),
  ('get_shared_shots'), ('get_shared_comments'), ('add_shared_comment'), ('list_public_tables'),
  ('notes_needing_embedding'), ('set_note_embedding'), ('search_notes'), ('puls_keepalive')
)
select * from (
  select 1 as n, 'Все таблицы приложения на месте' as проверка,
         not exists (select 1 from required_tables r
                     where not exists (select 1 from pg_tables t where t.schemaname = 'public' and t.tablename = r.name)) as ok,
         coalesce((select string_agg(r.name, ', ') from required_tables r
                   where not exists (select 1 from pg_tables t where t.schemaname = 'public' and t.tablename = r.name)),
                  'все ' || (select count(*) from required_tables) || ' есть') as детали
  union all
  select 2, 'Все функции на месте',
         not exists (select 1 from required_functions f
                     where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                       where n.nspname = 'public' and p.proname = f.name)),
         coalesce((select string_agg(f.name, ', ') from required_functions f
                   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                     where n.nspname = 'public' and p.proname = f.name)),
                  'все ' || (select count(*) from required_functions) || ' есть')
  union all
  select 3, 'Защита строк (RLS) включена на ВСЕХ таблицах',
         not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
         coalesce((select string_agg(c.relname, ', ') from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 'везде включена')
  union all
  select 4, 'Расширения pgcrypto и vector установлены',
         (select count(*) from pg_extension where extname in ('pgcrypto', 'vector')) = 2,
         coalesce((select string_agg(extname, ', ') from pg_extension where extname in ('pgcrypto', 'vector')), 'нет')
  union all
  select 5, 'Справочник мишеней: 4 записи',
         (select count(*) from target_faces) = 4,
         (select count(*) from target_faces)::text || ' шт.'
  union all
  select 6, 'Аноним (публичный ключ без входа) НЕ имеет доступа к таблицам приложения',
         not exists (select 1 from information_schema.role_table_grants
                     where table_schema = 'public' and grantee = 'anon' and table_name <> 'table_docs'),
         coalesce((select string_agg(distinct table_name, ', ') from information_schema.role_table_grants
                   where table_schema = 'public' and grantee = 'anon' and table_name <> 'table_docs'),
                  'доступа нет (кроме чтения table_docs — так задумано)')
  union all
  select 7, 'Владелец создан (появляется после ПЕРВОГО входа в приложение)',
         (select count(*) from project_settings) = 1,
         case (select count(*) from project_settings)
           when 0 then 'ещё нет — войдите в приложение под своей почтой'
           when 1 then 'один владелец — как и должно быть'
           else 'ВНИМАНИЕ: владельцев больше одного — см. 00_START_HERE.md, «Если что-то не так»'
         end
  union all
  select 8, 'Пульс базы готов (keepalive_log есть; вызовов растёт, когда работает GitHub)',
         (select last_ping from keepalive_log where id = 1) is not null,
         'вызовов: ' || (select pings from keepalive_log where id = 1)::text ||
         ', последний: ' || (select last_ping from keepalive_log where id = 1)::text
  union all
  select 9, 'Инструкция для ИИ загружена (table_docs)',
         (select count(*) from table_docs) >= 20,
         (select count(*) from table_docs)::text || ' записей'
  union all
  select 10, 'Пример заметок на месте (notes)',
         (select count(*) from notes) >= 1,
         (select count(*) from notes)::text || ' записей'
) checks
order by n;
