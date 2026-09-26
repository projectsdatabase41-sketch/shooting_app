-- «В сети» для друзей. Клиент раз в минуту (пока открыт мессенджер) зовёт
-- chat_presence(): отмечает себя и получает время последнего появления
-- ТОЛЬКО принятых друзей — чужим оно не видно.
-- Выполнять в публичной базе (yirvomezybprdlntxyas). Повторный запуск безопасен.
alter table chat_profiles add column if not exists last_seen timestamptz;

create or replace function chat_presence()
returns table(user_id uuid, last_seen timestamptz)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  update chat_profiles set last_seen = now() where chat_profiles.user_id = auth.uid();
  return query
    select p.user_id, p.last_seen from chat_profiles p
    where p.last_seen is not null
      and exists (
        select 1 from chat_friends f
        where f.status = 'accepted'
          and ((f.requester_id = auth.uid() and f.addressee_id = p.user_id)
            or (f.addressee_id = auth.uid() and f.requester_id = p.user_id))
      );
end;
$$;
revoke all on function chat_presence() from public, anon;
grant execute on function chat_presence() to authenticated;
