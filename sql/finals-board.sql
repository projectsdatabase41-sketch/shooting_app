-- Табло публичных финалов (публичная база мессенджера). Запускать вручную в SQL editor.
-- Безопасно запускать повторно.
--
-- Публичный финал ведущий выставляет на табло: «готовится», «идёт», «окончен».
-- Зрители видят табло без входа и подключаются по секретному имени канала (key).
-- Сами финалы в базе не хранятся: по каналу идёт только realtime. Старше 6 часов на табло не показываются.

create table if not exists finals_board (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null default auth.uid(),
  host_name text not null default '',
  format_id text not null,
  key text not null,                       -- секретное имя канала realtime
  url text,                                -- личная база ведущего (если канал там)
  anon_key text,
  max_spectators int not null default 50 check (max_spectators between 0 and 150),
  status text not null default 'preparing' check (status in ('preparing', 'live', 'finished')),
  top jsonb,                               -- итог: [{name, place, total}]
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table finals_board enable row level security;

drop policy if exists board_read on finals_board;
create policy board_read on finals_board for select
  using (updated_at > now() - interval '6 hours');

drop policy if exists board_insert on finals_board;
create policy board_insert on finals_board for insert
  with check (host_id = auth.uid());

drop policy if exists board_update on finals_board;
create policy board_update on finals_board for update
  using (host_id = auth.uid()) with check (host_id = auth.uid());

drop policy if exists board_delete on finals_board;
create policy board_delete on finals_board for delete
  using (host_id = auth.uid());

grant select on finals_board to anon, authenticated;
grant insert, update, delete on finals_board to authenticated;
