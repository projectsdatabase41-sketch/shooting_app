# Модели 3D в R2 (не в публичном репозитории)

Файлы моделей — платный каталог, поэтому в открытом репозитории их держать
нельзя. Они лежат в приватном R2, воркер звонков отдаёт их приложению
зашифрованными (AES-GCM, ключ в секрете `MODELS_KEY`).

## Что где

| Что | Где |
|---|---|
| Файлы моделей | R2, ключи `models/<id>/model.stp`, зашифрованы |
| Отдача приложению | `GET {worker}/models/<id>/model.stp` |
| Каталог (необязательно) | `GET {worker}/models/index` |
| Загрузка | `POST {worker}/models/upload`, заголовок `x-admin-token` |
| Секреты воркера | `MODELS_KEY` (шифрование), `MODELS_ADMIN_TOKEN` (загрузка) |

## Как загрузить (один раз)

1. В Cloudflare проверь, что у воркера `pusl-calls` заданы секреты
   `MODELS_KEY` и `MODELS_ADMIN_TOKEN` (Workers → pusl-calls → Settings →
   Variables and Secrets). Если нет — создай: `MODELS_KEY` — случайные 32
   байта в base64, `MODELS_ADMIN_TOKEN` — длинная случайная строка.
2. В PowerShell:

```powershell
$env:MODELS_ADMIN_TOKEN="твой-админ-токен"
node tool/upload_models_r2.mjs
```

Скрипт берёт список из `assets/models/catalog.json`, файлы — из
`C:\Users\Admin\Downloads\models_stp\<id>.stp`, и грузит по 2 параллельно.
Повторный запуск перезаписывает объекты, ничего не дублирует.

## Как включить в приложении

Адрес модели выбирает `DriveModelsCatalog.modelUrl`:

- `models.proxy: true` в `config/chat-config.json` → воркер `/models/<id>/model.stp`;
- иначе — прежние файлы из репозитория `server/models`.

После успешной загрузки и проверки:

1. В `config/chat-config.json` добавь `"models": { "proxy": true }`.
2. Удали папку `server/models` из репозитория и запушь — минус ~95 МБ.

## Важно про историю git

Удаление папки убирает файлы только из новых коммитов. В **истории** они
остаются, и по прямой ссылке на старый коммит их всё ещё можно скачать.
Если это критично — нужна перезапись истории с force-push (клон у всех
сломается). Решение владельца.

## Ограничения и стоимость

- Трафик R2 бесплатный, хранение 10 ГБ free (каталог ~95 МБ), запросы —
  100 000/день free у Workers.
- `GET /models/<id>/model.stp` сейчас публичный: кто знает id, скачает файл.
  Для платного доступа следующим шагом добавляется проверка входа
  (Supabase-токен, как у `/ai`) и лимит скачиваний на пользователя.

## Автосинхронизация папки моделей (27.11)

Приложение теперь берёт каталог моделей с воркера (`GET /models/index`), а
встроенный `assets/models/catalog.json` остаётся запасным вариантом без сети.
Поэтому новые модели появляются **без пересборки приложения**.

Порядок:

1. В `config/chat-config.json` должно быть `"models": {"proxy": true}`.
2. Запустить слежение за папкой моделей (Node 18+):

```powershell
$env:MODELS_ADMIN_TOKEN="твой-админ-токен"
node tool/watch_models.mjs
```

Скрипт раз в минуту смотрит `C:\Users\Admin\Downloads\models_stp`, заливает
новые и изменённые `.stp` в R2, обновляет `assets/models/catalog.json` и
загружает каталог на воркер. Один проход без слежения: `--once`.

3. Чтобы работало без открытого окна, поставь задачу в Планировщик:

```powershell
schtasks /Create /TN "Nexus models sync" /SC MINUTE /MO 10 ^
  /TR "powershell -NoProfile -Command \"$env:MODELS_ADMIN_TOKEN='ТОКЕН'; node C:\Users\Admin\Downloads\shooting_app\tool\watch_models.mjs --once\""
```

Ограничения: скрипт ничего не удаляет — убранные из папки модели остаются в
каталоге; id существующих моделей сохраняются, новым выдаётся стабильный id
из имени файла.
