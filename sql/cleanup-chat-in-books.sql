-- Уборка: sql/chat-schema.sql и sql/chat-groups.sql по ошибке выполнены в
-- ОБЩЕЙ БАЗЕ КНИГ (yirvomezybprdlntxyas), а не на сервере мессенджера
-- (frbptucrvmyikencyspu). Этот файл убирает созданное ими — и ТОЛЬКО это.
-- Выполнять ТОЛЬКО в проекте yirvomezybprdlntxyas. Книги, правила и память
-- ИИ не трогаются. Расширения pgcrypto и pg_net не удаляются — ими могут
-- пользоваться другие части базы.

-- Страховка: если таблицы мессенджера здесь не пустые — остановиться,
-- значит это не тот проект.
do $$
begin
  if to_regclass('public.chat_profiles') is not null
     and (select count(*) from public.chat_profiles) > 0 then
    raise exception 'chat_profiles не пустая — похоже, это настоящий сервер мессенджера. Остановлено.';
  end if;
end $$;

-- Политики на системных таблицах (Storage, Realtime)
drop policy if exists chat_media_insert on storage.objects;
drop policy if exists chat_media_select on storage.objects;
drop policy if exists chat_media_delete on storage.objects;
drop policy if exists chat_global_media_insert on storage.objects;
drop policy if exists chat_global_media_select on storage.objects;
drop policy if exists chat_global_media_delete on storage.objects;
drop policy if exists dm_realtime_read on realtime.messages;
drop policy if exists dm_realtime_write on realtime.messages;

-- Таблицы (вместе с их триггерами и политиками)
drop table if exists public.chat_group_members cascade;
drop table if exists public.chat_groups cascade;
drop table if exists public.chat_messages cascade;
drop table if exists public.chat_global_messages cascade;
drop table if exists public.chat_friends cascade;
drop table if exists public.chat_push_tokens cascade;
drop table if exists public.chat_profiles cascade;

-- Функции
drop function if exists public.add_group_members(uuid, uuid[]);
drop function if exists public.create_group(text, text, text, text, uuid[]);
drop function if exists public.update_group(uuid, text, text, text, text);
drop function if exists public.remove_group_member(uuid, uuid);
drop function if exists public.set_group_role(uuid, uuid, text);
drop function if exists public.my_groups();
drop function if exists public.is_group_member(uuid, uuid);
drop function if exists public.is_group_admin(uuid, uuid);
drop function if exists public.search_profiles(text, int, int);
drop function if exists public.resolve_chat_code(text);
drop function if exists public.resolve_profiles(uuid[]);
drop function if exists public.delete_own_chat_account();
drop function if exists public.chat_notify_push();
drop function if exists public.chat_global_trim();

-- Хранилище файлов мессенджера (пустое): удалить через интерфейс —
-- Storage → бакет chat-media → «Delete bucket». Напрямую из SQL Supabase
-- таблицы хранилища менять не даёт.
