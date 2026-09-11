-- Проверка: подходят ли колонки таблицы под то, что ищет KnowledgeService
-- (lib/services/knowledge_service.dart). Ассистенту нужны РОВНО эти три
-- колонки: content (текст, по нему ищем), file_name и heading_path
-- (необязательны, просто подпись источника).
--
-- Замените 'ваша_таблица' на имя своей таблицы и выполните в SQL editor
-- Supabase. Пусто/ошибка в result — колонок нет, поиск по этой таблице
-- всегда будет возвращать пусто, даже если строк в ней тысячи.
select column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name = 'ваша_таблица'
order by ordinal_position;

-- Список ВСЕХ таблиц схемы public — если не уверены в точном имени.
select table_name
from information_schema.tables
where table_schema = 'public'
order by table_name;
