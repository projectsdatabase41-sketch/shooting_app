-- Публичная база (мессенджер). Один push-токен устройства = один аккаунт.
-- Раньше при смене аккаунта на том же браузере/телефоне токен оставался и у старого
-- аккаунта, и пуши старого продолжали приходить. Идемпотентно.

create or replace function chat_push_tokens_one_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from chat_push_tokens where token = new.token and user_id <> new.user_id;
  return new;
end;
$$;

drop trigger if exists trg_chat_push_tokens_one_owner on chat_push_tokens;
create trigger trg_chat_push_tokens_one_owner
  after insert or update on chat_push_tokens
  for each row execute function chat_push_tokens_one_owner();

-- Разовая чистка: если один токен у нескольких аккаунтов — оставить самую свежую запись.
delete from chat_push_tokens a
using chat_push_tokens b
where a.token = b.token and a.user_id <> b.user_id and a.updated_at < b.updated_at;
