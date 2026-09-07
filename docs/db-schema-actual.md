# Фактическая схема Supabase (снято 2026-09-06)

Снято через `GET /rest/v1/` (OpenAPI-описание PostgREST) секретным
ключом проекта `fiwpmxfonmyadatggtuj` — публичный ключ этот эндпоинт не
пускает ("Secret API key required"), обычный `OPTIONS` в этой версии
PostgREST схему больше не возвращает (пустое тело). Секретный ключ
использован только для этого разового снятия схемы и нигде не осел ни
в приложении, ни в репозитории.

Ниже — реальные колонки как есть, без правок. Таблицы `comments` и
`training_notes` в этом снимке ОТСУТСТВОВАЛИ — они добавлены
отдельным блоком в `sql/schema.sql` (см. раздел «Чего не хватало»).

## archived_packages
id uuid PK · remote_source_id uuid → remote_athlete_sources.id ·
original_package_id uuid NOT NULL · athlete_label text · source_project_url text ·
started_at timestamptz · fetched_at timestamptz NOT NULL ·
package_json jsonb NOT NULL · checksum text · note text · created_at timestamptz NOT NULL

## exercise_templates
id uuid PK · code text NOT NULL · name text NOT NULL · weapon_type text NOT NULL ·
ammo_type text NOT NULL · distance_m numeric NOT NULL · shots_count integer NOT NULL ·
series_count integer · shots_per_series integer · target_face_id uuid → target_faces.id ·
time_limit_minutes integer · official_code text · is_custom boolean NOT NULL ·
is_active boolean NOT NULL · created_at timestamptz NOT NULL · updated_at timestamptz NOT NULL

## exercises
Не «упражнение» в смысле приложения — снимок параметров ОДНОГО
исполнения упражнения внутри пакета (у пакета их может быть несколько,
у приложения сейчас всегда один).

id uuid PK · package_id uuid NOT NULL → training_packages.id ·
exercise_name text · discipline text NOT NULL · distance_meters numeric NOT NULL ·
target_face_id uuid → target_faces.id · decimal_scoring boolean NOT NULL ·
expected_shots integer · started_at timestamptz · time_is_approximate boolean NOT NULL ·
created_at timestamptz NOT NULL · updated_at timestamptz NOT NULL

## file_assets, photo_import_jobs, remote_athlete_sources, archived_packages
Инфраструктура под фото-импорт и дневник тренера через удалённый
источник — в приложении этой функциональности пока нет (см. TASK
раздел 2). Схема не трогается, мост её не использует.

## project_settings
id uuid PK · owner_user_id uuid NOT NULL · project_name text · status text NOT NULL ·
paused_at timestamptz · pause_reason text · is_athlete boolean NOT NULL ·
is_coach boolean NOT NULL · keep_local_packages_count integer NOT NULL ·
keep_files_after_sync boolean NOT NULL · sync_only_wifi boolean NOT NULL ·
storage_balance text NOT NULL · created_at timestamptz NOT NULL · updated_at timestamptz NOT NULL

Мост эту таблицу не трогает — раздел 1 задания говорит только про
тренировку/упражнение/выстрел, а `is_athlete`/`is_coach` тут дублируют
локальный рубильник режима тренера другим способом (через RPC
`set_project_status`, не прямой записью). Отдельная задача.

## share_grants
id uuid PK · token_hash text NOT NULL · label text · description text ·
permissions text[] NOT NULL · created_by uuid · created_at timestamptz NOT NULL ·
expires_at timestamptz · revoked_at timestamptz · revoked_by uuid · last_used_at timestamptz

`revoked_at` уже существует — в задании ошибочно указано как
отсутствующее, добавлять не потребовалось.

## share_events
id uuid PK · share_grant_id uuid → share_grants.id · event_type text NOT NULL ·
details jsonb NOT NULL · created_at timestamptz NOT NULL

## shots
id uuid PK · exercise_id uuid NOT NULL → exercises.id · shot_no integer NOT NULL ·
series_no integer · x_mm numeric · y_mm numeric · input_angle_degrees numeric ·
coordinate_source text NOT NULL · reported_score numeric · computed_score numeric ·
final_score numeric NOT NULL · source text NOT NULL · photo_import_id uuid → photo_import_jobs.id ·
is_manually_corrected boolean NOT NULL · confirmed boolean NOT NULL · shot_time_ms integer ·
created_at timestamptz NOT NULL · updated_at timestamptz NOT NULL

**Добавлено мостом:** `counts boolean not null default true`, `extra jsonb`
(раздел 5 задания, п.4 — были не хватало).

## target_faces
id uuid PK · code text NOT NULL · name text NOT NULL · distance_m numeric NOT NULL ·
default_caliber_mm numeric NOT NULL · scoring_type text NOT NULL · max_score numeric NOT NULL ·
ring_config jsonb NOT NULL · is_system boolean NOT NULL · is_active boolean NOT NULL ·
created_at timestamptz NOT NULL · updated_at timestamptz NOT NULL

## training_packages
id uuid PK · started_at timestamptz NOT NULL · ended_at timestamptz ·
time_is_approximate boolean NOT NULL · local_time_offset_minutes integer ·
title text · location text · note text · package_status text NOT NULL ·
editor_mode text NOT NULL · is_locked_by_athlete boolean NOT NULL ·
local_version integer NOT NULL · created_at timestamptz NOT NULL · updated_at timestamptz NOT NULL

Ни одной колонки-владельца (`user_id` и т.п.) — проект персональный
(один Supabase-проект на одного спортсмена), RLS не фильтрует по
строкам, а проверяет `is_project_owner()`.

