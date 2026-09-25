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
  -- Уведомления из общего чата: 'all' — каждое сообщение, 'replies' —
  -- только ответы на свои сообщения, 'none' — отключены. Личный чат это
  -- не затрагивает (там и так пишут напрямую тебе).
  global_push_mode text not null default 'all',
  -- Уведомления личных чатов: 'all' — как обычно, 'none' — отключены
  -- (без "только ответы" — в личной переписке любое сообщение и так
  -- адресовано лично тебе, отдельного смысла в этом варианте нет).
  personal_push_mode text not null default 'all',
  -- Громкий канал "Позвать" (рингтон устройства + усиленная вибрация,
  -- см. lib/services/push_service.dart) — тренер может отключить его у
  -- себя, тогда вызов приходит обычным тихим уведомлением вместо
  -- звонка поверх всего (см. Edge Function send-chat-push).
  call_alerts_enabled boolean not null default true,
  created_at     timestamptz not null default now()
);

alter table chat_profiles add column if not exists about text not null default '';
alter table chat_profiles drop constraint if exists chat_profiles_about_len;
alter table chat_profiles add constraint chat_profiles_about_len check (char_length(about) <= 120);

alter table chat_profiles add column if not exists global_push_mode text not null default 'all';
alter table chat_profiles drop constraint if exists chat_profiles_global_push_mode_check;
alter table chat_profiles add constraint chat_profiles_global_push_mode_check
  check (global_push_mode in ('all', 'replies', 'none'));

alter table chat_profiles add column if not exists personal_push_mode text not null default 'all';
alter table chat_profiles drop constraint if exists chat_profiles_personal_push_mode_check;
alter table chat_profiles add constraint chat_profiles_personal_push_mode_check
  check (personal_push_mode in ('all', 'none'));

alter table chat_profiles add column if not exists call_alerts_enabled boolean not null default true;

-- Приватность личных чатов: 'everyone' (по умолчанию) — как раньше,
-- первый встречный может просто написать; 'friends_only' — написать
-- может кто угодно, но это ЗАЯВКА (см. chat_friends ниже) — сообщения
-- видны, только когда её примут.
alter table chat_profiles add column if not exists privacy_mode text not null default 'everyone';
alter table chat_profiles drop constraint if exists chat_profiles_privacy_mode_check;
alter table chat_profiles add constraint chat_profiles_privacy_mode_check
  check (privacy_mode in ('everyone', 'friends_only'));

