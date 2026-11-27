// Автоматический перенос моделей из Google Диска в R2 (27.11).
//
// Владелец обновляет папку моделей на Диске — воркер дважды в день
// (cron 04:00/16:00 UTC) сам забирает новые и изменённые .stp в приватный R2,
// обновляет каталог /models/index, и приложение видит новинки без пересборки.
//
// Нужны два секрета воркера:
//   GOOGLE_SA_JSON        — JSON сервисного аккаунта Google (весь файл);
//   GDRIVE_MODELS_FOLDER  — id папки моделей (по умолчанию папка каталога).
// Папка должна быть расшарена сервисному аккаунту на просмотр.

import type { Env } from './index';
import { sealModels, readModel } from './models';

const ROOT_FOLDER = '1jctM_rUtijeK3ts8lPUfRW5NSzT88VFO'; // catalog.json rootId
const MAX_UPLOAD_PER_RUN = 60; // столько файлов за один запуск, остальное — следующим
const MAX_FILE_BYTES = 64 * 1024 * 1024;

type DriveFile = {
  id: string;
  name: string;
  mimeType: string;
  size?: string;
  md5Checksum?: string;
  modifiedTime?: string;
};

type SyncState = { files: Record<string, { md5: string; size: number; path: string; name: string }> };

const enc = new TextEncoder();

