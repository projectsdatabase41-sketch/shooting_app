-- Закрыть таблицу notes от анонимного доступа (аудит 26.11).
--
-- Что не так: файл sql/qwen-tables-access.sql открывает notes, qwen_ops_memory
-- и search_log роли anon политиками «using (true)». Если он был выполнен в
-- личной базе, любой, у кого есть anon-ключ этой базы, читает все заметки.
--
-- Этот скрипт снимает такие политики и оставляет доступ только владельцу
-- проекта (политики *_owner_all из установочного SQL) и роли service_role,
-- которую приложение не использует.
--
-- Выполнять в базе, где есть таблица notes. Повторный запуск безопасен.

do $$
declare
  t text;
begin
  foreach t in array array['notes', 'qwen_ops_memory', 'search_log'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop policy if exists %I on %I', t || '_read', t);
      execute format('drop policy if exists %I on %I', t || '_insert', t);
      execute format('drop policy if exists %I on %I', t || '_update', t);
      execute format('drop policy if exists %I on %I', t || '_owner_all', t);
      execute format(
        'create policy %I on %I for all to authenticated using (is_project_owner()) with check (is_project_owner())',
        t || '_owner_all', t);
      -- И снять сами права anon: без политик RLS уже не пустит, но так честнее.
      execute format('revoke all on table %I from anon', t);
    end if;
  end loop;
end $$;

-- Проверка: у notes не должно остаться политик для anon.
select schemaname, tablename, policyname, roles
from pg_policies
where schemaname = 'public' and tablename in ('notes','qwen_ops_memory','search_log')
order by tablename, policyname;
