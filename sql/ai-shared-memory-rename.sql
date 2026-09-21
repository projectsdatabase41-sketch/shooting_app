-- Переименование qwen_ops_memory -> ai_shared_memory ("общая память всех ИИ").
-- Причина: таблицу читает не только Qwen, а имя другого ИИ вводит в
-- заблуждение. Имя теперь говорит, как с ней обращаться: она ОБЩАЯ —
-- писать аккуратно, не затирать чужое, секреты не хранить.
--
-- НЕ ЛОМАЕТ Qwen: под старым именем остаётся простое представление (view)
-- поверх новой таблицы с теми же правами (security_invoker — политики RLS
-- базовой таблицы действуют как раньше). Чтение и обычная вставка через
-- старое имя работают.
--
-- ОДНО, ЧТО НУЖНО ПРОВЕРИТЬ ПОСЛЕ (см. блок проверки внизу): если Qwen пишет
-- через upsert (Prefer: resolution=merge-duplicates / on_conflict), через
-- view это может не сработать — тогда Qwen надо перевести на новое имя.
--
-- ОТКАТ (если что-то пошло не так):
--   drop view if exists qwen_ops_memory;
--   alter table ai_shared_memory rename to qwen_ops_memory;
--   notify pgrst, 'reload schema';
--
-- Идемпотентно: повторный запуск ничего не меняет. Запускать в SQL Editor
-- ЛИЧНОЙ базы ДО sql/table-protection.sql.

do $$
begin
  if to_regclass('public.qwen_ops_memory') is not null
     and to_regclass('public.ai_shared_memory') is null then
    alter table qwen_ops_memory rename to ai_shared_memory;
    create view qwen_ops_memory with (security_invoker = on) as
      select * from ai_shared_memory;
    grant select, insert, update on qwen_ops_memory to anon, authenticated;
  end if;
end $$;

comment on table ai_shared_memory is
  'ОБЩАЯ рабочая память всех ИИ, работающих с этой базой (Qwen, ассистент Puls, помощник в редакторе). Читать перед работой, писать аккуратно, чужие записи не затирать. Читается ролью anon — ЛЮБОЙ СЕКРЕТ ХРАНИТЬ ЗДЕСЬ НЕЛЬЗЯ (пароли, service_role, токены доступа). Только ссылки, публичные ключи и договорённости.';

-- Запись о таблице в table_docs: прежняя (qwen_ops_memory) заменяется.
delete from table_docs where entry_key = 'protect:qwen_ops_memory';

insert into table_docs (entry_key, kind, title, body) values
  ('protect:ai_shared_memory', 'table', 'ai_shared_memory — общая память всех ИИ (бывшая qwen_ops_memory)',
'Общая рабочая память ВСЕХ ИИ, работающих с этой базой. Старое имя qwen_ops_memory
оставлено как view (совместимость) — новым записям использовать ai_shared_memory.
ЧИТАЕТСЯ РОЛЬЮ anon (политика SELECT true) -> СЕКРЕТЫ СЮДА НЕЛЬЗЯ: ни пароли,
ни service_role, ни JWT/токены доступа, ни логин владельца. Допустимо: адрес
проекта, публичный (anon/publishable) ключ, имена таблиц, договорённости и
инструкции «где что лежит». Права: SELECT/INSERT/UPDATE для anon и authenticated,
DELETE не выдан — не выдавать. Не затирать чужие записи: дописывать. Назначение
колонок исходной таблицы уточнить у владельца процесса перед любой правкой
структуры. НЕ удалять и не менять права без записи здесь.')
on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();

notify pgrst, 'reload schema';

-- ПРОВЕРКА 1: новая таблица и view на месте.
select c.relname, c.relkind   -- r = таблица, v = view
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in ('qwen_ops_memory', 'ai_shared_memory');

-- ПРОВЕРКА 2: колонки — пришлите, чтобы я написал первую запись с инструкцией.
-- (Только имена колонок, без содержимого: в строках могут быть секреты.)
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'ai_shared_memory'
order by ordinal_position;

-- ПРОВЕРКА 3: нет ли секретов в уже лежащих строках — только счётчик, не
-- содержимое. Если больше 0: сменить эти секреты (они читались публично).
-- Здесь ищем по всем колонкам-строкам разом.
select count(*) as строк_похожих_на_секрет
from ai_shared_memory t
where t::text ~* '(service_role|eyJhbGci|password|пароль|secret|sk-or-)';
