-- Ссылки на базы спортсменов в базе ТРЕНЕРА.
--
-- Куда выполнять: SQL editor твоего ЛИЧНОГО проекта Supabase (того, к которому
-- подключено приложение тренера: project_settings.supabase_url), а НЕ в базах
-- спортсменов. Безопасно запускать повторно целиком.
--
-- Зачем: чтобы ИИ тренера, читая твою базу, мог сам сходить в проект нужного
-- спортсмена по его адресу/ключу/share-токену и разобрать его тренировки.
-- Никакого Google Диска для этого не нужно.
--
-- Замена ключей: строка одна на спортсмена, ключ (owner_user_id, athlete_id).
-- Когда спортсмен переподключает тренера и выдаёт новый токен (или переезжает
-- на новый проект), приложение делает upsert с on_conflict=owner_user_id,
-- athlete_id — адрес, anon-ключ и токен перезаписываются целиком. Если
-- спортсмен удалён из приложения, строку надо удалить (см. примеры в конце).

-- 1. Таблица-зеркало подключений ------------------------------------------
create table if not exists coach_athlete_links (
  owner_user_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  -- локальный id спортсмена в приложении тренера (coach_athletes.id)
  athlete_id      text not null,
  name            text not null,
  supabase_url    text not null,
  supabase_anon_key text not null,
  share_token     text not null,
  -- valid — токен проверен, revoked — отозван/неверный, unknown — ещё не проверяли
  token_status    text not null default 'unknown'
                  check (token_status in ('valid', 'revoked', 'unknown')),
  updated_at      timestamptz not null default now(),
  primary key (owner_user_id, athlete_id)
);

create index if not exists coach_athlete_links_owner_idx
  on coach_athlete_links (owner_user_id);

-- 2. Доступ только владельцу (тренеру) ------------------------------------
alter table coach_athlete_links enable row level security;

drop policy if exists coach_links_owner_all on coach_athlete_links;
create policy coach_links_owner_all on coach_athlete_links
  for all
  using (owner_user_id = auth.uid())
  with check (owner_user_id = auth.uid());

-- 3. updated_at обновляется сам при каждой перезаписи ---------------------
create or replace function coach_athlete_links_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists coach_athlete_links_touch on coach_athlete_links;
create trigger coach_athlete_links_touch
  before update on coach_athlete_links
  for each row execute function coach_athlete_links_touch();

-- 4. Токен, по которому ИИ читает СПИСОК подключений ----------------------
-- Хранится в твоём project_settings (рядом с именем проекта и паролем чата).
-- Придумай длинную случайную строку (32+ символов) и впиши её в приложение
-- или выполни update из шага 6 — этот токен заменяет ИИ service_role.
alter table project_settings add column if not exists ai_links_token text;
create unique index if not exists project_settings_ai_links_token_idx
  on project_settings (ai_links_token) where ai_links_token is not null;

-- 5. RPC для ИИ: отдаёт все подключения, но только по токену --------------
create or replace function get_coach_athlete_links(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
begin
  if p_token is null or length(p_token) < 16 then
    return null;
  end if;
  select owner_user_id into v_owner
    from project_settings
   where ai_links_token = p_token
   limit 1;
  if v_owner is null then
    return null;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'athlete_id', l.athlete_id,
             'name', l.name,
             'url', l.supabase_url,
             'anon_key', l.supabase_anon_key,
             'token', l.share_token,
             'status', l.token_status,
             'updated_at', l.updated_at)
           order by l.name)
      from coach_athlete_links l
     where l.owner_user_id = v_owner), '[]'::jsonb);
end;
$$;

grant execute on function get_coach_athlete_links(text) to anon, authenticated;

-- 6. Примеры (выполнять по одному, по необходимости) ----------------------
-- Задать токен для ИИ:
--   update project_settings set ai_links_token = 'вставь-сюда-длинную-случайную-строку'
--    where owner_user_id = auth.uid();
--
-- Проверить, что ИИ увидит:
--   select get_coach_athlete_links('вставь-сюда-тот-же-токен');
--
-- Удалить подключение спортсмена (он больше не занимается):
--   delete from coach_athlete_links
--    where owner_user_id = auth.uid() and athlete_id = '...';

notify pgrst, 'reload schema';