function b64url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function b64urlText(text: string): string {
  return b64url(enc.encode(text));
}

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function googleToken(env: Env): Promise<string | null> {
  const raw = env.GOOGLE_SA_JSON;
  if (!raw) return null;
  let sa: { client_email?: string; private_key?: string };
  try {
    sa = JSON.parse(raw);
  } catch {
    console.error('gdrive: GOOGLE_SA_JSON не JSON');
    return null;
  }
  if (!sa.client_email || !sa.private_key) {
    console.error('gdrive: в ключе нет client_email/private_key');
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  const header = b64urlText(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64urlText(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/drive.readonly',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));
  const payload = `${header}.${claim}`;
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(sa.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(payload)));
  const assertion = `${payload}.${b64url(sig)}`;
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!res.ok) {
    console.error('gdrive: токен не получен', res.status, (await res.text()).slice(0, 200));
    return null;
  }
  const body = (await res.json()) as { access_token?: string };
  return body.access_token ?? null;
}

async function listFolder(token: string, folderId: string): Promise<DriveFile[]> {
  const out: DriveFile[] = [];
  let pageToken = '';
  for (;;) {
    const params = new URLSearchParams({
      q: `'${folderId}' in parents and trashed=false`,
      fields: 'nextPageToken,files(id,name,mimeType,size,md5Checksum,modifiedTime)',
      pageSize: '1000',
      supportsAllDrives: 'true',
      includeItemsFromAllDrives: 'true',
    });
    if (pageToken) params.set('pageToken', pageToken);
    const res = await fetch(`https://www.googleapis.com/drive/v3/files?${params}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    if (!res.ok) {
      console.error('gdrive: список не получен', res.status, (await res.text()).slice(0, 200));
      break;
    }
    const body = (await res.json()) as { files?: DriveFile[]; nextPageToken?: string };
    out.push(...(body.files ?? []));
    if (!body.nextPageToken) break;
    pageToken = body.nextPageToken;
  }
  return out;
}

async function downloadFile(token: string, id: string): Promise<Uint8Array | null> {
  const res = await fetch(
    `https://www.googleapis.com/drive/v3/files/${id}?alt=media&supportsAllDrives=true`,
    { headers: { authorization: `Bearer ${token}` } },
  );
  if (!res.ok) {
    console.error('gdrive: файл не скачался', id, res.status);
    return null;
  }
  return new Uint8Array(await res.arrayBuffer());
}

/**
 * Основная синхронизация. Идемпотентна: уже перенесённые файлы не трогает,
 * сверяя md5. Ошибки логирует и возвращает статистику.
 */
export async function syncModelsFromDrive(env: Env): Promise<{ files: number; uploaded: number; skipped: number }> {
  const token = await googleToken(env);
  if (!token) return { files: 0, uploaded: 0, skipped: 0 };

  const rootId = (env.GDRIVE_MODELS_FOLDER || '').trim() || ROOT_FOLDER;

  // 1. Обойти дерево папок и собрать .stp/.step с путями.
  const stack: Array<{ id: string; prefix: string }> = [{ id: rootId, prefix: '' }];
  const files: Array<{ file: DriveFile; path: string }> = [];
  let visited = 0;
  while (stack.length && visited < 300) {
    visited++;
    const cur = stack.pop()!;
    for (const f of await listFolder(token, cur.id)) {
      if (f.mimeType === 'application/vnd.google-apps.folder') {
        stack.push({ id: f.id, prefix: cur.prefix ? `${cur.prefix}/${f.name}` : f.name });
      } else if (/\.(stp|step)$/i.test(f.name)) {
        files.push({ file: f, path: cur.prefix ? `${cur.prefix}/${f.name}` : f.name });
      }
    }
  }
  if (files.length === 0) return { files: 0, uploaded: 0, skipped: 0 };

  // 2. Состояние переноса и текущий каталог.
  let state: SyncState = { files: {} };
  try {
    const rawState = await env.MEDIA.get('models/sync.json');
    if (rawState) state = JSON.parse(await rawState.text()) as SyncState;
  } catch {
    // битое состояние — начинаем заново, файлы просто перезальются
  }
  let catalog: { items?: Array<Record<string, unknown>>; updatedAt?: string } = {};
  try {
    const body = await readModel(env, 'models/catalog.json');
    if (body) catalog = JSON.parse(new TextDecoder().decode(body));
  } catch {
    // нет каталога — соберём новый
  }
  const items = Array.isArray(catalog.items) ? catalog.items : [];
  const byId = new Map<string, Record<string, unknown>>();
  for (const it of items) {
    if (it && typeof it.id === 'string') byId.set(it.id, it);
  }

  // 3. Перенести новые/изменённые, но не больше лимита за запуск.
  let uploaded = 0;
  let skipped = 0;
  for (const { file, path } of files) {
    const size = Number(file.size ?? 0);
    const md5 = file.md5Checksum ?? `${size}:${file.modifiedTime ?? ''}`;
    const prev = state.files[file.id];
    if (prev && prev.md5 === md5 && byId.has(file.id)) continue;
    if (size > MAX_FILE_BYTES) {
      console.warn('gdrive: пропуск большого файла', file.name, size);
      continue;
    }
    if (uploaded >= MAX_UPLOAD_PER_RUN) {
      skipped++;
      continue;
    }
    const bytes = await downloadFile(token, file.id);
    if (!bytes) continue;
    await env.MEDIA.put(`models/${file.id}/model.stp`, await sealModels(env, bytes));
    state.files[file.id] = { md5, size: bytes.length, path, name: file.name };
    uploaded++;

    const stem = file.name.replace(/\.(stp|step)$/i, '');
    const parts = path.split('/');
    const category = parts.length > 1 ? parts[0] : 'Модели';
    const entry = byId.get(file.id) ?? {
      id: file.id,
      name: stem,
      fileName: file.name,
      category,
      path,
      order: items.length,
    };
    entry.fileName = file.name;
    entry.category = category;
    entry.path = path;
    if (!byId.has(file.id)) items.push(entry);
    byId.set(file.id, entry);
  }

  // 4. Сохранить состояние и каталог (только если что-то изменилось).
  if (uploaded > 0) {
    await env.MEDIA.put('models/sync.json', JSON.stringify(state));
    catalog.items = items;
    catalog.updatedAt = new Date().toISOString();
    const cat = enc.encode(JSON.stringify(catalog));
    await env.MEDIA.put('models/catalog.json', await sealModels(env, cat));
    console.log('gdrive: перенесено', uploaded, 'файлов; каталог обновлён');
  }
  return { files: files.length, uploaded, skipped };
}
