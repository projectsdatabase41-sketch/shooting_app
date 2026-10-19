# Nexus (shooting_app) — руководство по проекту

Документ для того, кто продолжает работу (человек или ИИ), когда прежний контекст потерян.
Читать целиком, затем `CLAUDE.md`, `docs/db-schema-actual.md`, `docs/puls-for-ai.md`.
Актуально на 2026-10-19 (коммиты до `0760b80` и позже; смотрите `git log`).

## 1. Что это

Flutter-приложение для стрелков (Android, веб на GitHub Pages, Windows/iOS-сборки есть, но основные — Android и веб):
тренировки на мишени, статистика, финалы (соревнование с ботами и людьми), мессенджер (с P2P и звонками),
задания тренера, заметки, ИИ-ассистент, «сервисы» (свои плитки). Репозиторий
`projectsdatabase41-sketch/shooting_app`, ветка `main`. Каждый пуш в `main` собирается CI
(Android APK в релиз `latest-apk`, веб на Pages, автоперевод интерфейса).

Владелец говорит по-русски; ответы — кратко, по-русски, без выдумок (см. `CLAUDE.md`).

## 2. Правила работы (важно)

- **Коммитить только явные пути** (`git add путь…`). Никогда `git add sql` / `git add .`: в `sql/` и корне лежат
  файлы ДРУГОГО ИИ владельца (`SUPABASE-CREATE.md`, `DATA-INGEST.md`, `TASK-sync-mapping.md`,
  `sql/supabase-schema.sql`, `sql/import-scatt-2023.sql`, `sql/table-docs.sql`, `sql/qwen-tables-access.sql`,
  `sql/fix-legacy-target-faces.sql`) — читать можно, менять и коммитить нельзя. Также не коммитить
  `.claude/`, `.mcp.json`, `.claudeignore`, `web/manifest.json` без просьбы.
- Force-push — только с прямого разрешения владельца.
- Секреты (ключи Supabase/Firebase/OpenRouter, PUSH_SECRET, токены) — никогда в чат, коммиты и публичный конфиг.
- Честность: не утверждать, что проверено на устройстве, если проверялось только тестами/анализатором.
- Перед каждым пушем: `flutter analyze --no-fatal-infos` (CI падает на **warning**, не только на error) и целевые тесты.
- Диск: на машине владельца часто почти нет места; `flutter test` падает при сборке «Недостаточно места».
  Перед прогоном чистить `%TEMP%\flutter_tools.*`; полный набор гонять пакетами по ~8 файлов.
- Подсказки в коде: комментарии на русском, объясняют ПОЧЕМУ (решение владельца / причина бага).

## 3. Карта репозитория

