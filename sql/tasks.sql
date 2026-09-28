-- Задания тренера спортсмену. Живут в ЛИЧНОЙ базе спортсмена; тренер пишет
-- и читает по своему токену (share_grants) функциями ниже, спортсмен —
-- напрямую как владелец. Сырые данные — дословно; ИИ пишет только в
-- task_reports. Повторный запуск безопасен.
--
-- План: tasks → task_stages (ступени, строго по очереди) → task_steps.
-- Режим ступени: single | together (одна страница) | any_order (все, порядок
-- свой) | pick_one (один на выбор).
-- Прохождение: task_runs → task_run_steps → task_shots / task_series_notes,
-- отклонения — task_events, отчёты ИИ — task_reports.

create table if not exists tasks (
  id           uuid primary key default gen_random_uuid(),
  grant_id     uuid references share_grants(id) on delete set null,
  group_key    uuid,                         -- одно задание у нескольких спортсменов
  title        text not null,
  coach_text   text not null default '',     -- исходный текст тренера целиком
  due_at       timestamptz,
  repeat_rule  text,                         -- 'daily' | 'mon,wed,fri' | null
  copied_from  uuid references tasks(id) on delete set null,
  status       text not null default 'active' check (status in ('active', 'removed', 'archived')),
  removed_at   timestamptz,
  created_at   timestamptz not null default now()
);

create table if not exists task_stages (
  id        uuid primary key default gen_random_uuid(),
  task_id   uuid not null references tasks(id) on delete cascade,
  position  int not null,
  mode      text not null default 'single' check (mode in ('single', 'together', 'any_order', 'pick_one'))
);

create table if not exists task_steps (
  id              uuid primary key default gen_random_uuid(),
  stage_id        uuid not null references task_stages(id) on delete cascade,
  position        int not null,
  title           text not null,
  instructions    text not null default '',  -- полный текст тренера к этапу
  exercise        jsonb,                     -- мишень, выстрелы, серии, изготовка
  time_limit_sec  int,
  sighting        jsonb,                     -- пристрелка: нужна / сколько / время
  note_mode       text not null default 'step' check (note_mode in ('shot', 'series', 'step', 'none')),
  keep_stats      boolean not null default false
);

create table if not exists task_clarifications (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references tasks(id) on delete cascade,
  question    text not null,
  answer      text not null default '',
  created_at  timestamptz not null default now()
);

create table if not exists task_runs (
  id           uuid primary key default gen_random_uuid(),
  task_id      uuid not null references tasks(id) on delete cascade,
  started_at   timestamptz,
  finished_at  timestamptz,
  status       text not null default 'done' check (status in ('in_progress', 'done', 'abandoned')),
  final_note   text not null default ''
);

create table if not exists task_run_steps (
  id           uuid primary key default gen_random_uuid(),
  run_id       uuid not null references task_runs(id) on delete cascade,
  step_id      uuid references task_steps(id) on delete set null,
  order_done   int,
  started_at   timestamptz,
  finished_at  timestamptz,
  report       text not null default ''
);

create table if not exists task_shots (
  id           uuid primary key default gen_random_uuid(),
  run_step_id  uuid not null references task_run_steps(id) on delete cascade,
  shot_no      int not null,
  series_no    int not null default 1,
  x_mm         double precision not null,
  y_mm         double precision not null,
  score        double precision not null,
  shot_at      timestamptz,
  sighting     boolean not null default false,
  note         text not null default ''
);

create table if not exists task_series_notes (
  id           uuid primary key default gen_random_uuid(),
  run_step_id  uuid not null references task_run_steps(id) on delete cascade,
  series_no    int not null,
  note         text not null
);

create table if not exists task_events (
  id           uuid primary key default gen_random_uuid(),
  run_id       uuid not null references task_runs(id) on delete cascade,
  run_step_id  uuid references task_run_steps(id) on delete cascade,
  type         text not null,                -- time_over | extra_shots | no_sighting | skipped …
  details      jsonb,
  created_at   timestamptz not null default now()
);

create table if not exists task_reports (
  id          uuid primary key default gen_random_uuid(),
  run_id      uuid not null references task_runs(id) on delete cascade,
  kind        text not null check (kind in ('structured', 'visual')),
  content     text not null,
  model       text,
  request     text,
  created_at  timestamptz not null default now()
);

-- Устройства спортсмена для push заданий (адрес FCM).
create table if not exists task_devices (
  token       text primary key,
  updated_at  timestamptz not null default now()
);

-- Устройство тренера для push «задание выполнено» — на его токене доступа.
alter table share_grants add column if not exists coach_fcm_token text;

