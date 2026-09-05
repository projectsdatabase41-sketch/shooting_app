# Как подготовить свою базу Supabase

Приложению нужна **ваша собственная** база: общей базы нет, ваши
тренировки не лежат ни у кого, кроме вас. Подготовка разовая, минут на
десять.

## 1. Завести проект

1. Зарегистрируйтесь на supabase.com и создайте новый проект
   (бесплатного тарифа хватает с запасом).
2. Придумайте и **сохраните** пароль базы — Supabase показывает его
   один раз.
3. Дождитесь, пока проект поднимется (пара минут).

## 2. Создать таблицы

Два способа, выбирайте любой.

**Способ А — руками.** В проекте откройте *SQL editor*, вставьте
скрипт из раздела 4 этого файла, нажмите *Run*. Скрипт можно запускать
повторно: он ничего не ломает и не стирает.

**Способ Б — через ИИ.** Если у вас ChatGPT или Claude, подключённый к
Supabase, отправьте ему текст из раздела 3 — он сделает всё сам.

## 3. Текст для ИИ-ассистента

Скопируйте всё, что ниже до конца файла, и отправьте ассистенту одним
сообщением.

---

Ты подключён к моему проекту Supabase. Примени, пожалуйста, миграцию
ниже — это схема для приложения по спортивной стрельбе.

Что важно:

* Скрипт идемпотентный, применяй его целиком и как есть, ничего не
  переписывая и не «улучшая».
* Не создавай никаких дополнительных таблиц, политик и функций сверх
  того, что в скрипте.
* Если в базе уже есть таблицы с такими же именами от другого проекта —
  **остановись и скажи мне**, ничего не применяй. `CREATE TABLE IF NOT
  EXISTS` на существующей таблице молча ничего не делает, и приложение
  начнёт писать в чужие данные.
* После применения проверь и сообщи мне:
  1. созданы ли таблицы `exercises`, `training_sessions`, `shots`,
     `comments`, `training_notes`, `share_grants`, `project_settings`,
     `target_faces`;
  2. включён ли row level security на всех из них;
  3. существуют ли функции `create_share_token`, `revoke_share_token`,
     `validate_share_token`, `get_shared_training_sessions`,
     `get_shared_shots`, `get_shared_comments`, `get_shared_exercises`,
     `add_shared_comment`.
* Ничего из моих данных не удаляй.

Отдельно проверь настройки аутентификации и скажи мне, включено ли
подтверждение почты (*Confirm email*). Если включено — так и оставь, но
предупреди меня: после регистрации в приложении надо будет подтвердить
адрес письмом, иначе вход не сработает.

Когда закончишь, дай мне два значения из *Settings → API*: **Project
URL** и **публичный ключ** (anon / publishable). Секретный ключ
(service_role) мне не нужен, и в приложение он не вводится.

## 4. Скрипт

