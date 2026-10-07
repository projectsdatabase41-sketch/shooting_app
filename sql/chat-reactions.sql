-- Реакции (смайлики) на сообщения мессенджера. Выполнять в публичной базе
-- (yirvomezybprdlntxyas) ПОСЛЕ chat-schema.sql и chat-push-gate.sql.
-- Повторный запуск безопасен.
--
-- Реакция — транзитная строка msg_type = 'reaction': text — смайлик ('-' снять
-- реакцию), edit_of_client_message_id — сообщение, на которое реакция. Клиент
-- применяет её и удаляет строку, как правку/удаление.

alter table chat_messages drop constraint if exists chat_messages_msg_type_check;
alter table chat_messages add constraint chat_messages_msg_type_check
  check (msg_type in ('text','image','video','audio','file','edit','delete','call','call_ack','call_cancel','read','reaction'));

alter table chat_messages drop constraint if exists chat_messages_check;
alter table chat_messages drop constraint if exists chat_messages_content_check;
alter table chat_messages add constraint chat_messages_content_check
  check (
    (msg_type = 'text' and text is not null and attachment_path is null and drive_file_id is null)
    or (msg_type in ('image','video','audio','file') and (attachment_path is not null or drive_file_id is not null))
    or (msg_type = 'edit' and edit_of_client_message_id is not null and text is not null)
    or (msg_type = 'delete' and delete_of_client_message_id is not null)
    or (msg_type = 'call')
    or (msg_type = 'call_ack' and ack_of_client_message_id is not null)
    or (msg_type = 'call_cancel' and cancel_of_client_message_id is not null)
    or (msg_type = 'read' and text is not null)
    or (msg_type = 'reaction' and edit_of_client_message_id is not null and text is not null)
  );

-- Реакция не должна слать push «новое сообщение» (как правка и удаление).
create or replace function chat_push_gate() returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  cfg chat_push_config;
  n   int;
begin
  if new.msg_type in ('edit', 'delete', 'reaction') then
    return new;
  end if;
  select * into cfg from chat_push_config where id = 1;
  if not found then
    return new;
  end if;

  if new.msg_type not in ('call', 'call_ack', 'call_cancel') then
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
  return new;
end;
$$;
