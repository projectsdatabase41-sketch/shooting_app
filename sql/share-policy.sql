-- Политики токена тренера.
--   basic    — только тренировки, результаты и комментарии (всё, что связано с
--              результатами; через get_shared_* из schema.sql). Задания и чат
--              тренера со спортсменом работают по своим функциям (tasks.sql,
--              coach-chat.sql) независимо от политики.
--   extended — basic + таблицы личной базы, которые спортсмен отметил при
--              создании токена (shared_tables). Читаются ТОЛЬКО через
--              get_shared_table, только отмеченные и не из запретного списка.
-- Выполнить один раз в личной базе (SQL Editor).

alter table share_grants add column if not exists policy text not null default 'basic';
alter table share_grants drop constraint if exists share_grants_policy_check;
alter table share_grants add constraint share_grants_policy_check check (policy in ('basic', 'extended'));
alter table share_grants add column if not exists shared_tables text[] not null default '{}';

-- Что разрешено этому токену — тренерское приложение узнаёт отсюда.
create or replace function get_share_policy(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_grant uuid;
  v_row record;
begin
  v_grant := validate_share_token(p_token);
  if v_grant is null then return null; end if;
  select policy, shared_tables into v_row from share_grants where id = v_grant;
  return jsonb_build_object('policy', coalesce(v_row.policy, 'basic'), 'tables', to_jsonb(coalesce(v_row.shared_tables, '{}'::text[])));
end;
$$;

-- Строки одной из разрешённых таблиц (до p_limit, 1..1000). Служебные таблицы
-- с секретами отдавать нельзя, даже если их внесли в список вручную.
create or replace function get_shared_table(p_token text, p_table text, p_limit int default 200)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_grant uuid;
  v_row record;
  v_result jsonb;
  v_limit int := greatest(1, least(coalesce(p_limit, 200), 1000));
  v_blocked text[] := array['share_grants', 'share_events', 'project_settings', 'chat_push_tokens', 'task_devices'];
begin
  v_grant := validate_share_token(p_token);
  if v_grant is null then raise exception 'invalid or revoked token'; end if;
  select policy, shared_tables into v_row from share_grants where id = v_grant;
  if v_row.policy is distinct from 'extended' or not (p_table = any(coalesce(v_row.shared_tables, '{}'::text[]))) then
    raise exception 'table is not shared with this token';
  end if;
  if p_table = any(v_blocked) or to_regclass('public.' || quote_ident(p_table)) is null then
    raise exception 'table is not available';
  end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (select * from public.%I limit %s) t', p_table, v_limit)
    into v_result;
  return v_result;
end;
$$;

grant execute on function get_share_policy(text) to anon, authenticated;
grant execute on function get_shared_table(text, text, int) to anon, authenticated;

notify pgrst, 'reload schema';