create index if not exists idx_task_stages_task on task_stages(task_id, position);
create index if not exists idx_task_steps_stage on task_steps(stage_id, position);
create index if not exists idx_task_runs_task on task_runs(task_id);
create index if not exists idx_task_run_steps_run on task_run_steps(run_id);
create index if not exists idx_task_shots_step on task_shots(run_step_id);

do $$
declare t text;
begin
  foreach t in array array['tasks','task_stages','task_steps','task_clarifications','task_runs','task_run_steps',
                           'task_shots','task_series_notes','task_events','task_reports','task_devices'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "owner %s" on %I', t, t);
    execute format('create policy "owner %s" on %I for all using (is_project_owner()) with check (is_project_owner())', t, t);
  end loop;
end $$;

-- ---------- Тренер (по токену) ----------

-- Задание целиком одним JSON: {title, coach_text, due_at, repeat_rule, group_key,
-- copied_from, stages:[{mode, steps:[{title, instructions, exercise, time_limit_sec,
-- sighting, note_mode, keep_stats}]}], clarifications:[{question, answer}]}.
create or replace function coach_create_task(p_token text, p_task jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_grant uuid;
  v_task uuid;
  v_stage uuid;
  s jsonb;
  st jsonb;
  c jsonb;
  i int := 0;
  j int;
begin
  v_grant := validate_share_token(p_token);
  if v_grant is null then raise exception 'invalid or revoked token'; end if;
  insert into tasks (grant_id, group_key, title, coach_text, due_at, repeat_rule, copied_from)
  values (v_grant, nullif(p_task->>'group_key', '')::uuid, coalesce(p_task->>'title', 'Задание'),
          coalesce(p_task->>'coach_text', ''), nullif(p_task->>'due_at', '')::timestamptz,
          nullif(p_task->>'repeat_rule', ''), nullif(p_task->>'copied_from', '')::uuid)
  returning id into v_task;
  for s in select * from jsonb_array_elements(coalesce(p_task->'stages', '[]'::jsonb)) loop
    insert into task_stages (task_id, position, mode) values (v_task, i, coalesce(s->>'mode', 'single'))
    returning id into v_stage;
    j := 0;
    for st in select * from jsonb_array_elements(coalesce(s->'steps', '[]'::jsonb)) loop
      insert into task_steps (stage_id, position, title, instructions, exercise, time_limit_sec, sighting, note_mode, keep_stats)
      values (v_stage, j, coalesce(st->>'title', ''), coalesce(st->>'instructions', ''), st->'exercise',
              nullif(st->>'time_limit_sec', '')::int, st->'sighting', coalesce(st->>'note_mode', 'step'),
              coalesce((st->>'keep_stats')::boolean, false));
      j := j + 1;
    end loop;
    i := i + 1;
  end loop;
  for c in select * from jsonb_array_elements(coalesce(p_task->'clarifications', '[]'::jsonb)) loop
    insert into task_clarifications (task_id, question, answer)
    values (v_task, coalesce(c->>'question', ''), coalesce(c->>'answer', ''));
  end loop;
  return v_task;
end;
$$;

-- Снять задание (removed) или вернуть (active) — только своё.
create or replace function coach_set_task_status(p_token text, p_task_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_grant uuid;
begin
  v_grant := validate_share_token(p_token);
  if v_grant is null then raise exception 'invalid or revoked token'; end if;
  if p_status not in ('active', 'removed') then raise exception 'bad status'; end if;
  update tasks set status = p_status, removed_at = case when p_status = 'removed' then now() end
  where id = p_task_id and grant_id = v_grant;
end;
$$;

-- Задание со всем содержимым: план, прохождения с выстрелами, отметками,
-- отклонениями и отчётами. Без p_task_id — список своих заданий (кратко).
create or replace function coach_get_tasks(p_token text, p_task_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_grant uuid;
begin
  v_grant := validate_share_token(p_token);
  if v_grant is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'task', to_jsonb(t),
      'stages', (select coalesce(jsonb_agg(to_jsonb(sg) || jsonb_build_object('steps',
                   (select coalesce(jsonb_agg(to_jsonb(sp) order by sp.position), '[]') from task_steps sp where sp.stage_id = sg.id))
                 order by sg.position), '[]') from task_stages sg where sg.task_id = t.id),
      'runs', (select coalesce(jsonb_agg(to_jsonb(r) || case when p_task_id is null then '{}'::jsonb else jsonb_build_object(
                 'steps', (select coalesce(jsonb_agg(to_jsonb(rs) || jsonb_build_object(
                     'shots', (select coalesce(jsonb_agg(to_jsonb(sh) order by sh.shot_no), '[]') from task_shots sh where sh.run_step_id = rs.id),
                     'series_notes', (select coalesce(jsonb_agg(to_jsonb(sn) order by sn.series_no), '[]') from task_series_notes sn where sn.run_step_id = rs.id))
                   order by rs.order_done), '[]') from task_run_steps rs where rs.run_id = r.id),
                 'events', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at), '[]') from task_events e where e.run_id = r.id),
                 'reports', (select coalesce(jsonb_agg(to_jsonb(rp) order by rp.created_at), '[]') from task_reports rp where rp.run_id = r.id))
               end order by r.started_at), '[]') from task_runs r where r.task_id = t.id)
    ) order by t.created_at desc)
    from tasks t
    where t.grant_id = v_grant and (p_task_id is null or t.id = p_task_id)
  ), '[]'::jsonb);
