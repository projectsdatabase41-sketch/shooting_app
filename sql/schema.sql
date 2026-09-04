-- sql/schema.sql — миграция для Supabase-проекта пользователя
-- (раздел 2 tech-spec-v2.md: один проект Supabase на пользователя,
-- не мультитенантная схема). Применяется через Supabase SQL editor или
-- `mcp__Supabase__apply_migration` при подключении реального бэкенда
-- (раздел 12 ТЗ — вне объёма этого документа, схема готова заранее).
--
-- ВАЖНО: таблица color_prefs сюда НЕ входит — она чисто локальная
-- (часть A.2 логики-спека), не синхронизируется.

create extension if not exists "pgcrypto";

create table if not exists project_settings (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  is_athlete         boolean not null default true,
  is_coach           boolean not null default false,
  storage_keep_count int not null default 200,
  created_at         timestamptz not null default now()
);

create table if not exists target_faces (
  code                  text primary key,
  name                  text not null,
  distance_m            numeric not null,
  caliber_mm            numeric not null,
  bullseye_diameter_mm  numeric not null,
  blank_size_mm         numeric
);

insert into target_faces (code, name, distance_m, caliber_mm, bullseye_diameter_mm, blank_size_mm) values
  ('rifle_10m', '№ 8, пневматическая винтовка 10 м', 10, 4.5, 30.5, 170),
  ('pistol_10m', 'Пневматический пистолет 10 м', 10, 4.5, 26.5, null),
  ('rifle_50m', '№ 12, малокалиберная винтовка 50 м', 50, 5.6, 112.4, 250),
  ('pistol_25m', '№ 4, пистолет 25 м', 25, 5.6, 200, 550)
on conflict (code) do nothing;

create table if not exists exercises (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  code              text not null,
  name              text not null,
  target_face_code  text not null references target_faces(code),
  total_shots       int not null,
  series_size       int not null,
  gender            text not null default 'mixed' check (gender in ('male','female','mixed')),
  created_at        timestamptz not null default now()
);

create table if not exists training_sessions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  exercise_id       uuid not null references exercises(id),
  target_face_code  text not null references target_faces(code),
  status            text not null default 'notStarted'
                     check (status in ('notStarted','running','paused','finished')),
  started_at        timestamptz,
  finished_at       timestamptz,
  pause_intervals   jsonb not null default '[]'::jsonb,
  comment           text, -- легаси-поле, не источник комментариев уровня "тренировка" (см. comments)
  created_at        timestamptz not null default now()
);

create table if not exists shots (
  id                  uuid primary key default gen_random_uuid(),
  session_id          uuid not null references training_sessions(id) on delete cascade,
  shot_number         int not null,
  series_no           int not null,
  x_mm                numeric not null,
  y_mm                numeric not null,
  score               numeric not null,
  time                timestamptz not null,
  is_favorite         boolean not null default false,
  is_manually_edited  boolean not null default false,
  is_trashed          boolean not null default false
);

create index if not exists idx_shots_session on shots(session_id);

-- Единая таблица комментариев (часть C.3 логики-спека) — решение
-- открытого вопроса раздела 10 ТЗ. Комментарии к выстрелу больше НЕ
-- дублируются в JSON-поле shots.
create table if not exists comments (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references training_sessions(id) on delete cascade,
  level        text not null check (level in ('shot', 'series', 'session')),
  shot_id      uuid references shots(id) on delete cascade,
  series_no    int,
  author_role  text not null check (author_role in ('athlete', 'coach')),
  text         text not null,
  created_at   timestamptz not null default now(),
  constraint comments_level_fields check (
    (level = 'shot' and shot_id is not null and series_no is null) or
    (level = 'series' and series_no is not null and shot_id is null) or
    (level = 'session' and shot_id is null and series_no is null)
  )
);

create index if not exists idx_comments_session on comments(session_id);

create table if not exists share_grants (
  id             uuid primary key default gen_random_uuid(),
  athlete_id     uuid not null references auth.users(id) on delete cascade,
  token_hash     text not null,
  athlete_label  text not null default '',
  created_at     timestamptz not null default now(),
  revoked_at     timestamptz
);

create index if not exists idx_share_grants_athlete on share_grants(athlete_id) where revoked_at is null;

