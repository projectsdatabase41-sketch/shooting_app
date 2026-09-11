-- Есть ли таблица ai_conversation_summaries вообще, и пишется ли в неё
-- что-то. Если запрос ниже падает с ошибкой "relation does not exist" —
-- таблицу ещё не создали (нужно применить sql/schema.sql целиком,
-- он идемпотентный и ничего не сломает при повторном прогоне).
select count(*) as строк, max(created_at) as последняя_запись
from ai_conversation_summaries;

-- Если таблица есть, но строк 0 — проверьте RLS: INSERT должен быть
-- разрешён is_project_owner(). Быстрая проверка политики:
select policyname, cmd, qual, with_check
from pg_policies
where tablename = 'ai_conversation_summaries';
