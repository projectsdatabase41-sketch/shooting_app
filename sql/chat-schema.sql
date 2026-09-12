-- Схема ОТДЕЛЬНОГО Supabase-проекта для публичного чата — НЕ той базы,
-- что хранит книги/правила (AiSettings.booksUrl), и НЕ личной базы
-- спортсмена/тренера. Один проект на ВСЕХ пользователей приложения,
-- только транзит сообщений и вложений — история переписки хранится на
-- устройствах (см. lib/services/chat_sync_service.dart).
--
-- Идемпотентно: файл можно накатывать повторно на уже созданную базу
-- (IF NOT EXISTS / ADD COLUMN IF NOT EXISTS / DROP POLICY IF EXISTS
-- везде, где это применимо) — расширение вложений добавлено этим же
-- файлом поверх исходной версии с одним текстом.
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
--
-- Вложения (фото/видео/файлы/голосовые — как в Telegram/WhatsApp):
-- сам файл лежит в Storage (бакет chat-media, см. ниже), в строке —
-- только путь к нему и метаданные. Тот же принцип "только транзит":
-- объект в Storage удаляется ВМЕСТЕ со строкой, как только получатель
-- скачал файл (клиент делает оба удаления одним махом).
create table if not exists chat_messages (
  id                     uuid primary key default gen_random_uuid(),
  client_message_id      text not null,
  sender_id              uuid not null references auth.users(id) on delete cascade,
  recipient_id           uuid not null references auth.users(id) on delete cascade,
  -- Текст теперь необязателен — сообщение может быть чистым вложением
  -- (фото без подписи) или подписью к вложению одновременно.
  text                   text,
  -- 'text' — только текст; 'image'/'video'/'audio'/'file' — есть вложение.
  msg_type               text not null default 'text'
                           check (msg_type in ('text','image','video','audio','file')),
  attachment_path        text,   -- путь объекта в бакете chat-media
  attachment_name        text,   -- исходное имя файла (для 'file')
  attachment_mime        text,
  attachment_size        bigint, -- байты — показать "2.4 МБ" и свериться с лимитом на клиенте
  attachment_duration_ms integer, -- для video/audio — длительность, если известна
  attachment_width       integer, -- для image/video — пропорции превью до загрузки самого файла
  attachment_height      integer,
  created_at             timestamptz not null default now(),
  unique (sender_id, client_message_id),
  -- Сообщение либо текстовое (text заполнен, вложения нет), либо с
  -- вложением (attachment_path заполнен) — оба сразу тоже можно
  -- (подпись к фото), но не "ничего": пустых сообщений не бывает.
  check (
    (msg_type = 'text' and text is not null and attachment_path is null)
    or (msg_type <> 'text' and attachment_path is not null)
  )
);

-- Столбцы вложений добавляются и на уже существующую (по прежней
-- версии этого файла) таблицу chat_messages.
alter table chat_messages alter column text drop not null;
alter table chat_messages add column if not exists msg_type text not null default 'text';
alter table chat_messages add column if not exists attachment_path text;
alter table chat_messages add column if not exists attachment_name text;
alter table chat_messages add column if not exists attachment_mime text;
alter table chat_messages add column if not exists attachment_size bigint;
alter table chat_messages add column if not exists attachment_duration_ms integer;
alter table chat_messages add column if not exists attachment_width integer;
alter table chat_messages add column if not exists attachment_height integer;

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

-- ============================================================
-- Вложения: бакет Storage + политики.
--
-- Приватный бакет (public = false) — файл отдаётся только по запросу
-- с JWT отправителя/получателя через RLS ниже, никаких публичных ссылок.
-- Лимит размера — 50 МБ на файл (видео с телефона обычно крупнее фото
-- и голосовых, но такого лимита хватает с запасом; поднять его можно
-- здесь же). Разрешённые типы НЕ ограничены нарочно — как и в
-- Telegram/WhatsApp, вложением может быть любой файл, а не только
-- заранее одобренный список форматов.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-media', 'chat-media', false, 52428800)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

-- Путь объекта — обязательно "<sender_id>/<что угодно>", это же и
-- проверяет политика на вставку. Клиент формирует путь сам, например
-- "<sender_id>/<client_message_id>/<исходное_имя>".
drop policy if exists chat_media_insert on storage.objects;
create policy chat_media_insert on storage.objects
  for insert
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Скачать/увидеть объект может только тот, кто есть отправителем или
-- получателем в СТРОКЕ chat_messages, которая на него ссылается —
-- значит, как только строку удалили (сообщение доставлено), скачать
-- файл по старому пути больше нельзя, даже если объект технически ещё
-- не стёрт.
drop policy if exists chat_media_select on storage.objects;
create policy chat_media_select on storage.objects
  for select
  using (
    bucket_id = 'chat-media'
    and exists (
      select 1 from chat_messages m
      where m.attachment_path = storage.objects.name
        and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())
    )
  );

drop policy if exists chat_media_delete on storage.objects;
create policy chat_media_delete on storage.objects
  for delete
  using (
    bucket_id = 'chat-media'
    and exists (
      select 1 from chat_messages m
      where m.attachment_path = storage.objects.name
        and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())
    )
  );

notify pgrst, 'reload schema';
