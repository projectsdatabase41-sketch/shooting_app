-- Совместные финалы (тренер, спортсмены, помощники) — публичная база мессенджера.
-- Запускать вручную в SQL editor. Безопасно запускать повторно.
--
-- Модель: «хозяин» (host) ведёт часы и считает финал на своём телефоне и
-- публикует состояние в finals_sessions.state; участники читают его опросом
-- (раз в секунду) и отправляют выстрелы событиями в finals_events; хозяин их
-- применяет. Realtime можно включить позже без смены схемы.

create table if not exists finals_sessions (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null default auth.uid(),
  format_id text not null,
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);

-- role: athlete (сам вводит свои выстрелы), coach (вводит за любых),
-- helper (вводит за одного спортсмена target_id). status: invited/accepted/declined.
create table if not exists finals_session_members (
  session_id uuid not null references finals_sessions(id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('athlete', 'coach', 'helper')),
  target_id text,
  name text not null default '',
  status text not null default 'invited' check (status in ('invited', 'accepted', 'declined')),
  primary key (session_id, user_id, role)
);

create table if not exists finals_events (
  id bigint generated always as identity primary key,
  session_id uuid not null references finals_sessions(id) on delete cascade,
  author uuid not null default auth.uid(),
  kind text not null check (kind in ('shot', 'undo')),
  who text not null,           -- id участника финала, за кого выстрел
  x double precision,
  y double precision,
  created_at timestamptz not null default now()
);
create index if not exists finals_events_session on finals_events (session_id, id);

alter table finals_sessions enable row level security;
alter table finals_session_members enable row level security;
alter table finals_events enable row level security;

-- Участник сессии = хозяин или приглашённый/принявший.
create or replace function finals_is_member(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from finals_sessions s where s.id = sid and s.host_id = auth.uid())
      or exists (select 1 from finals_session_members m where m.session_id = sid and m.user_id = auth.uid());
$$;

drop policy if exists fs_read on finals_sessions;
-- host_id = auth.uid() напрямую: иначе INSERT ... RETURNING не видит только что вставленную строку.
create policy fs_read on finals_sessions for select using (host_id = auth.uid() or finals_is_member(id));
drop policy if exists fs_insert on finals_sessions;
create policy fs_insert on finals_sessions for insert with check (host_id = auth.uid());
drop policy if exists fs_update on finals_sessions;
create policy fs_update on finals_sessions for update using (host_id = auth.uid());

drop policy if exists fm_read on finals_session_members;
create policy fm_read on finals_session_members for select using (finals_is_member(session_id));
-- Приглашает только хозяин.
drop policy if exists fm_insert on finals_session_members;
create policy fm_insert on finals_session_members for insert
  with check (exists (select 1 from finals_sessions s where s.id = session_id and s.host_id = auth.uid()));
-- Ответить на приглашение (принять/отказаться) может сам приглашённый.
drop policy if exists fm_answer on finals_session_members;
create policy fm_answer on finals_session_members for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- События: тренер — за любого, спортсмен — за себя, помощник — за своего.
drop policy if exists fe_read on finals_events;
create policy fe_read on finals_events for select using (finals_is_member(session_id));
drop policy if exists fe_insert on finals_events;
create policy fe_insert on finals_events for insert with check (
  author = auth.uid() and (
    exists (select 1 from finals_sessions s where s.id = session_id and s.host_id = auth.uid())
    or exists (
      select 1 from finals_session_members m
      where m.session_id = finals_events.session_id and m.user_id = auth.uid() and m.status = 'accepted'
        and (m.role in ('coach', 'helper') or m.target_id = finals_events.who)
    )
  )
);

-- ===== Realtime (приватный Broadcast `final:<session_id>`) =====
-- Войти в канал и писать в него могут хозяин и участники сессии.
create or replace function is_finals_realtime_member(p_topic text, p_user uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare sid uuid;
begin
  if p_topic !~ '^final:' then
    return false;
  end if;
  begin
    sid := substr(p_topic, 7)::uuid;
  exception when others then
    return false;
  end;
  return exists (select 1 from finals_sessions s where s.id = sid and s.host_id = p_user)
      or exists (select 1 from finals_session_members m
                 where m.session_id = sid and m.user_id = p_user and m.status = 'accepted');
end $$;

drop policy if exists finals_realtime_read on realtime.messages;
create policy finals_realtime_read on realtime.messages
  for select to authenticated
  using (is_finals_realtime_member(realtime.topic(), auth.uid()));

drop policy if exists finals_realtime_write on realtime.messages;
create policy finals_realtime_write on realtime.messages
  for insert to authenticated
  with check (is_finals_realtime_member(realtime.topic(), auth.uid()));
