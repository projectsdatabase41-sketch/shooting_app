-- Год рождения спортсмена в таблице чемпионов — для фильтра по возрасту.
-- Клиент публикует его из профиля; у старых записей пусто (в фильтре по возрасту они
-- не показываются, в общем списке — да).
-- Выполнять в публичной базе (yirvomezybprdlntxyas). Повторный запуск безопасен.
alter table finals_champions add column if not exists birth_year int check (birth_year between 1900 and 2100);
create index if not exists finals_champions_birth_idx on finals_champions (format_id, birth_year, total desc);