-- Заявки/друзья — переживают переустановку и смену телефона (в отличие
-- от chat_contacts, который живёт только на устройстве): при входе с
-- нового устройства список принятых заявок подтягивается заново в
-- локальный список контактов (см. ChatAuthService.listFriends).
create table if not exists chat_friends (
  requester_id  uuid not null references auth.users(id) on delete cascade,
  addressee_id  uuid not null references auth.users(id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at    timestamptz not null default now(),
  primary key (requester_id, addressee_id)
);

alter table chat_friends enable row level security;

-- Видно обеим сторонам — и кто отправил, и кому адресовано.
drop policy if exists chat_friends_select on chat_friends;
create policy chat_friends_select on chat_friends
  for select
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- Заявку создаёт только сам отправитель, от своего имени (см.
-- ChatAuthService.ensureFriendRequest — вызывается при отправке
-- сообщения новому собеседнику).
drop policy if exists chat_friends_insert on chat_friends;
create policy chat_friends_insert on chat_friends
  for insert
  with check (requester_id = auth.uid());

-- Принять заявку может только адресат (перевод в 'accepted').
drop policy if exists chat_friends_update on chat_friends;
create policy chat_friends_update on chat_friends
  for update
  using (addressee_id = auth.uid())
  with check (addressee_id = auth.uid());

-- Отклонить/удалить из друзей может любая из сторон.
drop policy if exists chat_friends_delete on chat_friends;
create policy chat_friends_delete on chat_friends
  for delete
  using (requester_id = auth.uid() or addressee_id = auth.uid());

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
  -- (см. ниже), а не новые сообщения сами по себе; 'call' — "позвать"
  -- (кнопка в ChatThreadScreen) — без текста и вложения, только сигнал
  -- для push с усиленным звуком/вибрацией (см. Edge Function);
  -- 'call_ack'/'call_cancel' — служебные сигналы к уже отправленному
  -- 'call' (тот же принцип, что у edit/delete): тренер жмёт "Иду" →
  -- 'call_ack' спортсмену, спортсмен передумал → 'call_cancel' тренеру.
  msg_type               text not null default 'text'
                           check (msg_type in ('text','image','video','audio','file','edit','delete','call','call_ack','call_cancel')),
  attachment_path        text,   -- путь объекта в бакете chat-media
  -- Большие вложения (свыше лимита бакета, см. ChatMediaUtils.maxAttachmentBytes)
  -- идут не через Storage, а через отдельный Google Drive (см.
  -- ChatDriveService/google-apps-script/chat-drive-relay.gs) — тогда
  -- attachment_path пуст, а здесь id файла на Диске. Само тело файла
  -- через эту таблицу и через Storage не проходит ни в том, ни в другом
  -- случае — тут только метаданные.
  drive_file_id          text,
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
  ack_of_client_message_id    text,
  cancel_of_client_message_id text,
  reply_to_client_message_id  text,
  reply_to_preview             text,
  created_at             timestamptz not null default now(),
  unique (sender_id, client_message_id),
  -- Сообщение — ОДНО из: текст, вложение (+ опц. подпись), edit-сигнал
  -- (текст + ссылка на оригинал) или delete-сигнал (только ссылка на
  -- оригинал, без текста/вложения).
  check (
    (msg_type = 'text' and text is not null and attachment_path is null and drive_file_id is null)
    or (msg_type in ('image','video','audio','file') and (attachment_path is not null or drive_file_id is not null))
    or (msg_type = 'edit' and edit_of_client_message_id is not null and text is not null)
    or (msg_type = 'delete' and delete_of_client_message_id is not null)
    or (msg_type = 'call')
    or (msg_type = 'call_ack' and ack_of_client_message_id is not null)
    or (msg_type = 'call_cancel' and cancel_of_client_message_id is not null)
  )
);

-- Столбцы вложений добавляются и на уже существующую (по прежней
-- версии этого файла) таблицу chat_messages.
alter table chat_messages alter column text drop not null;
alter table chat_messages add column if not exists msg_type text not null default 'text';
alter table chat_messages add column if not exists attachment_path text;
alter table chat_messages add column if not exists drive_file_id text;
alter table chat_messages add column if not exists attachment_name text;
alter table chat_messages add column if not exists attachment_mime text;
alter table chat_messages add column if not exists attachment_size bigint;
alter table chat_messages add column if not exists attachment_duration_ms integer;
alter table chat_messages add column if not exists attachment_width integer;
alter table chat_messages add column if not exists attachment_height integer;
alter table chat_messages add column if not exists edit_of_client_message_id text;
alter table chat_messages add column if not exists delete_of_client_message_id text;
alter table chat_messages add column if not exists ack_of_client_message_id text;
alter table chat_messages add column if not exists cancel_of_client_message_id text;
alter table chat_messages add column if not exists reply_to_client_message_id text;
alter table chat_messages add column if not exists reply_to_preview text;
-- Разрешил ли отправитель скачивание вложения (настройка ОТПРАВИТЕЛЯ,
-- ChatPreferences.photoDownloadMode) — приезжает вместе с сообщением,
-- получатель уже не спрашивает профиль отправителя отдельно.
alter table chat_messages add column if not exists download_allowed boolean not null default true;

