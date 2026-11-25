# Доступ ИИ тренера к базам спортсменов

Схема: у тренера в его собственной базе Supabase лежит **зеркало подключений**
к спортсменам. ИИ, подключённый к базе тренера, сначала берёт список
спортсменов одним RPC, потом сам читает дневник нужного спортсмена в его
проекте по share-токену. Google Диск не участвует.

SQL: [`docs/sql/2026-11-26-coach-athlete-links.sql`](sql/2026-11-26-coach-athlete-links.sql)
— выполнить в SQL editor **своего** проекта тренера (не спортсмена).

## Что лежит в базе тренера

Таблица `coach_athlete_links`, строка на спортсмена:

| поле | смысл |
|---|---|
| `owner_user_id` | тренер (auth.uid()), RLS: строку видит только он |
| `athlete_id` | локальный id спортсмена в приложении (`coach_athletes.id`) |
| `name` | имя для подписи в ответах ИИ |
| `supabase_url` | адрес проекта спортсмена |
| `supabase_anon_key` | публичный ключ проекта спортсмена (только чтобы постучаться в PostgREST) |
| `share_token` | токен доступа, который спортсмен выдал тренеру (чтение) |
| `token_status` | `valid` / `revoked` / `unknown` |
| `updated_at` | когда подключение последний раз записывалось |

## Замена ключей при переподключении

Ключ строки — `(owner_user_id, athlete_id)`. Приложение при каждом
подключении/переподключении спортсмена делает upsert:

```
POST {coach_url}/rest/v1/coach_athlete_links?on_conflict=owner_user_id,athlete_id
Prefer: resolution=merge-duplicates
{ "athlete_id": "...", "name": "...", "supabase_url": "...",
  "supabase_anon_key": "...", "share_token": "...", "token_status": "valid" }
```

Если спортсмен выдал новый токен, переехал на другой проект или сменил ключ —
все три поля перезаписываются одной строкой, старых значений не остаётся.
Отзыв токена помечается `token_status = 'revoked'`, чтобы ИИ не путал «нет
доступа» с «нет тренировок».

## Как читает ИИ

1. Токен доступа ИИ задаётся в `project_settings.ai_links_token` (длинная
   случайная строка). Он заменяет `service_role`: без него RPC вернёт `null`.
2. Список спортсменов:

```
POST {coach_url}/rest/v1/rpc/get_coach_athlete_links
Headers: apikey: {coach_anon}, Authorization: Bearer {coach_anon}
Body: {"p_token": "<ai_links_token>"}
```

Ответ — массив `{athlete_id, name, url, anon_key, token, status}`.

3. Дневник конкретного спортсмена (только его проект, без смешивания):

```
POST {url}/rest/v1/rpc/get_shared_packages
Headers: apikey: {anon_key}, Authorization: Bearer {anon_key}
Body: {"p_token": "<token>"}
```

Аналогично `get_shared_exercises`, `get_shared_shots`, `get_shared_comments`.

## Правила, чтобы не смешать спортсменов

- Один спортсмен — один проект: запрос всегда идёт в `url` из его строки.
- В каждом ответе ИИ сохраняет `athlete_id` и `name` рядом с данными; сводные
  таблицы помечаются именем спортсмена, а не сливаются «в кучу».
- `status != 'valid'` → сначала сказать тренеру «доступ отозван», а не «нет
  тренировок».
- Токен и ключи из ответа не пересылать в чат и не публиковать.
