-- Связь «спортсмен выдал токен тренеру» ↔ мессенджер. Выполнить в ЛИЧНОЙ
-- базе спортсмена (там же, где share_grants). Повторный запуск безопасен.
--
-- Тренер подключает спортсмена по токену → его приложение вызывает
-- link_coach_chat и записывает в этот токен свой чат-аккаунт; в ответ
-- получает чат-аккаунт спортсмена. «Позвать тренера» у спортсмена зовёт тех,
-- кому выданы ДЕЙСТВУЮЩИЕ токены (отозвал токен — звать уже некого).

alter table project_settings add column if not exists chat_user_id text;
alter table project_settings add column if not exists chat_nickname text;
alter table share_grants add column if not exists coach_chat_user_id text;
alter table share_grants add column if not exists coach_chat_nickname text;

create or replace function link_coach_chat(p_token text, p_chat_user_id text, p_nickname text)
returns table(athlete_chat_user_id text, athlete_nickname text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  v_id := validate_share_token(p_token);
  if v_id is null then
    return;
  end if;
  update share_grants
     set coach_chat_user_id = nullif(trim(coalesce(p_chat_user_id, '')), ''),
         coach_chat_nickname = left(trim(coalesce(p_nickname, '')), 60)
   where id = v_id;
  return query
    select ps.chat_user_id, ps.chat_nickname
    from project_settings ps
    where ps.chat_user_id is not null
    limit 1;
end;
$$;

grant execute on function link_coach_chat(text, text, text) to anon, authenticated;
