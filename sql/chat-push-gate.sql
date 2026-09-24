-- Экономия квоты Edge Function (Free: 500 тыс. вызовов в месяц).
-- Вместо Database Webhook (вызывает функцию на КАЖДОЕ сообщение) —
-- триггер, который вызывает send-chat-push только на первое сообщение
-- от данного отправителя данному получателю после паузы (по умолчанию
-- 120 с). Остальные сообщения получатель подхватит при опросе; сигналы
-- «позвать» (call / call_ack / call_cancel) идут всегда, edit/delete —
-- никогда.
--
-- Установка (один раз, в чат-проекте):
--   1. Edge Functions → Secrets: добавить PUSH_SECRET (любая длинная
--      случайная строка) и заново развернуть send-chat-push.
--   2. Ниже заменить <ТА-ЖЕ-СТРОКА> на этот секрет и выполнить файл.
--   3. Database → Webhooks: УДАЛИТЬ старые вебхуки на chat_messages и
--      chat_global_messages (иначе push придёт дважды; с включённым
--      PUSH_SECRET функция и так отклонит вызовы без секрета).
-- Секрет лежит в таблице без политик RLS — клиенты (anon/authenticated)
-- прочитать её не могут.

create extension if not exists pg_net with schema extensions;

create table if not exists chat_push_config (
  id            int primary key default 1 check (id = 1),
  function_url  text not null,
  secret        text not null,
  quiet_seconds int  not null default 120
);
alter table chat_push_config enable row level security;
revoke all on chat_push_config from anon, authenticated;

insert into chat_push_config (id, function_url, secret)
values (1, 'https://frbptucrvmyikencyspu.supabase.co/functions/v1/send-chat-push', '<ТА-ЖЕ-СТРОКА>')
on conflict (id) do update set function_url = excluded.function_url, secret = excluded.secret;

create table if not exists chat_push_last (
  sender_id    uuid not null,
  recipient_id uuid not null,
  at           timestamptz not null,
  primary key (sender_id, recipient_id)
);
alter table chat_push_last enable row level security;
revoke all on chat_push_last from anon, authenticated;

create or replace function chat_push_gate() returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  cfg chat_push_config;
  n   int;
begin
  if new.msg_type in ('edit', 'delete') then
    return new;
  end if;
  select * into cfg from chat_push_config where id = 1;
  if not found then
    return new;
  end if;

  if new.msg_type not in ('call', 'call_ack', 'call_cancel') then
    -- Вставит строку или обновит, только если пауза уже прошла; иначе 0 строк.
    insert into chat_push_last (sender_id, recipient_id, at)
    values (new.sender_id, new.recipient_id, now())
    on conflict (sender_id, recipient_id) do update set at = now()
      where chat_push_last.at < now() - make_interval(secs => cfg.quiet_seconds);
    get diagnostics n = row_count;
    if n = 0 then
      return new;
    end if;
  end if;

  perform net.http_post(
    url     := cfg.function_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg.secret),
    body    := jsonb_build_object('table', 'chat_messages', 'record', to_jsonb(new))
  );
  return new;
exception when others then
  -- Сбой push не должен ломать саму отправку сообщения.
  return new;
end;
$$;

drop trigger if exists chat_push_gate on chat_messages;
create trigger chat_push_gate after insert on chat_messages
  for each row execute function chat_push_gate();