## RPC-функции (реальные имена — в задании не совпадают с ожиданиями кода)
`hash_share_token(p_token)`, `is_project_owner()`, `revoke_share_grant(p_share_grant_id)`,
`set_project_status(p_status)`, `validate_share_token(p_token)`.

Старые `create_share_token`/`revoke_share_token`/`get_shared_*`, которые
раньше вызывал `SupabaseSyncService`/`CoachAccessService`, **не существуют** —
это отдельный источник PGRST202, помимо колоночной ошибки `deleted_at`.
Мост обновлён под `hash_share_token`/`revoke_share_grant` для выдачи и
отзыва токена. Сторона тренера (`CoachAccessService`, чтение чужого
дневника по токену через `get_shared_*`) в этот проход НЕ включена —
нужны новые RPC на сервере под `validate_share_token`, это отдельная
задача за пределами раздела 1.

## Чего не хватало (добавлено в sql/schema.sql)

1. `comments` — таблицы не было вовсе. Создана по образу локальной
   (`lib/db/local_schema.sql`): id, package_id → training_packages.id
   (был `session_id` локально — переименовано мостом, не в БД), level,
   shot_id → shots.id, series_no, author_role, text, created_at.
2. `training_notes` — таблицы не было. Создана для будущего (локально
   таблица существует, но ни один экран её не использует — синхронизация
   для неё не написана, писать нечего).
3. `shots.counts`, `shots.extra` — не хватало.
4. `extra jsonb` — добавлено на `training_packages`, `exercises`,
   `exercise_templates` (запас на будущее, мост пока пишет его только
   на `training_packages`, см. «Чего сознательно нет» ниже).

## Соответствие полей

### Тренировка (`TrainingSession` ↔ `training_packages` + `exercises`(child))

| Поле приложения | Колонка БД | Комментарий |
|---|---|---|
| id | training_packages.id, exercises.id | **обе таблицы используют один и тот же uuid** — дочерняя строка `exercises` 1:1 с пакетом, свой отдельный id ей не нужен |
| exerciseId | — | восстанавливается при pull подбором по `exercises.exercise_name`+`target_face_id`+`exercise_templates.shots_per_series` (FK на шаблон в реальной схеме отсутствует) |
| targetFaceCode | exercises.target_face_id → target_faces.code | через справочник, не текстом напрямую |
| status | training_packages.package_status | `.name` из `SessionStatus` как есть |
| startedAt | training_packages.started_at | |
| finishedAt | training_packages.ended_at | |
| shots/trash | shots (по exercise_id = training_packages.id) | локальный `is_trashed` — только локальный флаг, в базу не идёт: корзина живёт до завершения тренировки, синхронизируются только finished-тренировки, где корзину уже нечем пополнить |
| extra | training_packages.extra | как есть, без обёртки |
| pauseIntervals | — | **не синхронизируется** — нужно для тайминга ЖИВОЙ тренировки, для просмотра на другом устройстве не требуется (нет и в списке обязательных полей round-trip теста, раздел 9 задания) |

### Упражнение (`Exercise` ↔ `exercise_templates`, плюс снимок в `exercises`(child))

| Поле приложения | Колонка БД | Комментарий |
|---|---|---|
| id | exercise_templates.id | стабильный uuid, upsert по id |
| name | exercise_templates.name, exercises.exercise_name | в обеих — при push |
| targetFaceCode | exercise_templates.target_face_id → target_faces.code | |
| totalShots | exercise_templates.shots_count, exercises.expected_shots | |
| seriesSize | exercise_templates.shots_per_series | |
| gender | — | **не синхронизируется** — колонки нет, вне обязательного списка |
| deletedAt / isDeleted | exercise_templates.is_active (инверсия) | точное время удаления не хранится — при pull, если `!is_active`, `deletedAt` берётся из `updated_at` (приближение, но `isDeleted` не зависит от точности момента) |
| series (гибкие серии) | — | **не синхронизируется** — колонки нет, вне обязательного списка |
| code | exercise_templates.code | у приложения поля `code` больше нет (убрано ранее); пишем синтетическое `custom_<id>` — только чтобы удовлетворить NOT NULL, нигде не читается обратно |
| — | exercise_templates.weapon_type, ammo_type | выводятся из `TargetFace.code`/`caliberMm` (`TargetFace.weaponRu`/`ammoRu` тем же способом) |

### Выстрел (`Shot` ↔ `shots`)

| Поле приложения | Колонка БД | Комментарий |
|---|---|---|
| id | id | |
| shotNumber | shot_no | |
| seriesNo | series_no | при pull null → 1 |
| xMm / yMm | x_mm / y_mm | **Y как есть, без переворота знака** — обе стороны используют одну и ту же конвенцию (вверх положительный), проверено тестом round-trip |
| score | final_score | читаем как есть, **не пересчитываем** |
| — | computed_score | пишем `scoreForRadius(radiusMm)` для справки на сервере, при чтении не используется |
| time | shot_time_ms | миллисекунды эпохи (`millisecondsSinceEpoch`) — колонка называется двусмысленно, это самое буквальное прочтение и единственное, что не требует контекста пакета для восстановления абсолютного времени |
| isFavorite | — | **не синхронизируется** — колонки нет, вне обязательного списка |
| isManuallyEdited | is_manually_corrected | |
| counts | counts | добавлено мостом |
| extra | extra | добавлено мостом, как есть |
| — | coordinate_source, source | константа `'app'` — провенанс (рука/фото/прибор) в локальной модели отдельно не хранится |
| — | confirmed | константа `true` |
