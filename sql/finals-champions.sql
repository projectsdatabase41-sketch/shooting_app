-- Безопасно запускать повторно целиком.
-- Таблица чемпионов (публичная база yirvom). Запускать вручную в SQL editor.
create table if not exists finals_champions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  display_name text not null,
  format_id text not null,
  total numeric not null,
  stats jsonb not null,            -- СТП, разброс (для ботов), без сырых данных
  coach_id uuid,                   -- подпись тренера
  coach_signed_at timestamptz,
  consent boolean not null default false,
  banned_until timestamptz,
  created_at timestamptz not null default now()
);
alter table finals_champions enable row level security;
drop policy if exists champions_read on finals_champions;
create policy champions_read on finals_champions for select
  using (consent and coach_signed_at is not null and (banned_until is null or banned_until < now()));
drop policy if exists champions_insert on finals_champions;
create policy champions_insert on finals_champions for insert
  with check (user_id = auth.uid() and consent and coach_signed_at is null);
-- Подпись тренера ставит только он (coach_id = его uid), владелец не может.
drop policy if exists champions_coach_sign on finals_champions;
create policy champions_coach_sign on finals_champions for update
  using (coach_id = auth.uid()) with check (coach_id = auth.uid());
-- Тренер видит записи, ждущие его подписи; владелец видит свои.
drop policy if exists champions_coach_read on finals_champions;
create policy champions_coach_read on finals_champions for select using (coach_id = auth.uid());
drop policy if exists champions_owner_read on finals_champions;
create policy champions_owner_read on finals_champions for select using (user_id = auth.uid());
-- Подписать можно только неподписанную запись и только проставив подпись.
-- Нельзя назначить тренером самого себя.
alter table finals_champions drop constraint if exists champions_no_self_coach;
alter table finals_champions add constraint champions_no_self_coach check (coach_id is distinct from user_id);

-- Жалобы: по одной от пользователя; порог голосов даёт бан публикации на 30 дней.
create table if not exists finals_flags (
  champion_id uuid not null references finals_champions(id) on delete cascade,
  voter_id uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (champion_id, voter_id)
);
alter table finals_flags enable row level security;
drop policy if exists flags_insert on finals_flags;
create policy flags_insert on finals_flags for insert with check (voter_id = auth.uid());
drop policy if exists flags_read_own on finals_flags;
create policy flags_read_own on finals_flags for select using (voter_id = auth.uid());

create or replace function finals_flag_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; n int;
begin
  select user_id into owner from finals_champions where id = new.champion_id;
  if owner = new.voter_id then raise exception 'cannot flag own result'; end if;
  select count(*) into n from finals_flags where champion_id = new.champion_id;
  if n >= 5 then  -- порог голосов (с учётом новой строки BEFORE-триггером не считается)
    update finals_champions set banned_until = now() + interval '30 days' where id = new.champion_id;
  end if;
  return new;
end $$;
drop trigger if exists finals_flag_trg on finals_flags;
create trigger finals_flag_trg after insert on finals_flags for each row execute function finals_flag_check();

-- ===== Счётчик жалоб, постоянный бан («чёрная фишка») и апелляция =====
alter table finals_champions add column if not exists flag_count int not null default 0;
alter table finals_champions add column if not exists ban_count int not null default 0;
alter table finals_champions add column if not exists appeal_requested boolean not null default false;

create table if not exists finals_appeals (
  champion_id uuid not null references finals_champions(id) on delete cascade,
  voter_id uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (champion_id, voter_id)
);
alter table finals_appeals enable row level security;
drop policy if exists appeals_insert on finals_appeals;
create policy appeals_insert on finals_appeals for insert with check (voter_id = auth.uid());

-- Забаненные записи с поданной апелляцией видны всем вошедшим (для голосования).
drop policy if exists champions_appeal_read on finals_champions;
create policy champions_appeal_read on finals_champions for select
  using (appeal_requested and banned_until >= now() and auth.uid() is not null);

-- Жалоба: 5 голосов → бан 30 дней; третий бан → навсегда.
create or replace function finals_flag_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; n int; cur timestamptz; bans int;
begin
  select user_id, banned_until, ban_count into owner, cur, bans from finals_champions where id = new.champion_id;
  if owner = new.voter_id then raise exception 'cannot flag own result'; end if;
  select count(*) into n from finals_flags where champion_id = new.champion_id;
  update finals_champions set flag_count = n where id = new.champion_id;
  if n >= 5 and (cur is null or cur < now()) then
    update finals_champions
       set ban_count = bans + 1,
           banned_until = case when bans + 1 >= 3 then 'infinity'::timestamptz else now() + interval '30 days' end
     where id = new.champion_id;
  end if;
  return new;
end $$;

