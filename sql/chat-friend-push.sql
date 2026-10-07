-- Push «вам прислали заявку в друзья». Выполнять в публичной базе
-- (yirvomezybprdlntxyas) ПОСЛЕ chat-push-gate.sql и chat-friends-blocks.sql.
-- Повторный запуск безопасен. Затем задеплоить функцию send-chat-push
-- (supabase/functions/send-chat-push) — в ней добавлена ветка chat_friends.

create or replace function chat_friend_push() returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  cfg chat_push_config;
begin
  if new.status is distinct from 'pending' then
    return new;
  end if;
  select * into cfg from chat_push_config where id = 1;
  if not found then
    return new;
  end if;
  perform net.http_post(
    url     := cfg.function_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg.secret),
    body    := jsonb_build_object('table', 'chat_friends', 'record', to_jsonb(new))
  );
  return new;
exception when others then
  -- Сбой push не должен ломать саму заявку.
  return new;
end;
$$;

drop trigger if exists chat_friend_push on chat_friends;
create trigger chat_friend_push after insert on chat_friends
  for each row execute function chat_friend_push();
