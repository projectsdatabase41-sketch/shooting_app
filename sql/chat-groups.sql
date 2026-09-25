-- Мессенджер: поиск участников и группы. Выполнить ОДИН раз в чат-проекте
-- (yirvomezybprdlntxyas — публичная база) после sql/chat-schema.sql. Повторный запуск безопасен.

-- ============================================================
-- Поиск участников: по имени, «о себе» или точному коду контакта.
-- Код наружу не отдаётся (как и раньше — им только находят).
-- ============================================================
create or replace function search_profiles(p_query text, p_limit int default 30, p_offset int default 0)
returns table(user_id uuid, nickname text, avatar_base64 text, about text)
language sql
stable
security definer
set search_path = public
as $$
  select p.user_id, p.nickname, p.avatar_base64, p.about
  from chat_profiles p
  where p.user_id <> auth.uid()
    and (
      coalesce(trim(p_query), '') = ''
      or p.nickname ilike '%' || trim(p_query) || '%'
      or p.about ilike '%' || trim(p_query) || '%'
      or upper(p.chat_code) = upper(trim(p_query))
    )
  order by lower(p.nickname), p.user_id
  limit least(greatest(coalesce(p_limit, 30), 1), 50)
  offset greatest(coalesce(p_offset, 0), 0);
$$;
revoke all on function search_profiles(text, int, int) from public, anon;
grant execute on function search_profiles(text, int, int) to authenticated;

-- ============================================================
-- Группы. Сообщения группы идут через ту же транзитную таблицу
-- chat_messages: отправитель кладёт по строке на каждого участника
-- (group_id заполнен). Так работают опрос, push и удаление после
-- получения — без отдельного механизма.
-- ============================================================
create table if not exists chat_groups (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(name) between 1 and 60),
  about         text not null default '' check (char_length(about) <= 200),
  avatar_base64 text,
  color         text not null default '',
  owner_id      uuid not null references auth.users(id) on delete cascade,
  created_at    timestamptz not null default now()
);

