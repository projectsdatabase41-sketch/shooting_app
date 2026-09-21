-- Убирает из ai_shared_memory ключи OpenRouter (sk-or-...) и секретные ключи
-- Supabase нового формата (sb_secret_...) — таблица читается ролью anon,
-- держать их там нельзя. Сами ключи остаются в секретах GitHub.
--
-- Универсально: не зависит от списка колонок — перебирает текстовые/json
-- колонки таблицы (обычные, не вычисляемые) и заменяет найденное пометкой.
-- НЕ трогает JWT (eyJ...): среди них может быть публичный anon-ключ, который
-- как раз можно и нужно хранить. Строку со словом service_role проверьте
-- отдельно (см. запрос в чате) — этот скрипт её не лечит.
--
-- Идемпотентно. Запускать в SQL Editor ЛИЧНОЙ базы.

-- ШАГ 1: что будет затронуто (значения не показываются).
select count(*) as строк_с_ключами
from ai_shared_memory t
where t::text ~ '(sk-or-[A-Za-z0-9_-]{10,}|sb_secret_[A-Za-z0-9_-]{10,})';

-- ШАГ 2: замена.
do $$
declare
  r    record;
  pat  constant text := '(sk-or-[A-Za-z0-9_-]{10,}|sb_secret_[A-Za-z0-9_-]{10,})';
  repl constant text := '[ключ убран — хранится в секретах, не в этой таблице]';
begin
  for r in
    select column_name, data_type
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'ai_shared_memory'
      and data_type in ('text', 'character varying', 'jsonb')
      and is_generated = 'NEVER'
  loop
    if r.data_type = 'jsonb' then
      execute format(
        'update ai_shared_memory set %1$I = regexp_replace(%1$I::text, %2$L, %3$L, ''g'')::jsonb where %1$I::text ~ %2$L',
        r.column_name, pat, repl);
    else
      execute format(
        'update ai_shared_memory set %1$I = regexp_replace(%1$I, %2$L, %3$L, ''g'') where %1$I ~ %2$L',
        r.column_name, pat, repl);
    end if;
  end loop;
end $$;

-- ШАГ 3: должно вернуть 0.
select count(*) as осталось_строк_с_ключами
from ai_shared_memory t
where t::text ~ '(sk-or-[A-Za-z0-9_-]{10,}|sb_secret_[A-Za-z0-9_-]{10,})';