-- Владелец подаёт апелляцию на свой бан.
create or replace function finals_request_appeal(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update finals_champions set appeal_requested = true
   where id = p_id and user_id = auth.uid() and banned_until >= now();
end $$;
grant execute on function finals_request_appeal(uuid) to authenticated;

-- Апелляция: 5 голосов (не от жаловавшихся и не от владельца) снимают бан и жалобы.
create or replace function finals_appeal_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; n int;
begin
  select user_id into owner from finals_champions where id = new.champion_id and appeal_requested and banned_until >= now();
  if owner is null or owner = new.voter_id
     or exists (select 1 from finals_flags where champion_id = new.champion_id and voter_id = new.voter_id) then
    raise exception 'cannot vote';
  end if;
  select count(*) into n from finals_appeals where champion_id = new.champion_id;
  if n >= 5 then
    delete from finals_flags where champion_id = new.champion_id;
    delete from finals_appeals where champion_id = new.champion_id;
    update finals_champions set banned_until = null, flag_count = 0, appeal_requested = false where id = new.champion_id;
  end if;
  return new;
end $$;
drop trigger if exists finals_appeal_trg on finals_appeals;
create trigger finals_appeal_trg after insert on finals_appeals for each row execute function finals_appeal_check();

-- ===== Бан и «чёрные фишки» на АККАУНТ (а не на запись) =====
create table if not exists finals_user_strikes (
  user_id uuid primary key,
  strikes int not null default 0,
  banned_until timestamptz
);
alter table finals_user_strikes enable row level security;
drop policy if exists strikes_read_own on finals_user_strikes;
create policy strikes_read_own on finals_user_strikes for select using (user_id = auth.uid());

-- Забаненный аккаунт не может публиковать новые результаты.
drop policy if exists champions_insert on finals_champions;
create policy champions_insert on finals_champions for insert
  with check (user_id = auth.uid() and consent and coach_signed_at is null
    and not exists (select 1 from finals_user_strikes s
                    where s.user_id = auth.uid() and s.banned_until >= now()));

create or replace function finals_flag_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; n int; cur timestamptz; st int; ban timestamptz;
begin
  select user_id, banned_until into owner, cur from finals_champions where id = new.champion_id;
  if owner = new.voter_id then raise exception 'cannot flag own result'; end if;
  select count(*) into n from finals_flags where champion_id = new.champion_id;
  update finals_champions set flag_count = n where id = new.champion_id;
  if n >= 5 and (cur is null or cur < now()) then
    insert into finals_user_strikes (user_id, strikes) values (owner, 0) on conflict do nothing;
    update finals_user_strikes set strikes = strikes + 1 where user_id = owner returning strikes into st;
    ban := case when st >= 3 then 'infinity'::timestamptz else now() + interval '30 days' end;
    update finals_user_strikes set banned_until = ban where user_id = owner;
    update finals_champions set banned_until = ban where id = new.champion_id;
  end if;
  return new;
end $$;

create or replace function finals_appeal_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; n int;
begin
  select user_id into owner from finals_champions where id = new.champion_id and appeal_requested and banned_until >= now();
  if owner is null or owner = new.voter_id
     or exists (select 1 from finals_flags where champion_id = new.champion_id and voter_id = new.voter_id) then
    raise exception 'cannot vote';
  end if;
  select count(*) into n from finals_appeals where champion_id = new.champion_id;
  if n >= 5 then
    delete from finals_flags where champion_id = new.champion_id;
    delete from finals_appeals where champion_id = new.champion_id;
    update finals_champions set banned_until = null, flag_count = 0, appeal_requested = false where id = new.champion_id;
    -- Успешная апелляция снимает фишку и бан аккаунта.
    update finals_user_strikes set strikes = greatest(strikes - 1, 0), banned_until = null where user_id = owner;
  end if;
  return new;
end $$;

-- ===== Публикация без подписи тренера (по своим тренировкам) =====
-- Клиент проверяет, что у спортсмена достаточно тренировок и результат им не
-- противоречит, и ставит self_verified = true. Сервер приватную базу
-- тренировок не видит, поэтому доверяет клиенту — это слабее подписи тренера
-- (честность держат жалобы, баны и апелляции).
alter table finals_champions add column if not exists self_verified boolean not null default false;

drop policy if exists champions_insert on finals_champions;
create policy champions_insert on finals_champions for insert
  with check (user_id = auth.uid() and consent
    and ((coach_signed_at is null) or (self_verified and coach_id is null))
    and not exists (select 1 from finals_user_strikes s
                    where s.user_id = auth.uid() and s.banned_until >= now()));

-- ===== Протокол выстрелов чемпиона (смотреть по сериям, как в ведомости) =====
alter table finals_champions add column if not exists protocol jsonb;
