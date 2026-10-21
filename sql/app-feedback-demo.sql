-- Публичная база: отметка «включён режим Демо» в отзывах (демо меняет показываемое содержимое).
-- Идемпотентно. Приложение работает и без колонки (повторяет отправку без неё).
alter table app_feedback add column if not exists demo boolean not null default false;
notify pgrst, 'reload schema';
