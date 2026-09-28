-- Живой канал ГРУППЫ (Supabase Realtime, приватные каналы) — аналог
-- dm-канала личных чатов (sql/chat-schema.sql, ближе к концу файла), но
-- участников не двое, а сколько в группе. Канал называется
-- `group:<group_id>`, войти и писать может только участник группы
-- (chat_group_members, см. sql/chat-groups.sql).
--
-- Ускоряет только тех, кто сейчас держит группу открытой (мгновенная
-- доставка текста + presence без опроса) — офлайн-участники и история
-- по-прежнему идут обычным путём через chat_messages (fan-out по
-- участникам при отправке, см. ChatSyncService._fanOut), этот канал его
-- не заменяет.
--
-- Выполнять в публичном проекте (yirvom), после sql/chat-groups.sql
-- (нужна функция is_group_member).

create or replace function is_group_realtime_topic_member(p_topic text, p_user uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  gid uuid;
begin
  if p_topic !~ '^group:' then
    return false;
  end if;
  begin
    gid := substr(p_topic, 7)::uuid;
  exception when others then
    return false; -- не uuid — не наш канал, не 500-ка
  end;
  return is_group_member(gid, p_user);
end;
$$;

drop policy if exists group_realtime_read on realtime.messages;
create policy group_realtime_read on realtime.messages
  for select to authenticated
  using (is_group_realtime_topic_member(realtime.topic(), auth.uid()));

drop policy if exists group_realtime_write on realtime.messages;
create policy group_realtime_write on realtime.messages
  for insert to authenticated
  with check (is_group_realtime_topic_member(realtime.topic(), auth.uid()));
