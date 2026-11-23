#!/usr/bin/env node
// Загрузка файлов каталога 3D-моделей BS-Shooting в воркер
// (каталог 3D-моделей, просьба владельца 23.11).
//
// Запуск (Node 18+, ничего ставить не нужно):
//   node scripts/upload-model.mjs <адрес-воркера> <MODELS_ADMIN_TOKEN> <kind> <файл> [id]
//
//   kind: preview | glb | stp | catalog
//     preview — PNG-превью:        id обязателен (32 hex)
//     glb     — 3D-модель GLB:     id обязателен (32 hex)
//     stp     — чертёж STEP:       id обязателен (32 hex)
//     catalog — сам каталог JSON:  id НЕ нужен
//
// Примеры:
//   node scripts/upload-model.mjs https://pusl-calls.<двор>.workers.dev $TOKEN preview 7f3a...b1.png 7f3a12...
//   node scripts/upload-model.mjs https://pusl-calls.<двор>.workers.dev $TOKEN catalog catalog.json
//
// Каталог (catalog.json) — тот JSON, что приложение читает с /models/index:
//   {
//     "updatedAt": "2025-11-23T12:00:00Z",
//     "items": [
//       { "id": "7f3a12...", "name": "Мишень ISSF", "category": "Мишени",
//         "sizeBytes": 184320, "hasStep": true }
//     ]
//   }
//   id — 32 hex-символа (128 бит); sizeBytes — байт model.glb; hasStep — есть
//   ли model.stp. Порядок загрузки: превью/модель/STEP → затем catalog.json.
// Воркер шифрует и кладёт файлы в R2 сам: ключи MODELS_KEY скрипту не нужны.

import { readFileSync } from 'node:fs';

const [base, token, kind, file, id = ''] = process.argv.slice(2);
if (!base || !token || !kind || !file) {
  console.error('Использование: node scripts/upload-model.mjs <адрес-воркера> <токен> <preview|glb|stp|catalog> <файл> [id]');
  process.exit(1);
}
if (kind !== 'catalog' && !/^[0-9a-f]{32}$/.test(id)) {
  console.error('Для ' + kind + ' нужен id — 32 hex-символа (128 бит).');
  process.exit(1);
}

const data = readFileSync(file);
const form = new FormData();
form.append('kind', kind);
if (kind !== 'catalog') form.append('id', id);
form.append('data', new Blob([data]), kind + '.bin');

const res = await fetch(base.replace(/\/+$/, '') + '/models/upload', {
  method: 'POST',
  headers: { 'x-admin-token': token },
  body: form,
});
const text = await res.text();
if (res.ok) console.log('OK', kind, kind === 'catalog' ? '' : id, '→', text);
else {
  console.error('Ошибка', res.status, text);
  process.exit(1);
}
