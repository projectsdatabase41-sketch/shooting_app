"""Собирает единый установочный SQL личной базы спортсмена: lib/db/nexus_personal_db.sql.

Запуск из корня репозитория:  python tools/build_personal_sql.py

Состав (порядок важен: tasks.sql ссылается на share_grants из puls_install):
  1. lib/db/puls_install.sql  — тренировки, защита, notes с эмбеддингами, table_docs, проверка
  2. sql/share-policy.sql     — политики токена тренера (basic / extended)
  3. sql/tasks.sql            — задания тренера
  4. sql/task-delete.sql      — удаление заданий тренером
  5. sql/coach-chat.sql       — чат тренер ↔ спортсмен
  6. sql/coach-chat-link.sql  — связь токена тренера с мессенджером
  + итоговая проверка: список «что должно быть» → ok / нет.

Всё идемпотентно (create ... if not exists / create or replace): повторный запуск
после сбоя безопасен. Приложение копирует этот файл кнопкой «Скопировать SQL» и
проверяет результат на экране «Проверка базы» (lib/services/db_setup_check.dart —
список таблиц и функций там должен совпадать с проверкой внизу этого файла).
"""
import os

PARTS = [
    ('01 основная схема, защита, заметки, инструкции ИИ', 'lib/db/puls_install.sql'),
    ('02 политики токена тренера', 'sql/share-policy.sql'),
    ('03 задания тренера', 'sql/tasks.sql'),
    ('04 удаление заданий', 'sql/task-delete.sql'),
    ('05 чат тренер ↔ спортсмен', 'sql/coach-chat.sql'),
    ('06 связь токена тренера с мессенджером', 'sql/coach-chat-link.sql'),
]

TABLES = [
    'project_settings', 'target_faces', 'exercise_templates', 'training_packages', 'exercises', 'file_assets',
    'photo_import_jobs', 'shots', 'remote_athlete_sources', 'archived_packages', 'share_grants', 'share_events',
    'comments', 'training_notes', 'ai_conversation_summaries', 'notes', 'keepalive_log', 'table_docs',
    'tasks', 'task_stages', 'task_steps', 'task_clarifications', 'task_runs', 'task_run_steps', 'task_shots',
    'task_series_notes', 'task_events', 'task_reports', 'task_devices', 'coach_chat',
]
FUNCTIONS = [
    'list_public_tables', 'validate_share_token', 'get_share_policy', 'get_shared_table',
    'coach_create_task', 'coach_get_tasks', 'coach_delete_task', 'athlete_submit_run',
    'get_coach_chat', 'add_coach_chat',
]

HEADER = """-- ============================================================================
-- nexus_personal_db.sql — ПОЛНАЯ установка личной базы Nexus ОДНИМ файлом.
-- Собрано tools/build_personal_sql.py — руками не править (правьте исходные файлы).
--
-- Как использовать: Supabase → SQL Editor → New query → вставить ВЕСЬ файл → Run.
-- Идемпотентно: если запуск прервался или вы запустили второй раз — просто запустите
-- ещё раз, существующее не пострадает. В конце — таблица «что / есть ли».
-- ============================================================================

"""


def verify():
    t = ', '.join(f"'{x}'" for x in TABLES)
    f = ', '.join(f"'{x}'" for x in FUNCTIONS)
    return f"""

-- ============================== итоговая проверка ==============================
select 'таблица' as что, n as имя, exists (select 1 from information_schema.tables
       where table_schema = 'public' and table_name = n) as есть
from unnest(array[{t}]) as n
union all
select 'функция', n, exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
       where s.nspname = 'public' and p.proname = n)
from unnest(array[{f}]) as n
order by 1, 3, 2;
"""


def main():
    out = [HEADER]
    for title, path in PARTS:
        with open(path, encoding='utf-8') as f:
            body = f.read().rstrip() + '\n'
        out.append(f"\n-- ########## {title}  ({path}) ##########\n\n{body}")
    out.append(verify())
    with open('lib/db/nexus_personal_db.sql', 'w', encoding='utf-8', newline='\n') as f:
        f.write(''.join(out))
    print('ok', os.path.getsize('lib/db/nexus_personal_db.sql'), 'bytes')


if __name__ == '__main__':
    main()