-- RLS: каждый пользователь видит только свои данные. Доступ тренера —
-- исключительно через RPC ниже (SECURITY DEFINER), не через прямые
-- политики на чужие строки (раздел 2 ТЗ: обмен через ревокируемый
-- токен, не через пароль/service_role).
alter table project_settings enable row level security;
alter table exercises enable row level security;
alter table training_sessions enable row level security;
alter table shots enable row level security;
alter table comments enable row level security;
alter table share_grants enable row level security;

create policy "own project_settings" on project_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own exercises" on exercises
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own training_sessions" on training_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own shots" on shots
  for all using (
    exists (select 1 from training_sessions s where s.id = shots.session_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from training_sessions s where s.id = shots.session_id and s.user_id = auth.uid())
  );

create policy "own or authored comments" on comments
  for all using (
    exists (select 1 from training_sessions s where s.id = comments.session_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from training_sessions s where s.id = comments.session_id and s.user_id = auth.uid())
  );

create policy "own share_grants" on share_grants
  for all using (athlete_id = auth.uid()) with check (athlete_id = auth.uid());

-- ============================================================
-- RPC для модели доступа тренера (часть C.5 логики-спека).
-- ============================================================

-- Создание токена: возвращается токен ОДИН РАЗ, в базе — только хеш.
create or replace function create_share_token(p_athlete_label text default '')
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text := encode(gen_random_bytes(24), 'base64');
  v_hash text := encode(digest(v_token, 'sha256'), 'hex');
begin
  insert into share_grants (athlete_id, token_hash, athlete_label)
  values (auth.uid(), v_hash, p_athlete_label);
  return v_token;
end;
$$;

-- Отзыв токена — по id гранта (владелец = текущий athlete).
create or replace function revoke_share_token(p_grant_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update share_grants
    set revoked_at = now()
    where id = p_grant_id and athlete_id = auth.uid() and revoked_at is null;
$$;

-- Валидация токена тренером — обязана проверять revoked_at is null ПРИ
-- КАЖДОМ вызове, не кэшировать результат дольше сессии приложения (C.5).
create or replace function validate_share_token(p_token text)
returns uuid -- athlete_id, либо null если токен неверный/отозван
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash text := encode(digest(p_token, 'sha256'), 'hex');
  v_athlete uuid;
begin
  select athlete_id into v_athlete
    from share_grants
    where token_hash = v_hash and revoked_at is null
    limit 1;
  return v_athlete;
end;
$$;

-- Список тренировок спортсмена по токену — тренер не видит ничего,
-- если токен неверный/отозван (пустой результат, не ошибка).
create or replace function get_shared_training_sessions(p_token text)
returns setof training_sessions
language sql
security definer
set search_path = public
as $$
  select s.* from training_sessions s
  where s.user_id = validate_share_token(p_token)
    and validate_share_token(p_token) is not null
  order by s.started_at desc nulls last;
$$;

-- Выстрелы одной тренировки спортсмена по токену.
create or replace function get_shared_shots(p_token text, p_session_id uuid)
returns setof shots
language sql
security definer
set search_path = public
as $$
  select sh.* from shots sh
  join training_sessions s on s.id = sh.session_id
  where sh.session_id = p_session_id
    and s.user_id = validate_share_token(p_token)
    and validate_share_token(p_token) is not null
  order by sh.shot_number;
$$;

-- Комментарии тренировки/серии/выстрела по токену — доступ на чтение
-- и на добавление (тренер комментирует наравне со спортсменом, C.2:
-- комментирование не входит в canEdit и не ограничено ролью/статусом).
create or replace function get_shared_comments(p_token text, p_session_id uuid)
returns setof comments
language sql
security definer
set search_path = public
as $$
  select c.* from comments c
  join training_sessions s on s.id = c.session_id
  where c.session_id = p_session_id
    and s.user_id = validate_share_token(p_token)
    and validate_share_token(p_token) is not null
  order by c.created_at;
$$;

create or replace function add_shared_comment(
  p_token text,
  p_session_id uuid,
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
  v_athlete uuid := validate_share_token(p_token);
  v_row comments;
begin
  if v_athlete is null then
    raise exception 'invalid or revoked token';
  end if;
  insert into comments (session_id, level, shot_id, series_no, author_role, text)
  values (p_session_id, p_level, p_shot_id, p_series_no, 'coach', p_text)
  returning * into v_row;
  return v_row;
end;
$$;
