// Каталог 3D-моделей BS-Shooting (каталог 3D-моделей, просьба владельца 23.11).
//
// Картинка-превью для осмотра, по нажатию — 3D-модель. Всё хранится в том же
// приватном бакете R2 (binding MEDIA), что и объекты чата, по ключам:
//   models/<id>/preview.png   — картинка для осмотра;
//   models/<id>/model.glb     — сама 3D-модель;
//   models/<id>/model.stp     — чертёж STEP (опционально);
//   models/catalog.json       — сам каталог (updatedAt, items).
// id — 32 hex-символа (128 бит), приходит из каталога.
//
// Шифрование (каталог 3D-моделей, просьба владельца 23.11: «все ключи и
// ссылки не светить пользователю»): тела файлов в R2 лежат ЗАШИФРОВАННЫМИ
// AES-256-GCM секретным ключом воркера MODELS_KEY (base64 32 байта), формат
// байтов тот же, что у медиа чата на устройстве (lib/services/media_vault.dart):
// nonce(12) | ciphertext(+tag). Ключ в приложение не попадает: расшифровка
// происходит только здесь, наружу уходит уже открытый файл по публичным
// маршрутам /models/… (без токена). R2-ключи объектов наружу не отдаются.
//
// Маршруты (публичное чтение, запись — только владельцу):
//   GET    /models/index              — сам каталог (JSON), из R2 расшифрован;
//   GET    /models/<id>/preview.png   — картинка (cache 7 дней);
//   GET    /models/<id>/model.glb     — модель (cache 7 дней);
//   GET    /models/<id>/model.stp     — STEP, если загружен;
//   POST   /models/upload             — загрузка, заголовок x-admin-token;
//   DELETE /models/<id>               — удалить все объекты id, тот же токен.
//
// Catalog.json храним тоже зашифрованным MODELS_KEY: он содержит все id —
// держать перечень в открытом виде в бакете незачем, а расшифровка для
// /models/index тривиальна (файл маленький).

import type { Env } from './index';

/** Корректный id модели: ровно 32 hex-символа (128 бит). */
const ID_RE = /^[0-9a-f]{32}$/;

const jsonModel = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'x-content-type-options': 'nosniff', 'access-control-allow-origin': '*' },
  });

/** Общие заголовки ответов моделей: nosniff + открытый CORS (приложение и веб). */
const fileHeaders = (type: string, cache: string) => ({
  'content-type': type,
  'cache-control': cache,
  'x-content-type-options': 'nosniff',
  'access-control-allow-origin': '*',
});

// ---------- AES-256-GCM (MODELS_KEY) ----------

let modelsKeyCache: CryptoKey | null = null;

/** AES-ключ из секрета MODELS_KEY (base64 32 байта); кэшируем на жизнь изолята. */
async function modelsKey(env: Env): Promise<CryptoKey | null> {
  if (!env.MODELS_KEY) return null;
  if (modelsKeyCache) return modelsKeyCache;
  try {
    const raw = Uint8Array.from(atob(env.MODELS_KEY.trim()), (c) => c.charCodeAt(0));
    if (raw.length !== 32) return null; // должен быть ровно AES-256
    modelsKeyCache = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
    return modelsKeyCache;
  } catch {
    return null;
  }
}

/** Шифрует тело: nonce(12) | ciphertext(+tag) — как медиа чата (media_vault.dart). */
async function sealModels(env: Env, clear: Uint8Array): Promise<Uint8Array> {
  const key = await modelsKey(env);
  if (!key) throw new Error('MODELS_KEY not configured');
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, clear));
  const out = new Uint8Array(12 + ct.length);
  out.set(nonce, 0);
  out.set(ct, 12);
  return out;
}

/** Расшифровывает тело; null — битый формат или неверный ключ. */
async function openModels(env: Env, data: Uint8Array): Promise<Uint8Array | null> {
  const key = await modelsKey(env);
  if (!key || data.length <= 12) return null;
  try {
    return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: data.slice(0, 12) }, key, data.slice(12)));
  } catch {
    return null;
  }
}

// ---------- Загрузка (только владелец) ----------

/** Тип объекта → ключ в R2. */
const KIND_FILE: Record<string, string> = { preview: 'preview.png', glb: 'model.glb', stp: 'model.stp' };
/** Потолки размеров: AES-GCM целиком расшифровывается в памяти воркера (~128 МБ),
 * поэтому крупные модели не пропускаем — превью 10 МБ, GLB 64 МБ, STEP 32 МБ. */
const KIND_MAX: Record<string, number> = { preview: 10e6, glb: 64e6, stp: 32e6, catalog: 5e6 };

