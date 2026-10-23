-- Табло публичных финалов (публичная база мессенджера). Запускать вручную в SQL editor.
-- Безопасно запускать повторно.
--
-- Публичный финал ведущий выставляет на табло: «готовится», «идёт», «окончен».
-- Табло показывает только краткие сведения (формат, регион, жюри, участники, итог).
-- Секретное имя канала и адрес базы лежат в закрытых колонках: напрямую их не прочитать,
-- их отдаёт только функция finals_board_join, и только для финала, который ещё не окончен.
-- Сами финалы в базе не хранятся: по каналу идёт только realtime. Старше 6 часов на табло не показываются,
-- строки старше суток удаляются при добавлении новых.

create table if not exists finals_board (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null default auth.uid(),
  host_name text not null default '',
  region text not null default '',
  format_id text not null,
  key text not null,                       -- секретное имя канала realtime (закрыто)
  url text,                                -- личная база ведущего, если канал там (закрыто)
  anon_key text,                           -- (закрыто)
  max_spectators int not null default 50 check (max_spectators between 0 and 150),
  status text not null default 'preparing' check (status in ('preparing', 'live', 'finished')),
  people jsonb not null default '{}'::jsonb,   -- {"jury": [имена], "athletes": [имена]}
  top jsonb,                               -- итог: [{name, place, total}]
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table finals_board add column if not exists region text not null default '';
alter table finals_board add column if not exists people jsonb not null default '{}'::jsonb;

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

-- Закрытые колонки key / url / anon_key: читать нельзя, писать можно.
revoke all on finals_board from anon, authenticated;
grant select (id, host_id, host_name, region, format_id, max_spectators, status, people, top, created_at, updated_at)
  on finals_board to anon, authenticated;
grant insert, update, delete on finals_board to authenticated;

-- Вход зрителя: отдаёт секретное имя канала только для идущего или готовящегося финала.
create or replace function finals_board_join(p_id uuid)
returns table(key text, url text, anon_key text)
language sql security definer set search_path = public as $$
  select b.key, b.url, b.anon_key from finals_board b
  where b.id = p_id and b.status in ('preparing', 'live') and b.updated_at > now() - interval '6 hours';
$$;
revoke all on function finals_board_join(uuid) from public;
grant execute on function finals_board_join(uuid) to anon, authenticated;

-- Уборка: при добавлении строки удаляем всё, что старше суток.
create or replace function finals_board_cleanup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from finals_board where updated_at < now() - interval '1 day';
  return new;
end;
$$;
drop trigger if exists finals_board_cleanup_trg on finals_board;
create trigger finals_board_cleanup_trg before insert on finals_board
  for each row execute function finals_board_cleanup();