end;
$$;

-- Устройство тренера — чтобы получать push «задание выполнено».
create or replace function register_coach_device(p_token text, p_fcm text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_grant uuid;
begin
  v_grant := validate_share_token(p_token);
  if v_grant is null then return; end if;
  update share_grants set coach_fcm_token = nullif(trim(p_fcm), '') where id = v_grant;
end;
$$;

-- Для сервера push: устройства спортсмена, если токен тренера действующий.
create or replace function task_push_targets(p_token text)
returns setof text
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if validate_share_token(p_token) is null then return; end if;
  return query select token from task_devices;
end;
$$;

-- ---------- Спортсмен (владелец базы) ----------

-- Прохождение целиком одним JSON (сохраняется разом, после выполнения):
-- {task_id, started_at, finished_at, final_note, steps:[{step_id, order_done,
-- started_at, finished_at, report, shots:[…], series_notes:[…]}], events:[…]}.
create or replace function athlete_submit_run(p_run jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_run uuid;
  v_rs uuid;
  s jsonb;
  x jsonb;
begin
  if not is_project_owner() then raise exception 'owner only'; end if;
  insert into task_runs (task_id, started_at, finished_at, status, final_note)
  values ((p_run->>'task_id')::uuid, nullif(p_run->>'started_at', '')::timestamptz,
          nullif(p_run->>'finished_at', '')::timestamptz, coalesce(p_run->>'status', 'done'),
          coalesce(p_run->>'final_note', ''))
  returning id into v_run;
  for s in select * from jsonb_array_elements(coalesce(p_run->'steps', '[]'::jsonb)) loop
    insert into task_run_steps (run_id, step_id, order_done, started_at, finished_at, report)
    values (v_run, nullif(s->>'step_id', '')::uuid, nullif(s->>'order_done', '')::int,
            nullif(s->>'started_at', '')::timestamptz, nullif(s->>'finished_at', '')::timestamptz,
            coalesce(s->>'report', ''))
    returning id into v_rs;
    for x in select * from jsonb_array_elements(coalesce(s->'shots', '[]'::jsonb)) loop
      insert into task_shots (run_step_id, shot_no, series_no, x_mm, y_mm, score, shot_at, sighting, note)
      values (v_rs, (x->>'shot_no')::int, coalesce((x->>'series_no')::int, 1), (x->>'x_mm')::float8,
              (x->>'y_mm')::float8, (x->>'score')::float8, nullif(x->>'shot_at', '')::timestamptz,
              coalesce((x->>'sighting')::boolean, false), coalesce(x->>'note', ''));
    end loop;
    for x in select * from jsonb_array_elements(coalesce(s->'series_notes', '[]'::jsonb)) loop
      insert into task_series_notes (run_step_id, series_no, note)
      values (v_rs, (x->>'series_no')::int, coalesce(x->>'note', ''));
    end loop;
    for x in select * from jsonb_array_elements(coalesce(s->'events', '[]'::jsonb)) loop
      insert into task_events (run_id, run_step_id, type, details)
      values (v_run, v_rs, x->>'type', x->'details');
    end loop;
  end loop;
  return v_run;
end;
$$;

-- Для сервера push: устройства тренеров (владелец спрашивает своих).
create or replace function task_coach_targets()
returns setof text
language sql
security definer
set search_path = public, extensions
as $$
  select coach_fcm_token from share_grants
  where is_project_owner() and revoked_at is null and coach_fcm_token is not null;
$$;

grant execute on function coach_create_task(text, jsonb) to anon, authenticated;
grant execute on function coach_set_task_status(text, uuid, text) to anon, authenticated;
grant execute on function coach_get_tasks(text, uuid) to anon, authenticated;
grant execute on function register_coach_device(text, text) to anon, authenticated;
grant execute on function task_push_targets(text) to anon, authenticated;
grant execute on function athlete_submit_run(jsonb) to authenticated;
grant execute on function task_coach_targets() to authenticated;

notify pgrst, 'reload schema';
