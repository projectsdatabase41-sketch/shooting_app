-- Служебный аккаунт "импортёр" для стороннего ИИ (Qwen): может ДОБАВЛЯТЬ и
-- ЧИТАТЬ тренировки, но не удалять, не менять чужое и не трогать настройки,
-- токены доступа тренера и файлы. Пароль владельца ИИ не нужен.
--
-- ШАГ 1 (руками, в браузере): Supabase Dashboard -> Authentication -> Users ->
--   Add user -> Create new user. Почта любая (например importer@puls.local),
--   пароль длинный случайный, галочка "Auto Confirm User" включена.
--   Пароль сохранить ТОЛЬКО у Qwen (его секреты). В базу/таблицы/чат не класть.
-- ШАГ 2: в строке ниже поставить эту же почту и выполнить весь файл в SQL Editor.
--
-- Идемпотентно: повторный запуск безопасен.

create table if not exists importer_users (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table importer_users enable row level security;  -- политик нет: напрямую не читается

insert into importer_users (user_id)
select id from auth.users where email = 'importer@puls.local'   -- <-- ВАША ПОЧТА ИМПОРТЁРА
on conflict do nothing;

-- security definer: функция сама читает importer_users, вызывающему таблица не видна.
create or replace function is_importer()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from importer_users where user_id = auth.uid());
$$;
grant execute on function is_importer() to authenticated;

-- Права: ВСТАВКА и ЧТЕНИЕ (чтобы найти шаблон упражнения и сверить записанное).
-- Ни update, ни delete — намеренно.
do $$
declare t text;
begin
  foreach t in array array['training_packages','exercises','exercise_templates','shots','comments']
  loop
    execute format('drop policy if exists "importer insert %1$s" on %1$I', t);
    execute format('create policy "importer insert %1$s" on %1$I for insert to authenticated with check (is_importer())', t);
    execute format('drop policy if exists "importer read %1$s" on %1$I', t);
    execute format('create policy "importer read %1$s" on %1$I for select to authenticated using (is_importer())', t);
  end loop;
end $$;

insert into table_docs (entry_key, kind, title, body) values
  ('rule:import-account', 'rule', 'Аккаунт импортёра — как войти и что можно',
'Импорт тренировок делается под служебным пользователем-импортёром, НЕ под владельцем.
Вход: POST <адрес проекта>/auth/v1/token?grant_type=password, заголовок apikey =
публичный ключ, тело {"email":..., "password":...}; в ответе access_token, дальше
Authorization: Bearer <access_token>. Пароль импортёра лежит у того, кто импортирует,
и НЕ хранится в базе. Права: INSERT и SELECT на training_packages, exercises,
exercise_templates, shots, comments. НЕТ: update, delete, project_settings,
share_grants, file_assets и всего остального. Токен живёт ~час — при 401 войти заново.
Исправить неверно записанное импортёр не может — сообщить владельцу.')
on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();

-- Проверка: должен быть 1 импортёр.
select u.email, i.user_id from importer_users i join auth.users u on u.id = i.user_id;
