-- Отчёт о защите таблиц — чтобы через полгода никто (ни человек, ни ИИ)
-- не "почистил" права или данные как якобы ненужные.
--
-- Два слоя:
--  1) table_docs (уже есть, см. sql/table-docs.sql): человеческое
--     "зачем таблица и что сломается, если тронуть" — записи rule:protection
--     и protect:<таблица>. Идемпотентно: повторный прогон обновляет тексты.
--  2) view table_protection: ЖИВОЕ состояние из системного каталога
--     (RLS включён? какие политики?) + пометка, есть ли описание в
--     table_docs. Не устаревает, потому что ничего не хранит — смотреть
--     всегда: select * from table_protection;  Нет описания = проверить.
--
-- Автоматической защиты от DROP это не даёт (нужен event trigger, а в
-- Supabase на него обычно нет прав) — это память и сигнал, не замок.

insert into table_docs (entry_key, kind, title, body) values
  ('rule:protection', 'rule', 'Защита таблиц — читать перед любой правкой прав или удалением',
'1. НЕ удалять таблицы, колонки, строки и НЕ менять политики RLS/права (grant/revoke)
   "потому что похоже на ненужное". Сначала select * from table_protection и
   запись protect:<таблица> в table_docs.
2. Таблицы приложения (тренировки, выстрелы, комментарии и т.д.): доступ только
   владельцу через is_project_owner(). Ослаблять нельзя — там личные данные.
3. Таблицы, созданные другим ИИ (notes, qwen_ops_memory, search_log): открыты
   на чтение/вставку/правку и для anon — это осознанный выбор их автора,
   приложение Puls читает notes. Не закрывать без согласования: сломается их
   рабочий процесс. DELETE там намеренно НЕ выдан — не добавлять.
4. Схема меняется только через sql/schema.sql (см. rule:schema-changes).
5. Изменили защиту — обновите protect:<таблица> и эту запись в том же коммите.'),

  ('protect:notes', 'table', 'notes — база знаний (создана другим ИИ)',
'Структурированные заметки: topic, summary, content (часто пуст — текст в summary),
tags (jsonb-массив), source (airtable и др.), status, version/supersedes
(версионность), confidence, metadata, embedding (openai/text-embedding-3-large),
content_tsv/search_vector (полнотекстовый поиск). ~240 строк, импорт из Airtable.
Защита: RLS включён, политики notes_read (SELECT), notes_insert (INSERT),
notes_update (UPDATE) для anon и authenticated. DELETE нет — намеренно.
Приложение Puls читает эту таблицу для ассистента (ищет по topic/summary/content,
колонки embedding/tsv НЕ тянет). НЕ удалять, НЕ переименовывать колонки,
НЕ закрывать чтение: сломается и ассистент Puls, и процесс-владелец.
Векторы заполняет процесс владельца — записи, добавленные приложением,
получают embedding позже (embedding_created_at null до этого).'),

  ('protect:qwen_ops_memory', 'table', 'qwen_ops_memory — рабочая память другого ИИ',
'Создана и используется ИИ Qwen (назначение колонок здесь не подтверждено —
уточнить у владельца процесса перед любой правкой). Политики: SELECT/INSERT/UPDATE
для anon и authenticated, DELETE не выдан. Приложение Puls её не использует.
НЕ удалять и НЕ менять права: это состояние чужого рабочего процесса.'),

  ('protect:search_log', 'table', 'search_log — журнал поиска другого ИИ',
'Создана процессом Qwen (назначение колонок не подтверждено). Политики:
search_log_read (SELECT), search_log_insert (INSERT) для anon и authenticated.
Приложение Puls не использует. НЕ чистить и НЕ менять права без согласования.'),

  ('protect:ai_conversation_summaries', 'table', 'ai_conversation_summaries — память ассистента Puls',
'Одна строка = один обмен вопрос-ответ (краткая выдержка, не полный текст).
Пишет и читает приложение (AiMemoryService), хранится не более 1000 строк —
лишние приложение стирает само. Защита: RLS + политика owner через
is_project_owner(). Удаление всей таблицы = ассистент забывает прошлые
разговоры. Единственная допустимая чистка — та, что делает приложение.'),

  ('protect:table_docs', 'table', 'table_docs — эта самая инструкция',
'Пишет только владелец (owner table_docs), читать может любой (read table_docs).
Это память проекта о защите и смысле таблиц. НЕ удалять и не "упрощать":
по ней следующий ИИ узнаёт, что трогать нельзя.')
on conflict (entry_key) do update
  set kind = excluded.kind, title = excluded.title, body = excluded.body, updated_at = now();

-- ЖИВОЙ отчёт. security_invoker — права смотрящего, не создателя.
create or replace view table_protection with (security_invoker = on) as
select c.relname                                   as table_name,
       c.relrowsecurity                            as rls_enabled,
       coalesce((
         select string_agg(p.policyname || ' [' || p.cmd || ' → ' || array_to_string(p.roles, ',') || ']',
                           '; ' order by p.policyname)
         from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
       ), '— нет политик —')                       as policies,
       exists (
         select 1 from table_docs d
         where d.entry_key = c.relname or d.entry_key = 'protect:' || c.relname
       )                                           as documented
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;

-- Отчёт не должен светить политики анониму.
revoke all on table_protection from anon;
grant select on table_protection to authenticated;

-- Проверка: таблицы без описания (кандидаты на внимание).
select table_name, rls_enabled, policies from table_protection where not documented;
