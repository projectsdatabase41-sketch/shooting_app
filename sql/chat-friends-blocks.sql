-- Мессенджер: друзья (явные заявки) и чёрный список. Выполнять в публичной
-- базе (yirvomezybprdlntxyas) после chat-schema.sql и chat-groups.sql.
-- Повторный запуск безопасен.
--
-- Дружба — только по явной заявке (request_friend). Встречная заявка сразу
-- превращается в дружбу. Автоматическая заявка остаётся лишь для тех, кто
-- включил «писать могут только друзья»: первое сообщение незнакомца
-- становится заявкой (триггер ниже; клиент больше этого не делает).

create or replace function chat_auto_friend_request() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.group_id is null
     and new.msg_type in ('text', 'image', 'video', 'audio', 'file', 'call')
     and exists (select 1 from chat_profiles where user_id = new.recipient_id and privacy_mode = 'friends_only')
     and not exists (select 1 from chat_friends
                     where (requester_id = new.sender_id and addressee_id = new.recipient_id)
                        or (requester_id = new.recipient_id and addressee_id = new.sender_id)) then
    insert into chat_friends (requester_id, addressee_id) values (new.sender_id, new.recipient_id) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists chat_messages_auto_friend on chat_messages;
create trigger chat_messages_auto_friend after insert on chat_messages
  for each row execute function chat_auto_friend_request();

-- ---------- Чёрный список ----------
create table if not exists chat_blocks (
  blocker_id  uuid not null references auth.users(id) on delete cascade,
  blocked_id  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
alter table chat_blocks enable row level security;
drop policy if exists chat_blocks_own on chat_blocks;
create policy chat_blocks_own on chat_blocks for all
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- Сообщение от заблокированного молча не сохраняется (и push не уходит:
-- триггер push срабатывает только на сохранённые строки). Отправитель
-- ошибки не видит.
create or replace function chat_drop_blocked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from chat_blocks where blocker_id = new.recipient_id and blocked_id = new.sender_id) then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists chat_messages_block on chat_messages;
create trigger chat_messages_block before insert on chat_messages
  for each row execute function chat_drop_blocked();

-- ---------- Функции для приложения ----------

-- Добавить в друзья: встречная заявка → сразу дружба; иначе — заявка.
create or replace function request_friend(p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_user = auth.uid() then raise exception 'bad user'; end if;
  if exists (select 1 from chat_blocks where (blocker_id = auth.uid() and blocked_id = p_user)
                                        or (blocker_id = p_user and blocked_id = auth.uid())) then
    return 'blocked';
  end if;
  if exists (select 1 from chat_friends where status = 'accepted'
             and ((requester_id = auth.uid() and addressee_id = p_user) or (requester_id = p_user and addressee_id = auth.uid()))) then
    return 'accepted';
  end if;
  update chat_friends set status = 'accepted' where requester_id = p_user and addressee_id = auth.uid();
  if found then
    delete from chat_friends where requester_id = auth.uid() and addressee_id = p_user and status = 'pending';
    return 'accepted';
  end if;
  insert into chat_friends (requester_id, addressee_id) values (auth.uid(), p_user) on conflict do nothing;
  return 'pending';
end $$;

-- Ответ на входящую заявку: принять или отклонить.
create or replace function respond_friend(p_user uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_accept then
    update chat_friends set status = 'accepted' where requester_id = p_user and addressee_id = auth.uid();
  else
    delete from chat_friends where requester_id = p_user and addressee_id = auth.uid();
  end if;
end $$;

-- Убрать из друзей / отменить свою заявку — в обе стороны.
create or replace function remove_friend(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from chat_friends
  where (requester_id = auth.uid() and addressee_id = p_user) or (requester_id = p_user and addressee_id = auth.uid());
$$;

-- Все связи: friend | incoming (мне прислали) | outgoing (жду ответа).
create or replace function friend_overview()
returns table(user_id uuid, nickname text, avatar_base64 text, about text, state text)
language sql stable security definer set search_path = public as $$
  select distinct on (o.other) o.other, p.nickname, p.avatar_base64, p.about, o.state
  from (
    select case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end as other,
           case when f.status = 'accepted' then 'friend'
                when f.requester_id = auth.uid() then 'outgoing' else 'incoming' end as state
    from chat_friends f
    where auth.uid() in (f.requester_id, f.addressee_id)
  ) o
  join chat_profiles p on p.user_id = o.other
  where not exists (select 1 from chat_blocks b where b.blocker_id = auth.uid() and b.blocked_id = o.other)
  order by o.other, (o.state = 'friend') desc, (o.state = 'incoming') desc;
$$;

-- Заблокировать: в чёрный список + убрать дружбу и заявки.
create or replace function block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_user = auth.uid() then raise exception 'bad user'; end if;
  insert into chat_blocks (blocker_id, blocked_id) values (auth.uid(), p_user) on conflict do nothing;
  delete from chat_friends
  where (requester_id = auth.uid() and addressee_id = p_user) or (requester_id = p_user and addressee_id = auth.uid());
end $$;

create or replace function unblock_user(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from chat_blocks where blocker_id = auth.uid() and blocked_id = p_user;
$$;

create or replace function my_blocks()
returns table(user_id uuid, nickname text, avatar_base64 text, blocked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select b.blocked_id, coalesce(p.nickname, '—'), p.avatar_base64, b.created_at
  from chat_blocks b left join chat_profiles p on p.user_id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc;
$$;

revoke all on function request_friend(uuid) from public, anon;
revoke all on function respond_friend(uuid, boolean) from public, anon;
revoke all on function remove_friend(uuid) from public, anon;
revoke all on function friend_overview() from public, anon;
revoke all on function block_user(uuid) from public, anon;
revoke all on function unblock_user(uuid) from public, anon;
revoke all on function my_blocks() from public, anon;
grant execute on function request_friend(uuid) to authenticated;
grant execute on function respond_friend(uuid, boolean) to authenticated;
grant execute on function remove_friend(uuid) to authenticated;
grant execute on function friend_overview() to authenticated;
grant execute on function block_user(uuid) to authenticated;
grant execute on function unblock_user(uuid) to authenticated;
grant execute on function my_blocks() to authenticated;

notify pgrst, 'reload schema';