/** Владелец: сравнение токена с секретом (не строка в коде), через SHA-256 — без утечек по времени. */
async function adminOk(req: Request, env: Env): Promise<boolean> {
  const token = req.headers.get('x-admin-token') || '';
  if (!env.MODELS_ADMIN_TOKEN || !token) return false;
  const enc = new TextEncoder();
  const a = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(token)));
  const b = new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(env.MODELS_ADMIN_TOKEN)));
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** POST /models/upload: multipart или JSON {id, kind, data: base64}. */
async function modelsUpload(req: Request, env: Env): Promise<Response> {
  if (!(await adminOk(req, env))) return jsonModel({ error: 'forbidden' }, 403);
  let id = '';
  let kind = '';
  let data: Uint8Array | null = null;
  const ctype = req.headers.get('content-type') || '';
  if (ctype.includes('multipart/form-data')) {
    const form = await req.formData().catch(() => null);
    if (!form) return jsonModel({ error: 'bad request' }, 400);
    kind = String(form.get('kind') ?? '');
    id = String(form.get('id') ?? '');
    const f = form.get('data');
    if (f instanceof File) data = new Uint8Array(await f.arrayBuffer());
  } else {
    const body = (await req.json().catch(() => null)) as { id?: unknown; kind?: unknown; data?: unknown } | null;
    if (!body) return jsonModel({ error: 'bad request' }, 400);
    kind = String(body.kind ?? '');
    id = String(body.id ?? '');
    if (typeof body.data === 'string' && body.data.length > 0) {
      // base64 (голый или data-URL) → байты
      const b64 = body.data.replace(/^data:[^;,]+;base64,/, '').replace(/\s+/g, '');
      try {
        data = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      } catch {
        return jsonModel({ error: 'bad request' }, 400);
      }
    }
  }
  // kind=catalog — общий файл, id не нужен; для остальных — обязателен и строгий.
  if (!data || (!KIND_FILE[kind] && kind !== 'catalog')) return jsonModel({ error: 'bad request' }, 400);
  if (kind !== 'catalog' && !ID_RE.test(id)) return jsonModel({ error: 'bad request' }, 400);
  if (data.length === 0 || data.length > (KIND_MAX[kind] ?? 0)) return jsonModel({ error: 'bad request' }, 400);
  const r2Key = kind === 'catalog' ? 'models/catalog.json' : `models/${id}/${KIND_FILE[kind]}`;
  try {
    await env.MEDIA.put(r2Key, await sealModels(env, data));
  } catch (e) {
    // конфигурация (нет ключа) или R2: наружу без деталей, но в логе видно причину
    console.error('models upload failed', e instanceof Error ? e.message : e);
    return jsonModel({ error: 'store failed' }, 500);
  }
  // R2-ключи и адреса наружу не отдаём — только факт успеха.
  return jsonModel({ ok: true, kind, ...(kind === 'catalog' ? {} : { id }) });
}

/** DELETE /models/<id>: удалить все объекты модели. */
async function modelsDelete(req: Request, env: Env, id: string): Promise<Response> {
  if (!(await adminOk(req, env))) return jsonModel({ error: 'forbidden' }, 403);
  if (!ID_RE.test(id)) return jsonModel({ error: 'not found' }, 404); // чужой/неверный id — без деталей
  const prefix = `models/${id}/`;
  let cursor: string | undefined;
  let deleted = 0;
  do {
    const page = await env.MEDIA.list({ prefix, cursor });
    for (const o of page.objects) {
      await env.MEDIA.delete(o.key);
      deleted++;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return jsonModel({ ok: true, deleted });
}

// ---------- Публичное чтение ----------

/** Общая расшифровка файла из R2: null — нет объекта или не расшифровалось. */
async function readModel(env: Env, r2Key: string): Promise<Uint8Array | null> {
  const obj = await env.MEDIA.get(r2Key);
  if (!obj) return null;
  const sealed = new Uint8Array(await obj.arrayBuffer());
  return openModels(env, sealed);
}

/**
 * Входная точка каталога: вызывается из общего роутера (src/index.ts) для
 * любых путей /models*. Возвращает null, если путь не наш — остальные
 * маршруты воркера работают как раньше.
 */
export async function handleModels(req: Request, env: Env, url: URL): Promise<Response | null> {
  const path = url.pathname;

  // Сам каталог: {updatedAt, items:[{id, name, category, sizeBytes, hasStep}]}.
  if (path === '/models/index' && req.method === 'GET') {
    const body = await readModel(env, 'models/catalog.json');
    if (!body) return jsonModel({ updatedAt: null, items: [] }); // каталог ещё не загружен
    return new Response(body, {
      headers: fileHeaders('application/json', 'public, max-age=300'),
    });
  }

  // Файл модели: только по строгому id и одному из трёх имён.
  const file = /^\/models\/([0-9a-f]{32})\/(preview\.png|model\.glb|model\.stp)$/.exec(path);
  if (file && req.method === 'GET') {
    const [, id, fname] = file;
    const body = await readModel(env, `models/${id}/${fname}`);
    // Неверный/чужой id или ключ воркера не задан — одинаковый 404 без деталей
    // (каталог 3D-моделей, просьба владельца 23.11: без ключей и адресов R2).
    if (!body) return jsonModel({ error: 'not found' }, 404);
    const type = fname === 'preview.png' ? 'image/png' : fname === 'model.glb' ? 'model/gltf-binary' : 'application/step';
    return new Response(body, {
      headers: fileHeaders(type, 'public, max-age=604800'), // 7 дней: содержимое неизменяемое
    });
  }

  // Загрузка и удаление — только владельцу.
  if (path === '/models/upload' && req.method === 'POST') return modelsUpload(req, env);
  const del = /^\/models\/([0-9a-f]{32})$/.exec(path);
  if (del && req.method === 'DELETE') return modelsDelete(req, env, del[1]);

  // Любой другой /models/… — 404, чтобы не утекать в «unauthorized» остальных маршрутов.
  if (path === '/models' || path.startsWith('/models/')) return jsonModel({ error: 'not found' }, 404);
  return null;
}
