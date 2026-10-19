-- Диагностика таблицы notes в ЛИЧНОЙ базе: структура, ограничения, индексы, политики,
-- функции и несколько строк-образцов. Только чтение — ничего не меняет.
-- Выполнить в Supabase → SQL Editor, результат (одна ячейка notes_structure) вставить в чат.
-- Длинные значения (текст заметок, эмбеддинги) обрезаются до 120 символов.
select jsonb_pretty(jsonb_build_object(
  'columns', (
    select jsonb_agg(jsonb_build_object('name', column_name, 'type', data_type, 'udt', udt_name,
                                        'nullable', is_nullable, 'default', column_default) order by ordinal_position)
    from information_schema.columns where table_schema = 'public' and table_name = 'notes'),
  'constraints', (
    select jsonb_agg(jsonb_build_object('name', conname, 'def', pg_get_constraintdef(oid)))
    from pg_constraint where conrelid = 'public.notes'::regclass),
  'indexes', (
    select jsonb_agg(indexdef) from pg_indexes where schemaname = 'public' and tablename = 'notes'),
  'rls_enabled', (select relrowsecurity from pg_class where oid = 'public.notes'::regclass),
  'policies', (
    select jsonb_agg(jsonb_build_object('name', policyname, 'cmd', cmd, 'roles', roles, 'using', qual, 'check', with_check))
    from pg_policies where schemaname = 'public' and tablename = 'notes'),
  'triggers', (
    select jsonb_agg(jsonb_build_object('name', tgname, 'def', pg_get_triggerdef(oid)))
    from pg_trigger where tgrelid = 'public.notes'::regclass and not tgisinternal),
  'functions_mentioning_notes', (
    select jsonb_agg(p.proname)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and pg_get_functiondef(p.oid) ilike '%notes%'),
  'extensions', (select jsonb_agg(extname) from pg_extension),
  'row_count', (select count(*) from public.notes),
  'sample_rows', (
    select jsonb_agg(r) from (
      select (select jsonb_object_agg(key, left(value::text, 120)) from jsonb_each(to_jsonb(t))) as r
      from (select * from public.notes limit 5) t) x)
)) as notes_structure;
