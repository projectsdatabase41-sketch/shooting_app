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
  -- 'text' — только текст; 'image'/'video'/'audio'/'file' — есть вложение;
  -- 'edit'/'delete' — служебные сигналы к уже отправленному сообщению
  -- (см. ниже), а не новые сообщения сами по себе.
  msg_type               text not null default 'text'
                           check (msg_type in ('text','image','video','audio','file','edit','delete')),
  attachment_path        text,   -- путь объекта в бакете chat-media
  attachment_name        text,   -- исходное имя файла (для 'file')
  attachment_mime        text,
  attachment_size        bigint, -- байты — показать "2.4 МБ" и свериться с лимитом на клиенте
  attachment_duration_ms integer, -- для video/audio — длительность, если известна
  attachment_width       integer, -- для image/video — пропорции превью до загрузки самого файла
  attachment_height      integer,
  -- Правка/удаление задним числом — client_message_id ОРИГИНАЛЬНОГО
  -- сообщения, к которому применяется сигнал (см. ChatSyncService.
  -- editMessage/deleteMessage). Ответ на сообщение — тоже по
  -- client_message_id, плюс короткая цитата на случай, если оригинал
  -- уже не найдётся у получателя локально.
  edit_of_client_message_id   text,
  delete_of_client_message_id text,
  reply_to_client_message_id  text,
  reply_to_preview             text,
  created_at             timestamptz not null default now(),
  unique (sender_id, client_message_id),
  -- Сообщение — ОДНО из: текст, вложение (+ опц. подпись), edit-сигнал
  -- (текст + ссылка на оригинал) или delete-сигнал (только ссылка на
  -- оригинал, без текста/вложения).
  check (
    (msg_type = 'text' and text is not null and attachment_path is null)
    or (msg_type in ('image','video','audio','file') and attachment_path is not null)
    or (msg_type = 'edit' and edit_of_client_message_id is not null and text is not null)
    or (msg_type = 'delete' and delete_of_client_message_id is not null)
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
alter table chat_messages add column if not exists edit_of_client_message_id text;
alter table chat_messages add column if not exists delete_of_client_message_id text;
alter table chat_messages add column if not exists reply_to_client_message_id text;
alter table chat_messages add column if not exists reply_to_preview text;

-- CHECK не подвинуть ни ADD COLUMN, ни повторным CREATE TABLE — только
-- пересозданием ограничения. Оба варианта имени учтены (авто-имя из
-- первой версии этого файла и явное новое), поэтому блок безопасно
-- накатывать многократно.
alter table chat_messages drop constraint if exists chat_messages_msg_type_check;
alter table chat_messages add constraint chat_messages_msg_type_check
  check (msg_type in ('text','image','video','audio','file','edit','delete'));

alter table chat_messages drop constraint if exists chat_messages_check;
alter table chat_messages drop constraint if exists chat_messages_content_check;
alter table chat_messages add constraint chat_messages_content_check
  check (
    (msg_type = 'text' and text is not null and attachment_path is null)
    or (msg_type in ('image','video','audio','file') and attachment_path is not null)
    or (msg_type = 'edit' and edit_of_client_message_id is not null and text is not null)
    or (msg_type = 'delete' and delete_of_client_message_id is not null)
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

-- ============================================================
-- Общедоступный чат — один поток на ВСЕХ пользователей платформы
-- (пункт списка правок), в отличие от chat_messages (личная переписка
-- двоих, транзит-и-удаление). Здесь сообщения ХРАНЯТСЯ — это открытая
-- лента, а не очередь на доставку.
--
-- Рост базы: лента не чистится сама. Для МVP этого достаточно (клиент
-- забирает только последние N сообщений — см.
-- ChatGlobalService.fetchRecent), но при заметном трафике стоит
-- завести периодическую очистку (например, pg_cron на платных планах,
-- либо ручной DELETE по возрасту раз в какое-то время) — сознательно
-- не добавлено сейчас.
-- ============================================================

create table if not exists chat_global_messages (
  id          uuid primary key default gen_random_uuid(),
  sender_id   uuid not null references auth.users(id) on delete cascade,
  text        text not null,
  created_at  timestamptz not null default now()
);

create index if not exists idx_chat_global_created on chat_global_messages(created_at desc);

alter table chat_global_messages enable row level security;

-- Читать и писать может любой вошедший в чат пользователь (общий
-- канал) — но НЕ анонимный доступ: `to authenticated` требует
-- настоящий JWT, простого anon-ключа без входа недостаточно.
drop policy if exists chat_global_select on chat_global_messages;
create policy chat_global_select on chat_global_messages
  for select
  to authenticated
  using (true);

drop policy if exists chat_global_insert on chat_global_messages;
create policy chat_global_insert on chat_global_messages
  for insert
  to authenticated
  with check (sender_id = auth.uid());

-- Профиль по списку id — для отображения ников/аватаров в ленте общего
-- чата и в списке "Участники" (не отдаёт chat_code — им по-прежнему
-- находят собеседника только для ЛИЧНОГО чата, а не через общий поток).
create or replace function resolve_profiles(p_ids uuid[])
returns table(user_id uuid, nickname text, avatar_base64 text)
language sql
security definer
set search_path = public
as $$
  select user_id, nickname, avatar_base64
  from chat_profiles
  where user_id = any(p_ids);
$$;

-- ============================================================
-- Push-уведомления через Firebase (FCM) — ДОБАВКА к этой базе, не
-- замена: сама переписка/контакты/вход остаются здесь как есть, Firebase
-- нужен только чтобы разбудить закрытое приложение сигналом "новое
-- сообщение" (см. lib/services/push_service.dart и
-- supabase/functions/send-chat-push/index.ts — код функции, которую
-- нужно развернуть в Supabase, инструкция в её же файле).
-- ============================================================

create table if not exists chat_push_tokens (
  user_id     uuid not null references auth.users(id) on delete cascade,
  token       text not null,
  updated_at  timestamptz not null default now(),
  primary key (user_id, token)
);

alter table chat_push_tokens enable row level security;

-- Каждый пишет/удаляет только свой собственный токен; чужие токены
-- никому не видны и не нужны — рассылку делает функция ниже с
-- служебным ключом (service_role), в обход RLS, а не клиент.
drop policy if exists chat_push_tokens_self on chat_push_tokens;
create policy chat_push_tokens_self on chat_push_tokens
  for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ============================================================
-- Триггер, который зовёт Edge Function send-chat-push при новом
-- сообщении — тот же результат, что "Database → Webhooks" в
-- дашборде, но SQL-ом, без мастера интерфейса.
--
-- ПЕРЕД накаткой этого блока один раз выполнить (значение — Project
-- settings → API → service_role key; секрет хранится в Vault, а не в
-- этом файле, потому что файл лежит в git):
--   select vault.create_secret('<service_role_key>', 'service_role_key');
-- ============================================================

create extension if not exists pg_net;

-- ВАЖНО: весь код похода за секретом и HTTP-вызова обёрнут в
-- `exception when others` — падение push (нет секрета, недоступна
-- функция, что угодно) НЕ ДОЛЖНО откатывать вставку самого сообщения.
-- Раньше без этой защиты ошибка здесь откатывала всю транзакцию
-- INSERT — из-за этого не отправлялись сообщения в личном чате, хотя
-- на вид проблема была "в push".
create or replace function chat_notify_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  service_key text;
begin
  begin
    select decrypted_secret into service_key
    from vault.decrypted_secrets
    where name = 'service_role_key';

    if service_key is not null then
      perform net.http_post(
        url := 'https://frbptucrvmyikencyspu.supabase.co/functions/v1/send-chat-push',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || service_key
        ),
        body := jsonb_build_object('table', TG_TABLE_NAME, 'record', row_to_json(NEW))
      );
    end if;
  exception when others then
    null;
  end;
  return NEW;
end;
$$;

drop trigger if exists chat_messages_push on chat_messages;
create trigger chat_messages_push
  after insert on chat_messages
  for each row execute function chat_notify_push();

drop trigger if exists chat_global_messages_push on chat_global_messages;
create trigger chat_global_messages_push
  after insert on chat_global_messages
  for each row execute function chat_notify_push();

-- ============================================================
-- Общий чат — лента никем не читается вглубь (решение пользователя),
-- поэтому храним не больше 500 последних сообщений: после каждой
-- вставки лишние (старше 500-го по дате) удаляются. `for each
-- statement`, а не `for each row` — при массовой вставке (например,
-- импорт) чистка запускается один раз, а не по разу на строку.
-- ============================================================

create or replace function chat_global_trim()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from chat_global_messages
  where id in (
    select id from chat_global_messages
    order by created_at desc
    offset 500
  );
  return null;
end;
$$;

drop trigger if exists chat_global_messages_trim on chat_global_messages;
create trigger chat_global_messages_trim
  after insert on chat_global_messages
  for each statement execute function chat_global_trim();

notify pgrst, 'reload schema';