create table if not exists chat_group_members (
  group_id  uuid not null references chat_groups(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  role      text not null default 'member' check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

alter table chat_groups enable row level security;
alter table chat_group_members enable row level security;

create or replace function is_group_member(p_group uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from chat_group_members where group_id = p_group and user_id = p_user);
$$;

create or replace function is_group_admin(p_group uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from chat_group_members
    where group_id = p_group and user_id = p_user and role in ('owner', 'admin')
  );
$$;

-- Читать — только участникам; менять состав и настройки — только через
-- функции ниже (прямые insert/update/delete запрещены отсутствием политик).
drop policy if exists chat_groups_read on chat_groups;
create policy chat_groups_read on chat_groups
  for select to authenticated using (is_group_member(id, auth.uid()));

drop policy if exists chat_group_members_read on chat_group_members;
create policy chat_group_members_read on chat_group_members
  for select to authenticated using (is_group_member(group_id, auth.uid()));

-- Лимит участников — строк в транзитной таблице на одно сообщение.
create or replace function create_group(p_name text, p_about text, p_color text, p_avatar text, p_member_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  gid uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if coalesce(array_length(p_member_ids, 1), 0) > 99 then raise exception 'too many members (max 100)'; end if;
  insert into chat_groups (name, about, color, avatar_base64, owner_id)
  values (trim(p_name), coalesce(trim(p_about), ''), coalesce(p_color, ''), p_avatar, auth.uid())
  returning id into gid;
  insert into chat_group_members (group_id, user_id, role) values (gid, auth.uid(), 'owner');
  insert into chat_group_members (group_id, user_id)
  select gid, m from unnest(p_member_ids) m
  where m <> auth.uid() and exists (select 1 from chat_profiles where user_id = m)
  on conflict do nothing;
  return gid;
end;
$$;

create or replace function update_group(p_group uuid, p_name text, p_about text, p_color text, p_avatar text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_group_admin(p_group, auth.uid()) then raise exception 'only group admins can edit'; end if;
  update chat_groups
  set name = trim(p_name), about = coalesce(trim(p_about), ''), color = coalesce(p_color, ''), avatar_base64 = p_avatar
  where id = p_group;
end;
$$;

create or replace function add_group_members(p_group uuid, p_member_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_group_admin(p_group, auth.uid()) then raise exception 'only group admins can add members'; end if;
  insert into chat_group_members (group_id, user_id)
  select p_group, m from unnest(p_member_ids) m
  where exists (select 1 from chat_profiles where user_id = m)
  on conflict do nothing;
  if (select count(*) from chat_group_members where group_id = p_group) > 100 then
    raise exception 'too many members (max 100)';
  end if;
end;
$$;

-- Убрать участника (админ) или выйти самому. Владелец уходит — права
-- переходят самому давнему участнику; последний ушёл — группа удаляется.
create or replace function remove_group_member(p_group uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  was_owner boolean;
  heir uuid;
begin
  if p_user <> auth.uid() and not is_group_admin(p_group, auth.uid()) then
    raise exception 'only group admins can remove members';
  end if;
  if p_user <> auth.uid()
     and exists (select 1 from chat_group_members where group_id = p_group and user_id = p_user and role = 'owner') then
    raise exception 'owner cannot be removed';
  end if;
  select role = 'owner' into was_owner from chat_group_members where group_id = p_group and user_id = p_user;
  delete from chat_group_members where group_id = p_group and user_id = p_user;
  if coalesce(was_owner, false) then
    select user_id into heir from chat_group_members where group_id = p_group
    order by (role = 'admin') desc, joined_at limit 1;
    if heir is null then
      delete from chat_groups where id = p_group;
    else
      update chat_group_members set role = 'owner' where group_id = p_group and user_id = heir;
      update chat_groups set owner_id = heir where id = p_group;
    end if;
  end if;
end;
$$;

create or replace function set_group_role(p_group uuid, p_user uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from chat_group_members where group_id = p_group and user_id = auth.uid() and role = 'owner') then
    raise exception 'only the owner can change roles';
  end if;
  if p_role not in ('admin', 'member') then raise exception 'bad role'; end if;
  update chat_group_members set role = p_role where group_id = p_group and user_id = p_user and role <> 'owner';
end;
$$;

-- Все мои группы с участниками — одним запросом (синхронизация списка).
create or replace function my_groups()
returns table(id uuid, name text, about text, avatar_base64 text, color text, members jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select g.id, g.name, g.about, g.avatar_base64, g.color,
    (select coalesce(jsonb_agg(jsonb_build_object('id', m.user_id, 'nickname', coalesce(p.nickname, '—'), 'role', m.role)
                               order by m.joined_at), '[]'::jsonb)
     from chat_group_members m left join chat_profiles p on p.user_id = m.user_id
     where m.group_id = g.id) as members
  from chat_groups g
  where is_group_member(g.id, auth.uid());
$$;

revoke all on function create_group(text, text, text, text, uuid[]) from public, anon;
revoke all on function update_group(uuid, text, text, text, text) from public, anon;
revoke all on function add_group_members(uuid, uuid[]) from public, anon;
revoke all on function remove_group_member(uuid, uuid) from public, anon;
revoke all on function set_group_role(uuid, uuid, text) from public, anon;
revoke all on function my_groups() from public, anon;
grant execute on function create_group(text, text, text, text, uuid[]) to authenticated;
grant execute on function update_group(uuid, text, text, text, text) to authenticated;
grant execute on function add_group_members(uuid, uuid[]) to authenticated;
grant execute on function remove_group_member(uuid, uuid) to authenticated;
grant execute on function set_group_role(uuid, uuid, text) to authenticated;
grant execute on function my_groups() to authenticated;

-- Транзитная таблица: строка на каждого участника группы.
alter table chat_messages add column if not exists group_id uuid references chat_groups(id) on delete cascade;
-- Одно и то же сообщение группы уходит нескольким получателям — уникальность
-- теперь по (отправитель, получатель, id сообщения).
alter table chat_messages drop constraint if exists chat_messages_sender_id_client_message_id_key;
alter table chat_messages drop constraint if exists chat_messages_sender_recipient_client_key;
alter table chat_messages add constraint chat_messages_sender_recipient_client_key
  unique (sender_id, recipient_id, client_message_id);

drop policy if exists chat_messages_insert on chat_messages;
create policy chat_messages_insert on chat_messages
  for insert
  with check (
    sender_id = auth.uid()
    and (group_id is null or (is_group_member(group_id, auth.uid()) and is_group_member(group_id, recipient_id)))
  );
