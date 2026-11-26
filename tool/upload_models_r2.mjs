// Загрузка каталога 3D-моделей в R2 через воркер звонков.
//
// Зачем: файлы моделей не должны лежать в публичном репозитории. Воркер
// хранит их в R2 зашифрованными и отдаёт приложению по адресу
// /models/<id>/model.stp. Загружать может только владелец — по админ-токену.
//
// Запуск (Node 18+):
//   set MODELS_ADMIN_TOKEN=...        (Windows PowerShell: $env:MODELS_ADMIN_TOKEN="...")
//   node tool/upload_models_r2.mjs
//
// Переменные:
//   MODELS_ADMIN_TOKEN — секрет воркера MODELS_ADMIN_TOKEN (обязателен);
//   WORKER_URL         — по умолчанию https://pusl-calls.pusl-calls.workers.dev;
//   MODELS_DIR         — папка с исходными .stp (по умолчанию
//                        C:\Users\Admin\Downloads\models_stp);
//   CONCURRENCY        — сколько файлов грузить параллельно (по умолчанию 2).
//
// Скрипт идемпотентный: повторная загрузка перезаписывает объект.

import { readFile, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';

const WORKER = process.env.WORKER_URL || 'https://pusl-calls.pusl-calls.workers.dev';
const TOKEN = process.env.MODELS_ADMIN_TOKEN || '';
const DIR = process.env.MODELS_DIR || 'C:\\Users\\Admin\\Downloads\\models_stp';
const CONCURRENCY = Number(process.env.CONCURRENCY || 2);

if (!TOKEN) {
  console.error('Нет MODELS_ADMIN_TOKEN. Задай переменную окружения и повтори.');
  process.exit(1);
}
if (!existsSync(DIR)) {
  console.error(`Нет папки с моделями: ${DIR}`);
  process.exit(1);
}

const catalogPath = new URL('../assets/models/catalog.json', import.meta.url);
const catalog = JSON.parse(await readFile(catalogPath, 'utf8'));
const items = catalog.items || [];

async function uploadOne(item, index, total) {
  const file = path.join(DIR, `${item.id}.stp`);
  if (!existsSync(file)) return { id: item.id, error: 'нет файла' };
  const bytes = await readFile(file);
  const form = new FormData();
  form.set('kind', 'stp');
  form.set('id', item.id);
  form.set('data', new Blob([bytes], { type: 'application/octet-stream' }), `${item.id}.stp`);

  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await fetch(`${WORKER}/models/upload`, {
        method: 'POST',
        headers: { 'x-admin-token': TOKEN },
        body: form,
      });
      if (res.ok) {
        console.log(`[${index}/${total}] ok ${item.id} (${(bytes.length / 1048576).toFixed(1)} МБ)`);
        return { id: item.id, ok: true };
      }
      const text = await res.text().catch(() => '');
      if (attempt === 3) {
        console.error(`[${index}/${total}] ошибка ${res.status} ${item.id}: ${text.slice(0, 120)}`);
        return { id: item.id, error: `${res.status}` };
      }
    } catch (e) {
      if (attempt === 3) {
        console.error(`[${index}/${total}] сеть ${item.id}: ${e.message}`);
        return { id: item.id, error: e.message };
      }
    }
    await new Promise((r) => setTimeout(r, 1000 * attempt));
  }
  return { id: item.id, error: 'unknown' };
}

const queue = items.map((item, i) => ({ item, i }));
const total = queue.length;
let done = 0;
const failures = [];

async function worker() {
  while (queue.length) {
    const next = queue.shift();
    if (!next) break;
    const res = await uploadOne(next.item, ++done, total);
    if (res.error) failures.push(res);
  }
}

await Promise.all(Array.from({ length: Math.max(1, Math.min(4, CONCURRENCY)) }, worker));

// Каталог (для /models/index) — необязательно, но пусть лежит рядом.
try {
  const catForm = new FormData();
  catForm.set('kind', 'catalog');
  catForm.set('data', new Blob([JSON.stringify(catalog)], { type: 'application/json' }), 'catalog.json');
  const res = await fetch(`${WORKER}/models/upload`, {
    method: 'POST',
    headers: { 'x-admin-token': TOKEN },
    body: catForm,
  });
  console.log(res.ok ? 'каталог загружен' : `каталог: ошибка ${res.status}`);
} catch (e) {
  console.warn('каталог не загружен:', e.message);
}

console.log(`\nГотово: ${total - failures.length} из ${total}.`);
if (failures.length) {
  console.log('Не удалось:', failures.map((f) => f.id).join(', '));
  process.exitCode = 1;
}
