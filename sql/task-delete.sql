-- Выполнить один раз в базе СПОРТСМЕНА (SQL Editor): тренер сможет удалять свои задания совсем.
-- Удалить своё задание совсем (со ступенями, прохождениями и отчётами —
-- каскадом). Снять без удаления — coach_set_task_status.
create or replace function coach_delete_task(p_token text, p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_grant uuid;
begin
  v_grant := validate_share_token(p_token);
  if v_grant is null then raise exception 'invalid or revoked token'; end if;
  delete from tasks where id = p_task_id and grant_id = v_grant;
end;
$$;
grant execute on function coach_delete_task(text, uuid) to anon, authenticated;
