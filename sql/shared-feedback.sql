-- Применить в ОБЩЕЙ базе разработчика (yirvomezybprdlntxyas.supabase.co —
-- та же, что уже хранит shooting_rules/books), НЕ в личной базе
-- спортсмена/тренера. Пункт 10 списка правок: анонимные отзывы об
-- приложении, которые ассистент отправляет по явной просьбе
-- пользователя (см. AiContext.systemPrompt, блок ```feedback).
--
-- Анонимно намеренно: никакого владельца, устройства, версии
-- приложения — только сам текст и когда он пришёл.
create table if not exists feedback (
  id uuid primary key default gen_random_uuid(),
  text text not null,
  created_at timestamptz not null default now()
);

alter table feedback enable row level security;

-- Вставлять может кто угодно с публикуемым (anon) ключом — обычный
-- паттерн для анонимной формы обратной связи. Политики на SELECT для
-- anon/authenticated нет: читать отзывы может только сам разработчик
-- через Dashboard/service_role.
drop policy if exists feedback_insert_anon on feedback;
create policy feedback_insert_anon on feedback
  for insert
  to anon
  with check (true);
