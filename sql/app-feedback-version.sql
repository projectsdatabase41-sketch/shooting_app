-- Публичная база: версия приложения в отзывах. Идемпотентно. Приложение работает и без
-- этой колонки (повторяет отправку без версии), но версия в отзывах появится только после неё.
alter table app_feedback add column if not exists app_version text check (char_length(app_version) <= 40);
notify pgrst, 'reload schema';
