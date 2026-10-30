-- Личный канал входящих звонков `ucall:<id пользователя>` (Supabase Realtime, приватные каналы).
-- Слушать (select) может только сам владелец канала; писать (insert) — любой вошедший: так звонящий
-- отправляет «звонят» в канал собеседника. Нужно для звонков тем, у кого нет push (веб на iPhone).
-- Откат: drop policy ucall_realtime_read / ucall_realtime_write on realtime.messages;
drop policy if exists ucall_realtime_read on realtime.messages;
create policy ucall_realtime_read on realtime.messages
  for select to authenticated
  using (realtime.topic() = 'ucall:' || auth.uid()::text);

drop policy if exists ucall_realtime_write on realtime.messages;
create policy ucall_realtime_write on realtime.messages
  for insert to authenticated
  with check (realtime.topic() like 'ucall:%');
