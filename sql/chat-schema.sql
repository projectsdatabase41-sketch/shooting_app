-- Схема ОТДЕЛЬНОГО Supabase-проекта для публичного чата — НЕ той базы,
-- что хранит книги/правила (AiSettings.booksUrl), и НЕ личной базы
-- спортсмена/тренера. Один проект на ВСЕХ пользователей приложения,
-- только транзит сообщений — история переписки хранится на устройствах
-- (см. lib/services/chat_sync_service.dart).
--
-- После создания проекта:
-- 1. Накатить этот файл в SQL Editor.
-- 2. Settings → API → скопировать Project URL и anon/publishable key.
-- 3. Вписать их в lib/services/chat_settings.dart (сейчас там пустые
--    строки) — этим включается вся уже готовая клиентская часть.
-- 4. В Auth → Providers по желанию отключить подтверждение почты
--    (решение пользователя: для этого чата оно не нужно).

create extension if not exists pgcrypto;

-- Публичный профиль поверх auth.users — никнейм и код контакта.
-- Внутренний user_id никогда не отдаётся клиенту напрямую в списках,
-- только через resolve_chat_code (см. ниже) при явном добавлении.
create table if not exists chat_profiles (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  nickname       text not null,
  chat_code      text not null unique,
  avatar_base64  text,
  created_at     timestamptz not null default now()
);

-- Сообщения — временная очередь. Строка живёт от отправки до того, как
-- получатель её заберёт (клиент удаляет её сам после чтения, см.
-- ChatSyncService.pollIncoming) — история не копится в базе вовсе.
create table if not exists chat_messages (
  id                  uuid primary key default gen_random_uuid(),
  client_message_id   text not null,
  sender_id           uuid not null references auth.users(id) on delete cascade,
  recipient_id        uuid not null references auth.users(id) on delete cascade,
  text                text not null,
  created_at          timestamptz not null default now(),
  unique (sender_id, client_message_id)
);

create index if not exists idx_chat_messages_recipient on chat_messages(recipient_id);

alter table chat_profiles enable row level security;
alter table chat_messages enable row level security;

-- Профиль: видит и правит только свой собственный (найти чужой можно
-- ТОЛЬКО через resolve_chat_code ниже, не прямым select).
drop policy if exists chat_profiles_self on chat_profiles;
create policy chat_profiles_self on chat_profiles
  for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Сообщения: отправлять можно только от своего имени, читать/удалять —
-- только свои входящие или то, что сам отправил.
drop policy if exists chat_messages_insert on chat_messages;
create policy chat_messages_insert on chat_messages
  for insert
  with check (sender_id = auth.uid());

drop policy if exists chat_messages_select on chat_messages;
create policy chat_messages_select on chat_messages
  for select
  using (recipient_id = auth.uid() or sender_id = auth.uid());

drop policy if exists chat_messages_delete on chat_messages;
create policy chat_messages_delete on chat_messages
  for delete
  using (recipient_id = auth.uid() or sender_id = auth.uid());

-- Поиск собеседника по коду контакта — SECURITY DEFINER, чтобы клиент
-- не мог читать всю таблицу профилей, только находить один по точному
-- коду (пункт из обсуждения: внутренний ID и полный список пользователей
-- наружу не отдаются).
create or replace function resolve_chat_code(p_code text)
returns table(user_id uuid, nickname text, avatar_base64 text)
language sql
security definer
set search_path = public
as $$
  select user_id, nickname, avatar_base64
  from chat_profiles
  where chat_code = p_code;
$$;

notify pgrst, 'reload schema';