| Путь | Что там |
|---|---|
| `lib/main.dart` | запуск, тема, `ShootingApp`, заставка, анимации, push-тап в вебе, переход по push |
| `lib/screens/` | экраны (55): главная `home_shell.dart`, настройки `settings_*`, мишень `target_screen.dart`, финалы `final*_screen.dart`, мессенджер `chat_*`, чемпионы `champions_screen.dart`, звонок `call_screen.dart`, проверка базы `db_check_screen.dart` … |
| `lib/widgets/` | общие виджеты: плитки `home_tabs_bar.dart`, шапка `glass_pill.dart`, фон `app_backdrop.dart`/`tile_backdrop.dart`, мишень `target_canvas.dart`, кружок `circle_video.dart`, подсветка `selfie_light.dart`, блоки статистики `stats_blocks.dart` … |
| `lib/services/` | сервисы (59): сеть и база — `chat_auth_service`, `chat_sync_service`, `supabase_*`, `coach_*`; живая связь — `realtime_client`, `live_chat_session`, `webrtc_peer_link`, `p2p_file_transfer`, `call_session`; ИИ — `ai_service`, `knowledge_service`, `ai_memory_service`; прочее — `push_service`, `remote_config`, `app_update_service_*`, `starter_exercises`, `db_setup_check` |
| `lib/state/` | `AppDataStore` (главное состояние), `HomeTabsViewModel` (плитки), `TargetViewModel`, `AiChatViewModel`, `PersonalizationViewModel` |
| `lib/logic/` | чистая логика без UI: подсчёт очков, аналитика, `ai_context.dart` (контекст для ИИ), `text_search.dart`, `avatar_utils.dart` |
| `lib/models/` | модели данных (упражнение, тренировка, выстрел, мишень, сообщение чата …) |
| `lib/finals/` | движок финалов: `final_engine`, `final_run` (контроллер раунда), `bot`, `finals_net` (совместный финал по Realtime), `champions_service`, `announcer` |
| `lib/tasks/` | задания тренера: модели, сервис, экраны спортсмена/тренера, прохождение |
| `lib/theme/` | `app_theme.dart`, `app_transitions.dart` (анимации переходов + `TileOpen`/`MorphRoute`) |
| `lib/i18n/` + `i18n/` | перевод интерфейса: `tr('рус')`, словари en/de/zh встроены, 10 языков качаются, CI `translate.yml` дополняет |
| `lib/local_ai/` | локальная модель (llama.cpp) — только Android/десктоп, веб не поддерживает |
| `lib/db/` | `local_schema.sql` (локальная sqlite), `puls_install.sql` (исходник), **`nexus_personal_db.sql`** (собранный установщик личной базы) |
| `sql/` | SQL для серверов (см. раздел 5) |
| `cloud/calls-worker/` | Cloudflare Worker звонков (сигнализация, push звонков, выдача TURN) |
| `supabase/functions/` | Edge Functions: `send-chat-push`, `chat-drive-token` |
| `config/chat-config.json` | удалённый конфиг (флаги realtime/webrtc, адрес мессенджера, пауза push); читается через raw.githubusercontent |
| `tools/` | генераторы: `gen_backgrounds.py` (фоны/иконки), `gen_chat_wallpapers.py` (обои чата), `gen_splash_video.py`, `build_personal_sql.py` (установщик личной базы) |
| `.github/workflows/` | `build-apk.yml` (APK + `version.json` в релиз), `deploy-web.yml`, `translate.yml` |
| `test/` | ~80 файлов тестов (виджеты, логика, имитация Realtime/P2P) |
| `docs/` | `db-schema-actual.md` (реальная схема личной базы), `puls-for-ai.md`, `scatt-import-guide.md`, этот файл |

## 4. Где что хранится (данные)

- **Локально:** sqlite (`LocalDbService`; в вебе — wasm в IndexedDB, браузер может стереть — поэтому у веба просим `storage.persist`). Настройки — таблица `color_prefs` (ключ/значение) и `project_settings`.
- **Личная база Supabase** (у каждого спортсмена/тренера своя; у владельца `fiwpmxfonmyadatggtuj`): тренировки, выстрелы, комментарии, задания, `notes`, токены тренеров `share_grants`. Приложение ходит по REST (пакет `http`, без `supabase_flutter`). Создаётся SQL `lib/db/nexus_personal_db.sql`.
- **Публичная база** (`yirvomezybprdlntxyas`): мессенджер (профили, сообщения-очередь, друзья, группы, push-токены, Realtime-политики), финалы/чемпионы, отзывы, книги/правила для ИИ. MCP к ней нет — SQL запускает владелец.
- Старый сервер мессенджера `frbptucr…` и `APP_Tranzite` не используются.
- **Таблица `notes` общая с другим ИИ владельца** (RAG-память). Приложение трогает только строки `source='nexus_app'` (`notes_sync_service.dart`, `coach_notes_repository.dart`). Для диагностики структуры — `sql/inspect-notes.sql`.

## 5. SQL: какой файл для какой базы

