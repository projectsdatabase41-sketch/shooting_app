-- Код контакта собеседника — для панели профиля в переписке. Отдаётся
-- только тем, кто уже связан: друзья (любая заявка) или общая группа.
-- Выполнять в публичной базе (yirvomezybprdlntxyas). Повторный запуск безопасен.
create or replace function chat_code_of(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.chat_code from chat_profiles p
  where p.user_id = p_user
    and (
      exists (select 1 from chat_friends f
              where (f.requester_id = auth.uid() and f.addressee_id = p_user)
                 or (f.requester_id = p_user and f.addressee_id = auth.uid()))
      or exists (select 1 from chat_group_members a join chat_group_members b on a.group_id = b.group_id
                 where a.user_id = auth.uid() and b.user_id = p_user)
    );
$$;
revoke all on function chat_code_of(uuid) from public, anon;
grant execute on function chat_code_of(uuid) to authenticated;
