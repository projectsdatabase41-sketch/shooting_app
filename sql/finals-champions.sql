-- Таблица чемпионов (публичная база yirvom). Запускать вручную в SQL editor.
create table if not exists finals_champions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  display_name text not null,
  format_id text not null,
  total numeric not null,
  stats jsonb not null,            -- СТП, разброс (для ботов), без сырых данных
  coach_id uuid,                   -- подпись тренера
  coach_signed_at timestamptz,
  consent boolean not null default false,
  banned_until timestamptz,
  created_at timestamptz not null default now()
);
alter table finals_champions enable row level security;
create policy champions_read on finals_champions for select
  using (consent and coach_signed_at is not null and (banned_until is null or banned_until < now()));
create policy champions_insert on finals_champions for insert
  with check (user_id = auth.uid() and consent and coach_signed_at is null);
-- Подпись тренера ставит только он (coach_id = его uid), владелец не может.
create policy champions_coach_sign on finals_champions for update
  using (coach_id = auth.uid()) with check (coach_id = auth.uid());
-- Тренер видит записи, ждущие его подписи; владелец видит свои.
create policy champions_coach_read on finals_champions for select using (coach_id = auth.uid());
create policy champions_owner_read on finals_champions for select using (user_id = auth.uid());
-- Подписать можно только неподписанную запись и только проставив подпись.
