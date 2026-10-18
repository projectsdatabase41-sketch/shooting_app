-- Пол спортсмена в таблице чемпионов — для фильтра «Мужчины / Женщины».
-- Клиент публикует его из профиля ('m' / 'f'); у старых записей пусто (в фильтре по полу
-- они не показываются, в общем списке — да).
-- Выполнять в публичной базе (yirvomezybprdlntxyas). Повторный запуск безопасен.
alter table finals_champions add column if not exists gender text check (gender in ('m', 'f'));
create index if not exists finals_champions_gender_idx on finals_champions (format_id, gender, total desc);