```sql
-- sql/schema.sql — схема для ЛИЧНОЙ базы Supabase.
--
-- Модель развёртывания (решение пользователя, сентябрь 2026): общей
-- базы нет. У каждого спортсмена свой проект Supabase, у тренера свой.
-- Тренер подключается к базе спортсмена по ревокируемому токену — на
-- чтение и на комментарии. Никакой дополнительной регистрации в
-- сторонней службе не требуется: учётная запись создаётся здесь же, в
-- этой базе, средствами Supabase Auth.
--
-- Применяется один раз при подготовке базы: через SQL editor Supabase
-- или через ИИ-ассистента, подключённого к проекту (см. инструкцию
-- claude/supabase-setup-prompt.md — её пользователь просто пересылает
-- своему ассистенту).
--
-- Скрипт идемпотентный: повторный запуск ничего не ломает.
--
-- ВАЖНО: таблица color_prefs сюда НЕ входит — настройки оформления и
-- ассистента чисто локальные и не синхронизируются.

create extension if not exists "pgcrypto";

-- ============================================================
-- Служебное: отметка времени последнего изменения.
-- ============================================================

-- Синхронизация ручная и односторонних правил слияния не имеет:
-- выигрывает более поздняя запись. Чтобы это работало, время правки
-- должна ставить БАЗА, а не клиент — часы на телефоне могут врать, и
-- «победитель» тогда определялся бы настройками устройства.
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
-- Данные пользователя
-- ============================================================

create table if not exists project_settings (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null default auth.uid() references auth.users(id) on delete cascade,
  is_athlete         boolean not null default true,
  is_coach           boolean not null default false,
  storage_keep_count int not null default 200,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Справочник мишеней. Геометрию приложение берёт из собственных
-- констант (TargetFace), эта таблица нужна только как якорь для
-- внешних ключей и как читаемая расшифровка кода мишени в SQL.
create table if not exists target_faces (
  code                  text primary key,
  name                  text not null,
  distance_m            numeric not null,
  caliber_mm            numeric not null,
  bullseye_diameter_mm  numeric not null,
  blank_size_mm         numeric
);

insert into target_faces (code, name, distance_m, caliber_mm, bullseye_diameter_mm, blank_size_mm) values
  ('rifle_10m',  '№ 8, пневматическая винтовка 10 м',  10, 4.5,  30.5,  80),
  ('pistol_10m', '№ 9, пневматический пистолет 10 м',  10, 4.5,  59.5, 170),
  ('rifle_50m',  '№ 7, малокалиберная винтовка 50 м',  50, 5.6, 112.4, 250),
  ('pistol_25m', '№ 4, пистолет 25 м',                 25, 5.6, 200,   550)
on conflict (code) do nothing;

create table if not exists exercises (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name              text not null,
  target_face_code  text not null references target_faces(code),
  total_shots       int not null,
  series_size       int not null,
  gender            text not null default 'mixed' check (gender in ('male','female','mixed')),
  -- Описание серий: [{name, shot_count, time_limit_s, counts}, …].
  -- Пусто — упражнение старого вида, все серии одинаковы.
  series            jsonb,
  -- Мягкое удаление: упражнение уходит из выбора, но остаётся в базе,
  -- чтобы прошлые тренировки не потеряли название.
  deleted_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table if not exists training_sessions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  exercise_id       uuid not null references exercises(id),
  target_face_code  text not null references target_faces(code),
  status            text not null default 'notStarted'
                     check (status in ('notStarted','running','paused','finished')),
  started_at        timestamptz,
  finished_at       timestamptz,
  pause_intervals   jsonb not null default '[]'::jsonb,
  -- Показатели, под которые нет колонок: из SCATT и других приборов
  -- сюда уезжают скорость, стабильность прицеливания, темп, настройки
  -- прибора. В интерфейсе не показывается — это материал для
  -- ассистента, он читает содержимое и может построить по нему график.
  -- Структура намеренно не фиксирована: приборов со временем станет
  -- больше, и заводить под каждый свои колонки — тупик.
  extra             jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
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
  is_trashed          boolean not null default false,
  -- Идёт ли выстрел в зачёт. Пристрелка пишется и видна на мишени, но
  -- в сумму и статистику не входит. Флаг на выстреле, а не только в
  -- описании упражнения: шаблон могут потом переписать, а отстрелянная
  -- тренировка меняться не должна.
  counts              boolean not null default true,
  -- Показатели выстрела из внешних приборов: время прицеливания,
  -- удержание, скорость подвода. См. комментарий к training_sessions.extra.
  extra               jsonb,
  updated_at          timestamptz not null default now()
);

create index if not exists idx_shots_session on shots(session_id);

-- Единая таблица комментариев к тренировке, серии или выстрелу.
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

-- Заметки — самостоятельный дневник, не привязанный к тренировке.
--
-- Имя с приставкой training_ намеренно: «notes» — слишком ходовое
-- слово, и в реальной базе пользователя такая таблица уже нашлась (от
-- другого его проекта). CREATE TABLE IF NOT EXISTS в этом случае молча
-- ничего не делает, и приложение начало бы писать выстрелы в чужие
-- записи. Приставка стоит копейку и снимает целый класс аварий.
-- Тема (короткий заголовок) придумывается ассистентом при сохранении,
-- но остаётся обычным редактируемым текстом: если название не
-- понравилось, пользователь его переписывает.
--
-- Удаление двухступенчатое, как у выстрелов: сначала корзина
-- (is_trashed), и только очистка корзины удаляет строку насовсем.
create table if not exists training_notes (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  topic        text not null default '',
  body         text not null default '',
  is_favorite  boolean not null default false,
  is_trashed   boolean not null default false,
  trashed_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists idx_training_notes_user on training_notes(user_id) where is_trashed = false;

create table if not exists share_grants (
  id             uuid primary key default gen_random_uuid(),
  athlete_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  token_hash     text not null,
  athlete_label  text not null default '',
  created_at     timestamptz not null default now(),
  revoked_at     timestamptz
);

create index if not exists idx_share_grants_athlete on share_grants(athlete_id) where revoked_at is null;

-- Триггеры отметки времени. drop+create вместо "if not exists" —
-- у триггеров такого синтаксиса нет, а повторный запуск скрипта не
-- должен падать.
drop trigger if exists touch_exercises on exercises;
create trigger touch_exercises before update on exercises
  for each row execute function touch_updated_at();

drop trigger if exists touch_training_sessions on training_sessions;
create trigger touch_training_sessions before update on training_sessions
  for each row execute function touch_updated_at();

drop trigger if exists touch_shots on shots;
create trigger touch_shots before update on shots
  for each row execute function touch_updated_at();

drop trigger if exists touch_training_notes on training_notes;
create trigger touch_training_notes before update on training_notes
  for each row execute function touch_updated_at();

drop trigger if exists touch_project_settings on project_settings;
create trigger touch_project_settings before update on project_settings
  for each row execute function touch_updated_at();

-- ============================================================
-- RLS: каждый видит только своё.
--
-- Доступ тренера идёт ИСКЛЮЧИТЕЛЬНО через функции ниже (security
-- definer), а не через политики на чужие строки. Это принципиально:
-- токен можно отозвать одним полем, а выданный доступ к строкам —
-- нельзя.
-- ============================================================

alter table project_settings enable row level security;
alter table exercises enable row level security;
alter table training_sessions enable row level security;
alter table shots enable row level security;
alter table comments enable row level security;
alter table training_notes enable row level security;
alter table share_grants enable row level security;
alter table target_faces enable row level security;

drop policy if exists "own project_settings" on project_settings;
create policy "own project_settings" on project_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own exercises" on exercises;
create policy "own exercises" on exercises
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own training_sessions" on training_sessions;
create policy "own training_sessions" on training_sessions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own shots" on shots;
create policy "own shots" on shots
  for all using (
    exists (select 1 from training_sessions s where s.id = shots.session_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from training_sessions s where s.id = shots.session_id and s.user_id = auth.uid())
  );

drop policy if exists "own or authored comments" on comments;
create policy "own or authored comments" on comments
  for all using (
    exists (select 1 from training_sessions s where s.id = comments.session_id and s.user_id = auth.uid())
  ) with check (
    exists (select 1 from training_sessions s where s.id = comments.session_id and s.user_id = auth.uid())
  );

drop policy if exists "own training_notes" on training_notes;
create policy "own training_notes" on training_notes
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own share_grants" on share_grants;
create policy "own share_grants" on share_grants
  for all using (athlete_id = auth.uid()) with check (athlete_id = auth.uid());

-- Справочник мишеней читают все авторизованные, пишет только владелец
-- базы через SQL editor: это статические данные, а не пользовательские.
drop policy if exists "read target_faces" on target_faces;
create policy "read target_faces" on target_faces
  for select using (true);

-- ============================================================
-- Доступ тренера по токену
-- ============================================================

-- Создание токена: он возвращается ОДИН РАЗ, в базе остаётся только
-- хеш. Восстановить исходный токен нельзя — можно выпустить новый.
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

-- Проверка токена обязана смотреть revoked_at ПРИ КАЖДОМ вызове.
-- Отозванный токен перестаёт отдавать данные немедленно, а не после
-- перезапуска приложения тренера.
create or replace function validate_share_token(p_token text)
returns uuid -- athlete_id, либо null если токен неверный или отозван
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

-- Неверный или отозванный токен даёт ПУСТОЙ результат, а не ошибку:
-- тренер не должен по коду ответа отличать «нет доступа» от «нет
-- тренировок».
create or replace function get_shared_exercises(p_token text)
returns setof exercises
language sql
security definer
set search_path = public
as $$
  select e.* from exercises e
  where e.user_id = validate_share_token(p_token)
    and validate_share_token(p_token) is not null
  order by e.created_at;
$$;

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

-- Тренер комментирует наравне со спортсменом: комментирование не
-- входит в право правки и ролью не ограничено. Автор проставляется
-- сервером ('coach'), а не приходит из клиента.
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
  if not exists (
    select 1 from training_sessions s
    where s.id = p_session_id and s.user_id = v_athlete
  ) then
    raise exception 'session does not belong to this athlete';
  end if;
  insert into comments (session_id, level, shot_id, series_no, author_role, text)
  values (p_session_id, p_level, p_shot_id, p_series_no, 'coach', p_text)
  returning * into v_row;
  return v_row;
end;
$$;
```

## 5. Что дальше

В приложении: **Настройки → Учётная запись** (в самом низу). Вставьте
адрес и публичный ключ, введите почту и пароль, нажмите
«Зарегистрироваться» — учётная запись создастся в вашей же базе. Потом
кнопка «Проверить базу» скажет, всё ли на месте.

## 6. Как дать доступ тренеру

В настройках создайте токен доступа. Он показывается **один раз** — в
базе остаётся только его хеш, восстановить его нельзя, можно лишь
выпустить новый. Передайте тренеру адрес базы, публичный ключ и токен.
Тренер увидит ваши тренировки и сможет оставлять комментарии; править
ваши данные он не может. Отзыв токена действует немедленно.
