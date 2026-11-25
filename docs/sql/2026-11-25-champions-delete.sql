-- Отзыв владельца 25.11: владелец финала может пометить его на удаление.
-- В течение 10 минут после пометки финал исчезает из публичной выдачи
-- (политика champions_read); до того он виден всем с пометкой, а пометку
-- владелец может снять. Безопасно запускать повторно. Запускать вручную
-- в SQL editor (публичная база yirvom).

alter table finals_champions add column if not exists delete_at timestamptz;

-- Пометить на удаление или снять пометку может только владелец записи.
-- При успехе возвращает null, иначе — понятный текст ошибки на русском
-- (тот же стиль, что у остальных RPC проекта).
create or replace function finals_champion_mark_delete(p_id uuid, p_cancel boolean default false)
returns text
language plpgsql
security definer
set search_path = public as $$
declare owner uuid;
begin
  if auth.uid() is null then
    return 'Войдите в мессенджер';
  end if;
  select user_id into owner from finals_champions where id = p_id;
  if owner is null then
    return 'Финал не найден';
  end if;
  if owner <> auth.uid() then
    return 'Удалять можно только свой финал';
  end if;
  update finals_champions
     set delete_at = case when p_cancel then null else now() + interval '10 minutes' end
   where id = p_id;
  return null;
end $$;
grant execute on function finals_champion_mark_delete(uuid, boolean) to authenticated;

-- Из публичной выдачи строка исчезает, когда время пометки истекло: пока
-- delete_at > now() — видна с пометкой, после — скрыта от всех по этой политике.
drop policy if exists champions_read on finals_champions;
create policy champions_read on finals_champions for select
  using (consent and coach_signed_at is not null and (banned_until is null or banned_until < now())
    and (delete_at is null or delete_at > now()));

-- champions_owner_read (user_id = auth.uid()) не трогаем: владелец и после
-- истечения пометки видит свою запись (в своём списке) и может снять пометку —
-- при снятии строка снова станет публичной.