-- CHECK не подвинуть ни ADD COLUMN, ни повторным CREATE TABLE — только
-- пересозданием ограничения. Оба варианта имени учтены (авто-имя из
-- первой версии этого файла и явное новое), поэтому блок безопасно
-- накатывать многократно.
alter table chat_messages drop constraint if exists chat_messages_msg_type_check;
alter table chat_messages add constraint chat_messages_msg_type_check
  check (msg_type in ('text','image','video','audio','file','edit','delete','call','call_ack','call_cancel','read'));

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
    -- «прочитано»: text — JSON-список client_message_id прочитанных сообщений
    or (msg_type = 'read' and text is not null)
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
drop function if exists resolve_chat_code(text);
create or replace function resolve_chat_code(p_code text)
returns table(user_id uuid, nickname text, avatar_base64 text, about text)
language sql
security definer
set search_path = public
as $$
  select user_id, nickname, avatar_base64, about
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
  text        text,
  -- Вложения — тот же бакет chat-media, что и в личном чате, но путь с
  -- префиксом "global/" (см. политики ниже) и БЕЗ удаления после
  -- просмотра: лента общая и постоянная, а не транзит на доставку.
  attachment_path   text,
  attachment_name   text,
  attachment_mime    text,
  attachment_size   bigint,
  -- Ответ на сообщение — только id + готовая цитата, без FK: исходное
  -- сообщение может быть уже удалено триггером обрезки (500 штук).
  reply_to_id       uuid,
  reply_to_preview  text,
  created_at  timestamptz not null default now(),
  check (text is not null or attachment_path is not null)
);