**Личная база** — запускать ОДИН файл `lib/db/nexus_personal_db.sql` (собирается `python tools/build_personal_sql.py` из
`puls_install.sql` + `sql/share-policy.sql` + `sql/tasks.sql` + `sql/task-delete.sql` + `sql/coach-chat.sql` + `sql/coach-chat-link.sql`).
Идемпотентен; в конце — таблица «что/есть ли». Приложение: Настройки → Данные и синхронизация → «Проверка базы»
(`db_check_screen.dart`, `db_setup_check.dart`) проверяет таблицы и функции; список там и в скрипте сборки обязан совпадать
(тест `test/db_setup_check_test.dart`). Приложение само SQL выполнить НЕ может (ключ anon не создаёт таблицы) — только скопировать
и открыть SQL Editor.

**Публичная база (мессенджер и прочее)** — по порядку/по надобности (все идемпотентны):
`chat-schema.sql` (база мессенджера), `chat-groups.sql`, `chat-friends-blocks.sql`, `chat-reactions.sql`, `chat-presence.sql`,
`chat-friend-push.sql`, `chat-push-gate.sql`, `chat-group-realtime.sql`, `chat-contact-code.sql`,
**`chat-active-device.sql`** (одно активное устройство на аккаунт), `finals-sessions.sql`, `finals-champions.sql`,
**`finals-champions-gender.sql`**, **`finals-champions-age.sql`**, `app-feedback.sql` / `shared-feedback.sql` (отзывы).
Функции `supabase/functions/send-chat-push` деплоит владелец (`--no-verify-jwt`, секреты FIREBASE_*, PUSH_SECRET).

## 6. Подсистемы (коротко, с главными файлами)

**Плитки и модули.** `HomeTabsViewModel` — порядок/видимость/колонки/размер плиток; `ModulesSettings` — включённость модулей
(на новой установке всё выключено). `AppDataStore.isAthlete/isCoach` определяются включёнными вкладками («Тренировки» → спортсмен,
«Я тренер» = вкладка `athletes`). `RoleSplit`: если вы и спортсмен, и тренер — общий список «Чьи данные» (статистика, задания).
Плитки: стиль «стекло», плотность, тень (`TileStyle`), размер (`tileMaxPx`), перетаскивание.

**Анимации и оформление.** `AppTransitions` (один построитель на все экраны; типы: растворение, разброс, горизонт, вертикаль, наплыв,
затухание, «превращение» `MorphRoute`), настройки в «Внешний вид». Фоны: `AppBackdrop(kind)` картинки
`assets/bg/{web,android}/<kind>_{dark,light}.webp`; обои чата `assets/bg/chat/*.webp`. Заставка: `SplashGate` (`assets/video/splash_loop.mp4`,
запасной рисунок кодом). Индикатор ожидания — `AppLoader` (пульсирующая N). Статус-бар прозрачный (edge-to-edge).

**Тренировка.** `target_screen.dart`, `TargetViewModel`, `target_canvas.dart` (+лупа при перетаскивании пробоины), `painters/target_painter.dart`.
Стартовые упражнения по профилю — `starter_exercises.dart`.

**Финалы.** `FinalRunController` (фазы: пристрелка → заряжай → старт → стоп; боты с камбэками; ручной режим тренера/жюри),
совместные финалы `finals_net.dart` (Realtime), роли приглашённых: **Участник** и **Жюри** (равные права: команды и ввод).
Диктор `announcer.dart` (TTS + команды). Чемпионы: публикация с подписью тренера/самопроверкой, жалобы/апелляции, фильтр (упражнение, пол,
возраст по году рождения), профиль чемпиона.

**Мессенджер.** Авторизация `ChatAuthService` (выход из аккаунта — ТОЛЬКО при отказе сервера; сеть/5xx/429 сессию не трогают; ручной выход
отключает тихий вход `manualSignOut`). Доставка: P2P (WebRTC DataChannel) → Realtime → база (текст и вложения до 8 МБ; большие файлы P2P → Google Drive).
`LiveChatSession`, `ChatSyncService`. Одно активное устройство на аккаунт (`isActiveDevice`, нужен SQL). Подключение тренера без кодов — карточки
`NX1:{json}` (`coach_link.dart`: запрос, приглашение тренером, согласие, выдача токена). Восстановление истории у собеседника
(`chat_history_transfer.dart`, по согласию, P2P-файлом). Push: FCM; веб — `web/firebase-messaging-sw.js` + `push-bridge.js`
(нажатие на push открывает нужный чат). Выключенный модуль «Мессенджер» снимает push-токен.

