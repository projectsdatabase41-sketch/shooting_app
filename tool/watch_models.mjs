// Автоматическая синхронизация папки моделей с R2.
//
// Следит за папкой с .stp: новые/изменённые файлы заливает в R2 через
// воркер, обновляет assets/models/catalog.json и загружает каталог на
// воркер (/models/index). После этого новые модели видны в приложении без
// пересборки — приложение берёт каталог с воркера.
//
// Запуск (Node 18+):
//   set MODELS_ADMIN_TOKEN=...            (PowerShell: $env:MODELS_ADMIN_TOKEN="...")
//   node tool/watch_models.mjs            — следит постоянно (интервал 60 с)
//   node tool/watch_models.mjs --once     — один проход (для Планировщика задач)
//
// Переменные:
//   MODELS_ADMIN_TOKEN — секрет воркера MODELS_ADMIN_TOKEN (обязателен);
//   MODELS_DIR         — папка с моделями (по умолчанию
//                        C:\Users\Admin\Downloads\models_stp);
//   WORKER_URL         — по умолчанию https://pusl-calls.pusl-calls.workers.dev;
//   CATALOG            — путь к catalog.json (по умолчанию
//                        assets/models/catalog.json рядом с проектом);
//   INTERVAL_SEC       — период опроса в режиме слежения (60).
//
// Ничего не удаляет: пропавшие из папки модели остаются в каталоге, пока их
// не уберут вручную. Повторная заливка безопасна (объект перезаписывается).

import { readFile, writeFile, readdir, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WORKER = (process.env.WORKER_URL || 'https://pusl-calls.pusl-calls.workers.dev').replace(/\/+$/, '');
const TOKEN = process.env.MODELS_ADMIN_TOKEN || '';
const MODELS_DIR = process.env.MODELS_DIR || 'C:\\Users\\Admin\\Downloads\\models_stp';
const here = path.dirname(fileURLToPath(import.meta.url));
const CATALOG = process.env.CATALOG || path.join(here, '..', 'assets', 'models', 'catalog.json');
const STATE = path.join(MODELS_DIR, '.sync_state.json');
const INTERVAL = Math.max(15, Number(process.env.INTERVAL_SEC || 60)) * 1000;
const ONCE = process.argv.includes('--once');

if (!TOKEN) {
  console.error('Нет MODELS_ADMIN_TOKEN — задай переменную окружения.');
  process.exit(1);
}
if (!existsSync(MODELS_DIR)) {
  console.error(`Нет папки с моделями: ${MODELS_DIR}`);
  process.exit(1);
}

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

async function walk(dir, base = dir) {
  const out = [];
  for (const ent of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      out.push(...await walk(full, base));
    } else if (ent.isFile() && /\.(stp|step)$/i.test(ent.name)) {
      out.push({ full, rel: path.relative(base, full).split(path.sep).join('/') });
    }
  }
  return out;
}

function idForEntry(entry, rel, hash) {
  if (entry) return entry.id;
  // Стабильный id из имени файла: 24 hex-символа, подходит под формат воркера.
  return sha256(rel).slice(0, 24);
}

async function upload(kind, id, bytes, fileName) {
  const form = new FormData();
  form.set('kind', kind);
  if (id) form.set('id', id);
  form.set('data', new Blob([bytes], { type: 'application/octet-stream' }), fileName);
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await fetch(`${WORKER}/models/upload`, {
        method: 'POST',
        headers: { 'x-admin-token': TOKEN },
        body: form,
      });
      if (res.ok) return true;
      if (attempt === 3) {
        console.error(`  ошибка загрузки ${fileName}: HTTP ${res.status}`);
        return false;
      }
    } catch (e) {
      if (attempt === 3) {
        console.error(`  сеть ${fileName}: ${e.message}`);
        return false;
      }
    }
    await new Promise((r) => setTimeout(r, 800 * attempt));
  }
  return false;
}

let busy = false;

async function pass() {
  if (busy) return;
  busy = true;
  try {
    const state = existsSync(STATE)
      ? JSON.parse(await readFile(STATE, 'utf8'))
      : { files: {} };
    const catalog = JSON.parse(await readFile(CATALOG, 'utf8'));
    const items = Array.isArray(catalog.items) ? catalog.items : [];

    const byPath = new Map();
    for (const it of items) {
      if (it && it.fileName) byPath.set(String(it.fileName).toLowerCase(), it);
      if (it && it.path) byPath.set(String(it.path).toLowerCase(), it);
    }

    const files = await walk(MODELS_DIR);
    let uploaded = 0;
    let changedCatalog = false;

    for (const f of files) {
      const buf = await readFile(f.full);
      const hash = sha256(buf);
      const known = byPath.get(f.rel.toLowerCase());
      const prev = state.files[f.rel];
      if (prev && prev.hash === hash && known) continue;

      const id = idForEntry(known, f.rel, hash);
      const ok = await upload('stp', id, buf, path.basename(f.rel));
      if (!ok) continue;

      const stem = path.basename(f.rel).replace(/\.(stp|step)$/i, '');
      const category = path.dirname(f.rel) === '.' ? 'Модели' : path.dirname(f.rel).split('/')[0];
      const entry = known || { id, name: stem, fileName: path.basename(f.rel), category, path: f.rel, order: items.length };
      entry.id = id;
      entry.name = entry.name || stem;
      entry.fileName = path.basename(f.rel);
      entry.category = entry.category || category;
      entry.path = f.rel;
      if (entry.order == null) entry.order = items.length;
      if (!known) items.push(entry);

      state.files[f.rel] = { hash, id, size: buf.length, mtime: (await stat(f.full)).mtimeMs };
      uploaded++;
      changedCatalog = true;
      console.log(`загружено: ${f.rel} (${(buf.length / 1048576).toFixed(1)} МБ, id ${id})`);
    }

    if (changedCatalog) {
      catalog.items = items;
      catalog.updatedAt = new Date().toISOString();
      await writeFile(CATALOG, JSON.stringify(catalog, null, 2) + '\n', 'utf8');
      const catBytes = Buffer.from(JSON.stringify(catalog));
      if (!(await upload('catalog', null, catBytes, 'catalog.json'))) {
        console.error('  каталог не загрузился');
      }
    }

    await writeFile(STATE, JSON.stringify(state, null, 2) + '\n', 'utf8');
    if (uploaded || changedCatalog) console.log(`итог: ${uploaded} файлов, каталог обновлён`);
  } catch (e) {
    console.error('проход не удался:', e.message);
  } finally {
    busy = false;
  }
}

await pass();
if (!ONCE) {
  console.log(`слежу за ${MODELS_DIR} каждые ${INTERVAL / 1000} с; Ctrl+C — выход`);
  setInterval(pass, INTERVAL);
}
