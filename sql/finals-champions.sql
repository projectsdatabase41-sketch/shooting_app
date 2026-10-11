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