alter table chat_global_messages alter column text drop not null;
alter table chat_global_messages add column if not exists attachment_path text;
alter table chat_global_messages add column if not exists attachment_name text;
alter table chat_global_messages add column if not exists attachment_mime text;
alter table chat_global_messages add column if not exists attachment_size bigint;
alter table chat_global_messages add column if not exists reply_to_id uuid;
alter table chat_global_messages add column if not exists reply_to_preview text;
alter table chat_global_messages add column if not exists download_allowed boolean not null default true;
-- График в сообщении (кнопка "AI" — решение пользователя: тот же
-- ```chart JSON, что и в чате с ассистентом, "универсальный язык"
-- вместо отдельного формата для чата) — тот же формат, что у
-- coach_notes.chart_json.
alter table chat_global_messages add column if not exists chart_json text;

alter table chat_global_messages drop constraint if exists chat_global_messages_check;
alter table chat_global_messages add constraint chat_global_messages_check
  check (text is not null or attachment_path is not null or chart_json is not null);

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

-- Удалить можно только своё собственное сообщение (меню долгого
-- нажатия в общем чате).
drop policy if exists chat_global_delete on chat_global_messages;
create policy chat_global_delete on chat_global_messages
  for delete
  to authenticated
  using (sender_id = auth.uid());

-- Вложения общего чата — тот же бакет chat-media, путь
-- "global/<sender_id>/<...>" (отличает их от личных, которые лежат
-- прямо в "<sender_id>/..."). Смотреть может любой вошедший (лента
-- открыта всем), загружать/удалять — только в свою папку/своё.
--
-- ponytail: удаление объекта при чистке ленты (500-cap триггер,
-- chat_global_trim) не реализовано — при обрезке старых сообщений
-- с фото файл в Storage остаётся сиротой. Для MVP не критично (это
-- расход места, не дыра в безопасности); чистить — периодической
-- задачей, если объём вложений станет заметным.
drop policy if exists chat_global_media_insert on storage.objects;
create policy chat_global_media_insert on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = 'global'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists chat_global_media_select on storage.objects;
create policy chat_global_media_select on storage.objects
  for select
  to authenticated
  using (bucket_id = 'chat-media' and (storage.foldername(name))[1] = 'global');

drop policy if exists chat_global_media_delete on storage.objects;
create policy chat_global_media_delete on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = 'global'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

-- Профиль по списку id — для отображения ников/аватаров в ленте общего
-- чата и в списке "Участники" (не отдаёт chat_code — им по-прежнему
-- находят собеседника только для ЛИЧНОГО чата, а не через общий поток).
drop function if exists resolve_profiles(uuid[]);
create or replace function resolve_profiles(p_ids uuid[])
returns table(user_id uuid, nickname text, avatar_base64 text, about text)
language sql
security definer
set search_path = public
as $$
  select user_id, nickname, avatar_base64, about
  from chat_profiles
  where user_id = any(p_ids);
$$;

-- Удаление СВОЕГО ЖЕ чат-аккаунта целиком (настройка "Удалить аккаунт",
-- см. ChatSettingsScreen) — удаляет саму строку auth.users, всё
-- остальное (chat_profiles/chat_friends/chat_push_tokens/сообщения)
-- уходит каскадом по внешним ключам "on delete cascade", отдельно
-- чистить не нужно. SECURITY DEFINER — обычный пользователь не может
-- писать в auth.users напрямую, функция выполняется от имени её
-- владельца (postgres), но только для auth.uid() самого вызывающего.
-- Файлы вложений в Storage при этом НЕ удаляются (см. пункт "orphaned
-- storage" в комментариях ниже по файлу) — расход места, не дыра в
-- безопасности, можно почистить отдельно при необходимости.
create or replace function delete_own_chat_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from auth.users where id = auth.uid();
end;
$$;

grant execute on function delete_own_chat_account() to authenticated;

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
  push_secret text;
  gid uuid;
begin
  begin
    -- Сообщение группы лежит строкой на каждого участника, но push нужен
    -- один вызов на сообщение: функция сама разошлёт всем. Вызываем только
    -- для строки «первого» получателя. to_jsonb — чтобы не падать, пока
    -- колонки group_id ещё нет (sql/chat-groups.sql не выполнен).
    -- Служебные сигналы без уведомления (правка, «прочитано») — функцию не
    -- вызываем вовсе, экономим квоту. Удаление — вызываем: функция уберёт
    -- показанное уведомление с текстом удалённого сообщения.
    if NEW.msg_type in ('edit', 'read') then
      return NEW;
    end if;
    gid := (to_jsonb(NEW) ->> 'group_id')::uuid;
    if gid is not null and NEW.recipient_id <> (
      select user_id from chat_group_members
      where group_id = gid and user_id <> NEW.sender_id
      order by user_id limit 1
    ) then
      return NEW;
    end if;

    -- Вызов подписан общим секретом (vault 'push_secret' = секрет функции
    -- PUSH_SECRET), а не ключом service_role: его не нужно никуда копировать.
    select decrypted_secret into push_secret
    from vault.decrypted_secrets
    where name = 'push_secret';

    if push_secret is not null then
      perform net.http_post(
        url := 'https://yirvomezybprdlntxyas.supabase.co/functions/v1/send-chat-push',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-push-secret', push_secret
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

-- ============================================================
-- Живой канал личного чата (Supabase Realtime, приватные каналы).
--
-- Канал диалога называется `dm:<id1>:<id2>` (id по возрастанию), войти
-- и писать в него может только один из двух участников — иначе любой
-- залогиненный мог бы подслушать чужой диалог, угадав имя канала.
-- Включается на клиенте удалённо (config/chat-config.json, realtime.enabled).
-- ============================================================
drop policy if exists dm_realtime_read on realtime.messages;
create policy dm_realtime_read on realtime.messages
  for select to authenticated
  using (
    realtime.topic() like 'dm:%'
    and auth.uid()::text = any (string_to_array(substr(realtime.topic(), 4), ':'))
  );

drop policy if exists dm_realtime_write on realtime.messages;
create policy dm_realtime_write on realtime.messages
  for insert to authenticated
  with check (
    realtime.topic() like 'dm:%'
    and auth.uid()::text = any (string_to_array(substr(realtime.topic(), 4), ':'))
  );
