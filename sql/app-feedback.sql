-- Отзывы из режима «Демо» — публичная база (yirvom). Запускать вручную,
-- безопасно повторно.
--
-- Правила:
--  * в таблицу можно только ПИСАТЬ (anon и вошедшие); читать нельзя никому
--    через API — ни приложению, ни внутреннему ИИ. Смотреть отзывы — только в
--    панели Supabase (Table Editor / SQL editor под вашей учёткой);
--  * персональных данных нет: только текст, название страницы и платформа.

create table if not exists app_feedback (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  page text not null check (char_length(page) <= 200),
  text text not null check (char_length(text) between 1 and 4000),
  platform text not null default '' check (char_length(platform) <= 20)
);

alter table app_feedback enable row level security;

revoke all on app_feedback from anon, authenticated;
grant insert on app_feedback to anon, authenticated;

drop policy if exists feedback_insert on app_feedback;
create policy feedback_insert on app_feedback
  for insert to anon, authenticated
  with check (char_length(text) between 1 and 4000 and char_length(page) <= 200);
-- Политик select/update/delete нет намеренно.