**Звонки.** `CallSession`: сигналы по каналу переписки (P2P → Realtime), запасной путь через Cloudflare Worker (комната + push) через 4 с.
Медиа — WebRTC напрямую, TURN выдаёт воркер (`/ice`). Свет при съёмке: фонарик/подсветка экрана (`selfie_light.dart`).

**ИИ.** `AiService` (цепочка моделей OpenRouter + свой ключ + локальная), `AiContext` (контекст: тренировки, спортсмены, владельцы данных),
`KnowledgeService` (поиск по книгам/таблицам; **список файлов базы ≠ содержание** — правило в промпте, см. `asPromptBlock`),
память разговоров (`ai_memory_service`, сброс облачной/локальной), единый ассистент для всех ролей. При выключенном модуле ИИ все кнопки с ИИ скрыты (`ai_gate.dart`).

**Задания тренера** (`lib/tasks`), **заметки** (`notes_sync_service` ↔ таблица `notes`), **обновление приложения**
(`app_update_service_io.dart`: проверка по `version.json` в релизе — без лимитов API GitHub; запасной путь API; докачка APK).

## 7. Сборка, тесты, CI

- Анализ: `flutter analyze --no-fatal-infos` (должно быть 0 error и 0 warning). Тесты: `flutter test` (полный набор ~380 тестов, 2–3 мин при достаточном диске).
- CI APK падает на шаге «Сборка APK», если сломана команда в `.github/workflows/build-apk.yml` (был случай с литералом `\n`). Проверить APK без API:
  `curl -sL https://github.com/<repo>/releases/download/latest-apk/version.json` — там `sha` последней собранной версии.
  У API GitHub лимит 60 запросов/час на IP — опрашивать им нельзя.
- Dart: `\w` в `RegExp` не матчит кириллицу, а `caseSensitive:false` не работает для кириллицы без `unicode:true` — приводить текст к нижнему регистру и писать `[а-яё]`.
- Тесты с таймерами: отменять `Timer` в `dispose`, иначе «Timer is still pending».

## 8. Что должен выполнить владелец (SQL и деплой)

Владелец сообщал, что выполнил код `finals-champions-gender.sql`; по `finals-champions.sql` и `chat-active-device.sql` подтверждение надо
уточнить (проверить REST-запросом, что колонка/функция есть). Точно требуют запуска:
`finals-champions-age.sql` (возраст), по желанию `nexus_personal_db.sql` на чистой тестовой базе (проверить «Проверку базы»), `inspect-notes.sql`
(результат вставить ассистенту, чтобы описать структуру `notes`). Передеплой `send-chat-push` — если менялась функция.

## 9. Не проверено на устройствах / открытое

- P2P между телефонами и звонки через канал переписки; вход с двух устройств; баннер «Использовать здесь».
- Работа из РФ без VPN (Supabase/GitHub/STUN могут быть нестабильны) — диагностика «Проверка связи» не сделана.
- Групповые звонки: возможны (mesh до ~4 участников на WebRTC; дальше нужен SFU, например Cloudflare Calls) — не реализованы.
- Уведомление при перегруженном мессенджере; фото несколькими в одном сообщении; push в вебе (iOS — только у сайта на главном экране).
- Идеи/бэклог: `memory/project_ideas_backlog*.md` в папке памяти ассистента; ИИ-«новая статистика» системой отображения; интеграции других проектов
  в сеть Nexus (структуру даст владелец).

## 10. С чего начать новую сессию

1. `git status` и `git log --oneline -15`; проверить `version.json` релиза.
2. Прочитать `CLAUDE.md`, этот файл, `docs/db-schema-actual.md`.
3. Свежий отзыв пользователей приходит CSV (`app_feedback_rows (N).csv`) — разбирать по пунктам, сверять с кодом, не считать сделанным то, что не проверено.
4. Перед пушем — анализ и целевые тесты; коммиты с явными путями.
