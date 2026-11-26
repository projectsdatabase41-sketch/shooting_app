-- Пробуждение проекта Supabase из воркера (26.11).
--
-- Зачем: на бесплатном плане Supabase усыпляет проект после 7 дней без
-- активности. У нас cron воркера звонков ходит дважды в день и дёргает эту
-- функцию — проект остаётся активным без отдельного GitHub-workflow.
--
-- Почему RPC, а не SELECT из таблицы: функция не отдаёт никаких данных,
-- только текущее время. anon-ключ остаётся публичным, service_role не нужен.
--
-- Выполнить один раз в SQL Editor проекта, который нужно держать активным
-- (общий проект чата/финалов). Повторный запуск безопасен.

create or replace function keepalive()
returns timestamptz
language sql
security definer
set search_path = public
as $$ select now() $$;

-- Функцию можно звать обычным anon-ключом.
grant execute on function keepalive() to anon, authenticated;

-- Проверка: должно вернуть текущее время.
-- select keepalive();
