-- Аудит личной базы Supabase: какие таблицы есть, какие права и политики
-- на них, и работает ли память ассистента. ТОЛЬКО ЧТЕНИЕ (кроме блока 6,
-- он необязательный и идемпотентный). Запускайте блоки по одному в SQL
-- Editor и присылайте результаты 1, 3 и 4.

-- 1. Все таблицы схемы public: включена ли защита строк (RLS) и сколько строк.
select c.relname as таблица,
       c.relrowsecurity as rls_включён,
       c.reltuples::bigint as строк_примерно
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;

-- 2. Колонки таблицы памяти ассистента (что именно хранится).
select column_name as колонка, data_type as тип, is_nullable as может_быть_пустой
from information_schema.columns
where table_schema = 'public' and table_name = 'ai_conversation_summaries'
order by ordinal_position;

-- 3. Политики: кто и какие операции (select/insert/update/delete) может делать.
--    Это главный ответ на "какие допуски нужны для редактирования".
select tablename as таблица, policyname as политика, cmd as операция,
       roles as роли, qual as условие_чтения, with_check as условие_записи
from pg_policies
where schemaname = 'public'
order by tablename, policyname;

-- 4. Права ролей на таблицы (anon = ключ без входа, authenticated = после входа).
select table_name as таблица, grantee as роль,
       string_agg(privilege_type, ', ' order by privilege_type) as права
from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon', 'authenticated')
group by table_name, grantee
order by table_name, grantee;

-- 5. Есть ли функция is_project_owner() (на ней держатся политики
--    schema.sql) и пишется ли память ассистента.
select exists (select 1 from pg_proc where proname = 'is_project_owner') as есть_is_project_owner;

select count(*) as сводок, max(created_at) as последняя
from ai_conversation_summaries;

select created_at, left(summary, 120) as начало_сводки
from ai_conversation_summaries
order by created_at desc
limit 10;

-- 6. НЕОБЯЗАТЕЛЬНО: создать таблицу памяти, если её нет (иначе примените
--    sql/schema.sql целиком, он идемпотентный). Политика — только для
--    вошедшего пользователя, если is_project_owner() нет.
create table if not exists ai_conversation_summaries (
  id                    uuid primary key default gen_random_uuid(),
  period_start          timestamptz not null,
  period_end            timestamptz not null,
  summary               text not null,
  training_package_ids  uuid[] not null default '{}',
  shot_refs             jsonb,
  extra                 jsonb,
  created_at            timestamptz not null default now()
);
create index if not exists idx_ai_summaries_period on ai_conversation_summaries(period_start desc);
alter table ai_conversation_summaries enable row level security;

do $$
begin
  drop policy if exists "owner ai_conversation_summaries" on ai_conversation_summaries;
  if exists (select 1 from pg_proc where proname = 'is_project_owner') then
    create policy "owner ai_conversation_summaries" on ai_conversation_summaries
      for all using (is_project_owner()) with check (is_project_owner());
  else
    create policy "owner ai_conversation_summaries" on ai_conversation_summaries
      for all to authenticated using (true) with check (true);
  end if;
end $$;
