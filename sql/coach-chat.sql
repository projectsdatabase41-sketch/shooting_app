-- «Чат с тренером» (у спортсмена) ↔ «Чат со спортсменами» (у тренера).
-- Отдельно и от мессенджера, и от комментариев к тренировкам. Живёт в
-- ЛИЧНОЙ базе спортсмена; одна переписка на выданный тренеру токен
-- (share_grants) — у каждого тренера своя. Повторный запуск безопасен.
--
-- Спортсмен читает/пишет таблицу напрямую (он владелец базы), тренер —
-- функциями ниже по своему токену, без входа в базу спортсмена.

create table if not exists coach_chat (
  id           uuid primary key default gen_random_uuid(),
  grant_id     uuid not null references share_grants(id) on delete cascade,
  author_role  text not null check (author_role in ('athlete', 'coach')),
  text         text not null check (char_length(text) between 1 and 4000),
  created_at   timestamptz not null default now()
);
create index if not exists idx_coach_chat_grant on coach_chat(grant_id, created_at);

alter table coach_chat enable row level security;
drop policy if exists "owner coach_chat" on coach_chat;
create policy "owner coach_chat" on coach_chat
  for all using (is_project_owner()) with check (is_project_owner());

create or replace function get_coach_chat(p_token text)
returns setof coach_chat
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  v_id := validate_share_token(p_token);
  if v_id is null then return; end if;
  return query
    select * from (
      select * from coach_chat where grant_id = v_id order by created_at desc limit 500
    ) last500 order by created_at;
end;
$$;

-- Автор проставляется сервером ('coach'), из клиента не приходит.
create or replace function add_coach_chat(p_token text, p_text text)
returns coach_chat
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_row coach_chat;
begin
  v_id := validate_share_token(p_token);
  if v_id is null then raise exception 'invalid or revoked token'; end if;
  insert into coach_chat (grant_id, author_role, text)
  values (v_id, 'coach', trim(p_text))
  returning * into v_row;
  return v_row;
end;
$$;

-- Тренер удаляет только свои сообщения.
create or replace function delete_coach_chat(p_token text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  v_id := validate_share_token(p_token);
  if v_id is null then raise exception 'invalid or revoked token'; end if;
  delete from coach_chat where id = p_id and grant_id = v_id and author_role = 'coach';
end;
$$;

grant execute on function get_coach_chat(text) to anon, authenticated;
grant execute on function add_coach_chat(text, text) to anon, authenticated;
grant execute on function delete_coach_chat(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
