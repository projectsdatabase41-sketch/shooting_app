-- Одно активное устройство на аккаунт мессенджера. Очередь входящих
-- одноразовая (опросившее устройство забирает и удаляет строки), поэтому при
-- входе с двух устройств сообщения «съедало» одно из них. Теперь входящие
-- забирает только то устройство, которое отмечено активным; второе показывает
-- «Использовать здесь».
-- Выполнять в публичной базе (yirvomezybprdlntxyas). Повторный запуск безопасен.
alter table chat_profiles add column if not exists active_device text;

create or replace function chat_claim_device(p_device text)
returns void
language sql
security definer
set search_path = public
as $$
  update chat_profiles set active_device = p_device where user_id = auth.uid();
$$;

create or replace function chat_active_device()
returns text
language sql
security definer
set search_path = public
as $$
  select active_device from chat_profiles where user_id = auth.uid();
$$;

revoke all on function chat_claim_device(text), chat_active_device() from public, anon;
grant execute on function chat_claim_device(text), chat_active_device() to authenticated;
