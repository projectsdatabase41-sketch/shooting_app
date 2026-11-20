// Сервер звонков Pusl (Cloudflare Worker + Durable Objects). Supabase не
// участвует: пользователь проверяется по подписи его токена входа в
// мессенджер (открытый ключ ES256 из JWKS чат-базы), сам разговор идёт
// напрямую между телефонами (WebRTC), здесь — только «знакомство».
//
//   POST /register        {token}                  — FCM-токен устройства (для входящих)
//   GET  /ice                                      — STUN/TURN для WebRTC (временные доступы)
//   POST /call            {callId, to, name, video} — позвонить: push «входящий звонок»
//   POST /task-push       {kind: 'call'|'done'|'new'|…} — вызов тренера и push заданий (без мессенджера)
//   POST /cancel          {callId, to}             — отменить исходящий
//   GET  /room/<callId>?token=…  (WebSocket)       — обмен offer/answer/ice/hangup
//
// Секреты (wrangler secret put …): FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY,
// FIREBASE_PROJECT_ID; TURN — либо Cloudflare (TURN_KEY_ID, TURN_KEY_API_TOKEN),
// либо Metered (METERED_ICE_URL — адрес выдачи доступов вместе с ключом).

export interface Env {
  ROOMS: DurableObjectNamespace;
  USERS: DurableObjectNamespace;
  JWKS_URL: string;
  FIREBASE_CLIENT_EMAIL: string;
  FIREBASE_PRIVATE_KEY: string;
  FIREBASE_PROJECT_ID: string;
  TURN_KEY_ID: string;
  TURN_KEY_API_TOKEN: string;
  /** Metered TURN: https://<app>.metered.live/api/v1/turn/credentials?apiKey=… */
  METERED_ICE_URL: string;
  USAGE: DurableObjectNamespace;
  /** Порог трафика через ретранслятор в месяц, после которого TURN не выдаём. */
  CF_TURN_LIMIT_GB: string;
  METERED_LIMIT_MB: string;
  /** Ключи OpenRouter через запятую: приложение их больше не знает. */
  OPENROUTER_KEYS: string;
  /** Токен для админской сводки (плагин DSH читает расход TURN и R2). */
  ADMIN_TOKEN: string;
  /** Ключи Tavily через запятую: поиск в интернете для ИИ. */
  TAVILY_KEYS: string;
  /** iLoveAPI: публичный ключ проекта (секретный — для расшифровки JWT). */
  ILOVEPDF_PUBLIC_KEY: string;
  /** RSS-источники новостей через запятую. */
  NEWS_FEEDS: string;
  /** Ключевые слова для фильтра новостей через запятую. */
  NEWS_KEYWORDS: string;
  /** Медиа чата (зашифрованные на устройстве) — приватный бакет R2. */
  MEDIA: R2Bucket;
  MEDIA_LIMIT_GB: string;
  MEDIA_USER_LIMIT_MB: string;
  MEDIA_MAX_OBJECT_MB: string;
}

const MAX_PEERS = 4; // напрямую (mesh) больше 4 не потянет
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...cors } });

// ---------- проверка токена входа (ES256, JWKS чат-базы) ----------

const b64urlToBytes = (s: string) => {
  const b = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
};

let jwksCache: { keys: Record<string, CryptoKey>; at: number } | null = null;

async function jwk(env: Env, kid: string): Promise<CryptoKey | undefined> {
  if (!jwksCache || Date.now() - jwksCache.at > 3600_000 || !jwksCache.keys[kid]) {
    const res = await fetch(env.JWKS_URL);
    const { keys } = (await res.json()) as { keys: JsonWebKey[] };
    const out: Record<string, CryptoKey> = {};
    for (const k of keys) {
      if (k.kty !== 'EC') continue;
      out[(k as unknown as { kid: string }).kid] = await crypto.subtle.importKey(
        'jwk', k, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'],
      );
    }
    jwksCache = { keys: out, at: Date.now() };
  }
  return jwksCache.keys[kid];
}

/** id пользователя мессенджера или null (подпись/срок не прошли). */
export async function verifyUser(env: Env, token: string | null): Promise<string | null> {
  if (!token) return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
    const payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
    if (header.alg !== 'ES256' || !header.kid) return null;
    if (typeof payload.exp !== 'number' || payload.exp * 1000 < Date.now()) return null;
    const key = await jwk(env, header.kid);
    if (!key) return null;
    const ok = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' }, key, b64urlToBytes(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    );
    return ok && typeof payload.sub === 'string' ? payload.sub : null;
  } catch {
    return null;
  }
}

const bearer = (req: Request) => req.headers.get('authorization')?.replace(/^Bearer\s+/i, '') ?? null;

// ---------- FCM (как в send-chat-push, без SDK) ----------

const b64url = (bytes: ArrayBuffer | Uint8Array) => {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = '';
  for (const b of arr) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

let fcmToken: { value: string; exp: number } | null = null;

async function fcmAccessToken(env: Env): Promise<string> {
  if (fcmToken && fcmToken.exp > Date.now() + 30_000) return fcmToken.value;
  const now = Math.floor(Date.now() / 1000);
  const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({ alg: 'RS256', typ: 'JWT' })}.${enc({
    iss: env.FIREBASE_CLIENT_EMAIL,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })}`;
  const pem = env.FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n')
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '');
  const key = await crypto.subtle.importKey(
    'pkcs8', Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${b64url(sig)}` }),
  });
  const j = (await res.json()) as { access_token?: string; expires_in?: number };
  if (!j.access_token) throw new Error('FCM token exchange failed');
  fcmToken = { value: j.access_token, exp: Date.now() + (j.expires_in ?? 3600) * 1000 };
  return j.access_token;
}

/** Push ДАННЫМИ с высоким приоритетом — приложение само рисует звонок. */
async function sendData(env: Env, token: string, data: Record<string, string>): Promise<boolean> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${await fcmAccessToken(env)}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: { token, data, android: { priority: 'high', ttl: '30s' } } }),
  });
  return res.ok;
}

// ---------- Задания тренера (не мессенджер) ----------

/** Адреса устройств из личной базы спортсмена (RPC Supabase). */
async function rpcTokens(db: string, key: string, auth: string, fn: string, args: Record<string, unknown>): Promise<string[]> {
  const r = await fetch(`${db}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  }).catch(() => null);
  if (!r?.ok) return [];
  const j = (await r.json().catch(() => [])) as unknown;
  if (!Array.isArray(j)) return [];
  return j
    .map((x) => (typeof x === 'string' ? x : x && typeof x === 'object' ? String(Object.values(x)[0] ?? '') : ''))
    .filter((t) => t.length > 20 && t.length < 4096);
}

/** Push задания: данные — приложение на Android рисует уведомление само; веб — уведомление FCM. */
async function sendTask(env: Env, token: string, data: Record<string, string>, title: string, body: string): Promise<boolean> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${await fcmAccessToken(env)}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: { token, data, android: { priority: 'high' }, webpush: { notification: { title, body } } },
    }),
  });
  return res.ok;
}

// ---------- Worker ----------

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
    const url = new URL(req.url);

    // ---------- Новостная лента ----------
    // Приложение читает только наш /news: один запрос на запуск, без опроса
    // RSS-источников каждым пользователем. Обновление — по расписанию.
    if (url.pathname === '/news' && req.method === 'GET') {
      const obj = await env.MEDIA.get('news/feed.json');
      if (!obj) return json({ updatedAt: null, items: [] });
      return new Response(obj.body, {
        headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=1800', ...cors },
      });
    }
    if (url.pathname === '/news/refresh' && req.method === 'POST') {
      const token = req.headers.get('x-admin-token') || '';
      if (!env.ADMIN_TOKEN || token !== env.ADMIN_TOKEN) return json({ error: 'forbidden' }, 403);
      return json(await refreshNews(env));
    }
    // ---------- Сводка диагностики (без личных данных) ----------
    // Приложение после проверки сети присылает только числа: сколько шагов
    // прошло и сколько упало. Этого хватает панели, а таблица отзывов в
    // Supabase остаётся закрытой на чтение — сервисный ключ никуда не нужен.
    if (url.pathname === '/diag' && req.method === 'POST') {
      const b = (await req.json().catch(() => ({}))) as Record<string, unknown>;
      const total = Math.max(0, Math.min(100, Number(b.total ?? 0)));
      const failed = Math.max(0, Math.min(total, Number(b.failed ?? 0)));
      const platform = String(b.platform ?? '').slice(0, 20);
      await usage.fetch('https://u/diag', {
        method: 'POST',
        body: JSON.stringify({ total, failed, platform, at: new Date().toISOString() }),
      });
      return json({ ok: true });
    }

    // Публичная сводка для боковой панели плагина: только объёмы, без токенов.
    if (url.pathname === '/stats' && req.method === 'GET') {
      const usage = env.USAGE.get(env.USAGE.idFromName('global'));
      const month = (await (await usage.fetch('https://u/get')).json()) as Record<string, number>;
      const media = (await (await usage.fetch('https://u/media?uid=')).json()) as { total: number };
      const diag = (await (await usage.fetch('https://u/diag/get')).json()) as {
        count: number;
        failed: number;
        last: Array<Record<string, unknown>>;
      };
      return json({
        month: new Date().toISOString().slice(0, 7),
        turn: {
          cloudflare: { usedBytes: month.cloudflare ?? 0, limitBytes: Number(env.CF_TURN_LIMIT_GB || 800) * 1e9 },
          metered: { usedBytes: month.metered ?? 0, limitBytes: Number(env.METERED_LIMIT_MB || 450) * 1e6 },
        },
        media: { usedBytes: media.total, limitBytes: Number(env.MEDIA_LIMIT_GB || 8) * 1e9 },
        diag: { runs: diag.count, failedRuns: diag.failed, last: (diag.last ?? []).slice(-5) },
      });
    }

    // ---------- Админская сводка (только для плагина DSH) ----------
    // Токен в заголовке x-admin-token, секрет ADMIN_TOKEN. Отдаёт расход
    // ретранслятора и объём медиа: ровно те цифры, что нужны, чтобы не
    // выйти за бесплатные лимиты.
    if (url.pathname === '/admin/stats' && req.method === 'GET') {
      const token = req.headers.get('x-admin-token') || '';
      if (!env.ADMIN_TOKEN || token !== env.ADMIN_TOKEN) return json({ error: 'forbidden' }, 403);
      const usage = env.USAGE.get(env.USAGE.idFromName('global'));
      const month = (await (await usage.fetch('https://u/get')).json()) as Record<string, number>;
      const media = (await (await usage.fetch('https://u/media?uid=')).json()) as {
        total: number;
        user: number;
      };
      return json({
        month: new Date().toISOString().slice(0, 7),
        turn: {
          cloudflare: {
            usedBytes: month.cloudflare ?? 0,
            limitBytes: Number(env.CF_TURN_LIMIT_GB || 800) * 1e9,
          },
          metered: {
            usedBytes: month.metered ?? 0,
            limitBytes: Number(env.METERED_LIMIT_MB || 450) * 1e6,
          },
        },
        media: {
          usedBytes: media.total,
          limitBytes: Number(env.MEDIA_LIMIT_GB || 8) * 1e9,
        },
      });
    }

    if (url.pathname.startsWith('/room/')) {
      const callId = url.pathname.slice('/room/'.length);
      if (!/^[0-9a-f-]{36}$/.test(callId)) return json({ error: 'bad call id' }, 400);
      if (req.headers.get('Upgrade') !== 'websocket') return json({ error: 'websocket expected' }, 426);
      const uid = await verifyUser(env, url.searchParams.get('token'));
      if (!uid) return json({ error: 'unauthorized' }, 401);
      const headers = new Headers(req.headers);
      headers.set('x-uid', uid);
      return env.ROOMS.get(env.ROOMS.idFromName(callId)).fetch(new Request(req, { headers }));
    }

    // Push заданий. Без входа в мессенджер: «новое/снято» — по токену
    // доступа тренера (проверяет база спортсмена), «выполнено» — по входу
    // спортсмена в свою же базу. Только адреса Supabase, до 10 устройств.
    // ponytail: без ограничения частоты; добавить счётчик в UsageDO, если начнут злоупотреблять.
    if (url.pathname === '/task-push' && req.method === 'POST') {
      const b = (await req.json().catch(() => ({}))) as Record<string, unknown>;
      const db = String(b.db ?? '');
      const key = String(b.key ?? '');
      const kind = String(b.kind ?? '');
      const taskId = String(b.taskId ?? '');
      if (!/^https:\/\/[a-z0-9]{8,40}\.supabase\.co$/.test(db) || !key || key.length > 2000) return json({ error: 'bad db' }, 400);
      // 'call' — вызов тренера без мессенджера (задания не нужны).
      if (kind !== 'call' && !/^[0-9a-f-]{36}$/.test(taskId)) return json({ error: 'bad task' }, 400);
      const title = String(b.title ?? '').slice(0, 120);
      const who = String(b.who ?? '').slice(0, 60);
      let tokens: string[];
      if (kind === 'done' || kind === 'call') {
        // Вход спортсмена в СВОЮ базу проверяет она сама: чужой проект
        // получит только тренеров, зарегистрированных в нём.
        tokens = await rpcTokens(db, key, String(b.jwt ?? ''), 'task_coach_targets', {});
      } else if (kind === 'new' || kind === 'removed' || kind === 'reminder') {
        tokens = await rpcTokens(db, key, key, 'task_push_targets', { p_token: String(b.token ?? '') });
      } else {
        return json({ error: 'bad kind' }, 400);
      }
      if (kind === 'call') {
        let sentCall = 0;
        for (const t of tokens.slice(0, 10)) {
          const ok = await sendTask(env, t, { type: 'coach_call', who }, `${who || 'Спортсмен'}: вызывает вас`, 'Нужна помощь тренера');
          if (ok) sentCall++;
        }
        return json({ sent: sentCall });
      }
      const heading = kind === 'done' ? `${who || 'Спортсмен'}: задание выполнено` : kind === 'removed' ? 'Задание снято тренером' : 'Новое задание';
      let sent = 0;
      for (const t of tokens.slice(0, 10)) {
        if (await sendTask(env, t, { type: 'task', kind, task_id: taskId, title, who }, heading, title)) sent++;
      }
      return json({ sent });
    }

    const uid = await verifyUser(env, bearer(req));
    if (!uid) return json({ error: 'unauthorized' }, 401);

    // ---------- Поиск в интернете (Tavily) ----------
    // Только для вошедших: ключи лежат в секрете TAVILY_KEYS и в приложение
    // не попадают. Наружу отдаём отфильтрованное: короткий ответ и 5
    // результатов по 400 символов — иначе контекст модели раздувается.
    // Результат кладём в R2 на сутки, повторный тот же запрос бесплатен.
    if (url.pathname === '/search' && req.method === 'POST') {
      const body = (await req.json().catch(() => ({}))) as { query?: string; fresh?: boolean };
      const query = String(body.query ?? '').trim().slice(0, 300);
      if (query.length < 2) return json({ error: 'bad query' }, 400);
      const keys = (env.TAVILY_KEYS || '')
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s.startsWith('tvly-'));
      if (keys.length === 0) return json({ error: 'search not configured' }, 503);
      const hashBuf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(query.toLowerCase()));
      const keyHex = [...new Uint8Array(hashBuf)].map((b) => b.toString(16).padStart(2, '0')).join('');
      const cacheKey = `search/${keyHex.slice(0, 32)}.json`;
      if (!body.fresh) {
        const cached = await env.MEDIA.get(cacheKey);
        if (cached && Date.now() - new Date(cached.uploaded).getTime() < 24 * 3600 * 1000) {
          return new Response(cached.body, { headers: { 'content-type': 'application/json', ...cors } });
        }
      }
      const key = keys[Math.floor(Math.random() * keys.length)];
      let payload: Record<string, unknown> = {};
      try {
        const res = await fetch('https://api.tavily.com/search', {
          method: 'POST',
          headers: { 'content-type': 'application/json', Authorization: `Bearer ${key}` },
          body: JSON.stringify({
            query,
            search_depth: 'basic',
            max_results: 5,
            include_answer: true,
            include_raw_content: false,
          }),
        });
        payload = (await res.json().catch(() => ({}))) as Record<string, unknown>;
        if (!res.ok) {
          const detail = (payload as { detail?: unknown }).detail;
          const msg = typeof detail === 'string' ? detail : JSON.stringify(detail ?? `HTTP ${res.status}`);
          return json({ error: msg.slice(0, 200) }, res.status);
        }
      } catch (e) {
        return json({ error: `search failed: ${e}` }, 502);
      }
      const results = Array.isArray(payload.results) ? (payload.results as Array<Record<string, unknown>>) : [];
      const compact = {
        query,
        answer: String(payload.answer ?? '').slice(0, 900),
        results: results.slice(0, 5).map((r) => ({
          title: String(r.title ?? '').slice(0, 140),
          url: String(r.url ?? ''),
          content: String(r.content ?? '').replace(/\s+/g, ' ').slice(0, 400),
        })),
      };
      await env.MEDIA.put(cacheKey, JSON.stringify(compact), { customMetadata: { query: query.slice(0, 100) } });
      return json(compact);
    }

    const usage = env.USAGE.get(env.USAGE.idFromName('global'));
    const used = async () => (await (await usage.fetch('https://u/get')).json()) as Record<string, number>;

    // ---------- PDF-инструменты (iLoveAPI) ----------
    // Ключ проекта живёт в секрете ILOVEPDF_PUBLIC_KEY, в приложение не
    // попадает. Клиент кладёт файл в /pdf/upload (R2), просит /pdf/run с
    // задачей и забирает результат через /pdf/result. Пока ключа нет —
    // честный 503, интерфейс показывает «модуль не настроен».
    if (url.pathname === '/pdf/upload' && req.method === 'POST') {
      const name = (req.headers.get('x-file-name') || 'file').slice(0, 120);
      const len = Number(req.headers.get('content-length') || 0);
      if (!(len > 0) || len > 30e6) return json({ error: 'too large' }, 413);
      const id = crypto.randomUUID();
      await env.MEDIA.put(`pdf-tmp/${uid}/${id}/${name}`, req.body);
      return json({ id, name, bytes: len });
    }
    if (url.pathname === '/pdf/run' && req.method === 'POST') {
      const publicKeys = (env.ILOVEPDF_PUBLIC_KEY || '')
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s.startsWith('project_public_'));
      if (publicKeys.length === 0) return json({ error: 'pdf not configured' }, 503);
      const body = (await req.json().catch(() => ({}))) as {
        tool?: string;
        files?: Array<{ id: string; name: string }>;
        options?: Record<string, unknown>;
      };
      const tool = String(body.tool ?? '');
      const allowed = new Set([
        'merge', 'split', 'compress', 'officepdf', 'htmlpdf', 'pdfa', 'imagepdf',
        'pdfjpg', 'pagenumber', 'watermark', 'rotate', 'repair', 'protect',
        'unlock', 'validate', 'unpack', 'splitsmart', 'editpdf', 'ocr',
      ]);
      if (!allowed.has(tool)) return json({ error: 'unknown tool' }, 400);
      const files = Array.isArray(body.files) ? body.files.slice(0, 10) : [];
      if (files.length === 0) return json({ error: 'no files' }, 400);
      try {
        // Ключей может быть несколько (разные аккаунты): берём случайный, а
        // при отказе пробуем следующий — так лимит одного проекта не
        // останавливает работу.
        let token = '';
        for (let i = 0; i < publicKeys.length && token === ''; i++) {
          const key = publicKeys[(Math.floor(Math.random() * publicKeys.length) + i) % publicKeys.length];
          const authRes = await fetch('https://api.ilovepdf.com/v1/auth', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ public_key: key }),
          });
          const auth = (await authRes.json().catch(() => ({}))) as { token?: string };
          if (authRes.ok && auth.token) token = auth.token;
        }
        if (token === '') return json({ error: 'pdf auth failed' }, 502);
        const startRes = await fetch(`https://api.ilovepdf.com/v1/start/${tool}`, {
          method: 'GET',
          headers: { Authorization: `Bearer ${token}` },
        });
        const start = (await startRes.json().catch(() => ({}))) as { server?: string; task?: string };
        if (!startRes.ok || !start.server || !start.task) return json({ error: 'pdf start failed' }, 502);
        const uploaded: Array<{ server_filename: string; filename: string }> = [];
        for (const f of files) {
          const obj = await env.MEDIA.get(`pdf-tmp/${uid}/${f.id}/${f.name}`);
          if (!obj) return json({ error: 'file lost' }, 404);
          const buf = await obj.arrayBuffer();
          const form = new FormData();
          form.append('task', start.task);
          form.append('file', new Blob([buf]), f.name);
          const upRes = await fetch(`https://${start.server}/v1/upload`, {
            method: 'POST',
            headers: { Authorization: `Bearer ${token}` },
            body: form,
          });
          const up = (await upRes.json().catch(() => ({}))) as { server_filename?: string };
          if (!upRes.ok || !up.server_filename) return json({ error: 'pdf upload failed' }, 502);
          uploaded.push({ server_filename: up.server_filename, filename: f.name });
        }
        const procRes = await fetch(`https://${start.server}/v1/process`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}`, 'content-type': 'application/json' },
          body: JSON.stringify({ task: start.task, tool, files: uploaded, ...(body.options ?? {}) }),
        });
        if (!procRes.ok) return json({ error: 'pdf process failed' }, 502);
        const dlRes = await fetch(`https://${start.server}/v1/download/${start.task}`, {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (!dlRes.ok) return json({ error: 'pdf download failed' }, 502);
        const outId = crypto.randomUUID();
        await env.MEDIA.put(`pdf-out/${uid}/${outId}`, await dlRes.arrayBuffer());
        for (const f of files) await env.MEDIA.delete(`pdf-tmp/${uid}/${f.id}/${f.name}`);
        // Задачу на стороне iLoveAPI отдельно не удаляем: у них свой срок
        // хранения, а лишний запрос только тратит квоту.
        return json({ id: outId, name: `${tool}.pdf` });
      } catch (e) {
        return json({ error: `pdf failed: ${e}` }, 502);
      }
    }
    if (url.pathname.startsWith('/pdf/result/') && req.method === 'GET') {
      const id = url.pathname.slice('/pdf/result/'.length);
      if (!/^[0-9a-f-]{36}$/.test(id)) return json({ error: 'bad id' }, 400);
      const obj = await env.MEDIA.get(`pdf-out/${uid}/${id}`);
      if (!obj) return json({ error: 'not found' }, 404);
      return new Response(obj.body, {
        headers: { 'content-type': 'application/octet-stream', 'cache-control': 'private, max-age=600', ...cors },
      });
    }

    // ---------- Медиа чата: приватный R2, содержимое уже зашифровано ----------
    // Клиент шифрует файл на устройстве (AES-256-GCM) и присылает только
    // шифротекст: ни Cloudflare, ни база чата открытый файл не видят.
    // Квоты считаем здесь, чтобы нельзя было выйти за бесплатные 10 ГБ:
    // потолок MEDIA_LIMIT_GB=8 ГБ на бакет и MEDIA_USER_LIMIT_MB на человека
    // в месяц. При исчерпании клиент молча уходит на старый путь (через базу).
    const mediaTotalLimit = Number(env.MEDIA_LIMIT_GB || 8) * 1e9;
    const mediaUserLimit = Number(env.MEDIA_USER_LIMIT_MB || 1024) * 1e6;
    const mediaMaxObject = Number(env.MEDIA_MAX_OBJECT_MB || 25) * 1e6;
    const mediaUsage = async () =>
      (await (
        await usage.fetch(`https://u/media?uid=${encodeURIComponent(uid)}`)
      ).json()) as { total: number; user: number };

    if (url.pathname === '/media/usage' && req.method === 'GET') {
      const m = await mediaUsage();
      return json({
        totalBytes: m.total,
        totalLimitBytes: mediaTotalLimit,
        userBytes: m.user,
        userLimitBytes: mediaUserLimit,
      });
    }

    // ---------- ИИ через прокси ----------
    // Приложение больше не носит ключ OpenRouter: он живёт в секрете воркера.
    // Один запрос = один вызов модели; ответ отдаём как есть (OpenAI-формат).
    if (url.pathname === '/ai' && req.method === 'POST') {
      const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
      const model = String(body.model ?? '').trim();
      if (!model || model.length > 120) return json({ error: 'bad model' }, 400);
      const messages = body.messages;
      if (!Array.isArray(messages) || messages.length === 0 || messages.length > 60) {
        return json({ error: 'bad messages' }, 400);
      }
      const keys = (env.OPENROUTER_KEYS || '')
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s.startsWith('sk-or-'));
      if (keys.length === 0) return json({ error: 'ai not configured' }, 503);
      // Ключи равноправны: разбрасываем запросы, чтобы не упираться в лимит одного.
      const key = keys[Math.floor(Math.random() * keys.length)];
      const aiRes = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${key}`,
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://github.com/shooting-app',
          'X-Title': 'Shooting App',
        },
        body: JSON.stringify({
          model,
          messages,
          max_tokens: body.max_tokens ?? 4000,
          temperature: body.temperature ?? 0.3,
          reasoning: body.reasoning ?? { exclude: false },
        }),
      });
      const text = await aiRes.text();
      return new Response(text, {
        status: aiRes.status,
        headers: { 'content-type': 'application/json', ...cors },
      });
    }

    if (url.pathname === '/media/upload' && req.method === 'POST') {
      const key = (req.headers.get('x-media-key') || '').toLowerCase();
      if (!/^[a-f0-9]{32}$/.test(key)) return json({ error: 'bad key' }, 400);
      const len = Number(req.headers.get('content-length') || 0);
      if (!(len > 0) || len > mediaMaxObject) return json({ error: 'too large' }, 413);
      const m = await mediaUsage();
      if (m.total + len > mediaTotalLimit || m.user + len > mediaUserLimit) {
        return json({ error: 'quota' }, 413);
      }
      const stored = await env.MEDIA.put(`m/${key}`, req.body, {
        customMetadata: { owner: uid },
      });
      if (!stored) return json({ error: 'store failed' }, 500);
      await usage.fetch('https://u/media/add', {
        method: 'POST',
        body: JSON.stringify({ uid, bytes: len }),
      });
      return json({ ok: true, key });
    }

    if (url.pathname.startsWith('/media/') && req.method === 'GET') {
      const key = url.pathname.slice('/media/'.length).toLowerCase();
      if (!/^[a-f0-9]{32}$/.test(key)) return json({ error: 'bad key' }, 400);
      const obj = await env.MEDIA.get(`m/${key}`);
      if (!obj) return json({ error: 'not found' }, 404);
      // Ключ — случайные 128 бит, известен только участникам переписки.
      return new Response(obj.body, {
        headers: { 'content-type': 'application/octet-stream', 'cache-control': 'private, max-age=3600', ...cors },
      });
    }
    const limitBytes = (p: TurnProvider) =>
      p === 'cloudflare'
        ? Number(env.CF_TURN_LIMIT_GB || 800) * 1e9
        : Number(env.METERED_LIMIT_MB || 450) * 1e6;

    if (url.pathname === '/ice' && req.method === 'GET') {
      const ice: RTCIceServerLike[] = [{ urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] }];
      // Один ретранслятор на звонок: сначала Cloudflare (больше бесплатный объём),
      // потом Metered; кто упёрся в месячный порог — пропускаем. Ни одного —
      // только прямое соединение: никогда не выходим в платный объём.
      const month = await used();
      let turnProvider: TurnProvider | null = null;
      if (env.TURN_KEY_ID && env.TURN_KEY_API_TOKEN && (month.cloudflare ?? 0) < limitBytes('cloudflare')) {
        const res = await fetch(
          `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
          {
            method: 'POST',
            headers: { Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ ttl: 3 * 3600 }),
          },
        ).catch(() => null);
        if (res?.ok) {
          ice.push(...((await res.json()) as { iceServers: RTCIceServerLike[] }).iceServers);
          turnProvider = 'cloudflare';
        }
      }
      if (!turnProvider && env.METERED_ICE_URL && (month.metered ?? 0) < limitBytes('metered')) {
        try {
          const res = await fetch(env.METERED_ICE_URL);
          if (res.ok) {
            const list = (await res.json()) as RTCIceServerLike[];
            // только TURN — STUN у нас уже есть
            ice.push(...list.filter((srv) => JSON.stringify(srv.urls).includes('turn')));
            turnProvider = 'metered';
          }
        } catch {}
      }
      return json({ iceServers: ice, turnProvider });
    }

    // Приложение сообщает, сколько прошло через ретранслятор (после звонка и
    // раз в минуту разговора) — из этого считается месячный порог.
    if (url.pathname === '/usage' && req.method === 'POST') {
      const b = (await req.json().catch(() => ({}))) as { provider?: string; bytes?: number };
      const provider = b.provider === 'cloudflare' || b.provider === 'metered' ? b.provider : null;
      const bytes = Math.floor(Number(b.bytes));
      // Больше 2 ГБ за одно сообщение — мусор (минута видео ~20 МБ).
      if (!provider || !(bytes > 0) || bytes > 2e9) return json({ error: 'bad usage' }, 400);
      await usage.fetch('https://u/add', { method: 'POST', body: JSON.stringify({ provider, bytes }) });
      return json({ ok: true });
    }

    if (url.pathname === '/usage' && req.method === 'GET') {
      const month = await used();
      return json({
        month: new Date().toISOString().slice(0, 7),
        cloudflare: { usedBytes: month.cloudflare ?? 0, limitBytes: limitBytes('cloudflare') },
        metered: { usedBytes: month.metered ?? 0, limitBytes: limitBytes('metered') },
      });
    }

    const body = req.method === 'POST' ? ((await req.json().catch(() => ({}))) as Record<string, unknown>) : {};
    const userStub = (id: string) => env.USERS.get(env.USERS.idFromName(id));

    if (url.pathname === '/register' && req.method === 'POST') {
      if (typeof body.token !== 'string' || body.token.length > 4096) return json({ error: 'bad token' }, 400);
      await userStub(uid).fetch('https://u/register', { method: 'POST', body: JSON.stringify({ token: body.token }) });
      return json({ ok: true });
    }

    if ((url.pathname === '/call' || url.pathname === '/cancel') && req.method === 'POST') {
      const to = String(body.to ?? '');
      const callId = String(body.callId ?? '');
      if (!/^[0-9a-f-]{36}$/.test(callId) || !/^[0-9a-f-]{36}$/.test(to) || to === uid) return json({ error: 'bad request' }, 400);
      const data: Record<string, string> = url.pathname === '/call'
        ? { type: 'call_in', call_id: callId, from: uid, name: String(body.name ?? '').slice(0, 60), video: body.video ? '1' : '0' }
        : { type: 'call_end', call_id: callId, from: uid };
      const r = await userStub(to).fetch('https://u/ring', { method: 'POST', body: JSON.stringify(data) });
      return json(await r.json());
    }

    return json({ error: 'not found' }, 404);
  },

  // Обновление новостной ленты по расписанию (см. [triggers] в wrangler.toml).
  // RSS-источники дёргаются только здесь, а приложение читает наш /news,
  // поэтому лимиты источников не зависят от числа пользователей.
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(refreshNews(env));
  },
};

type RTCIceServerLike = { urls: string | string[]; username?: string; credential?: string };
type TurnProvider = 'cloudflare' | 'metered';

// ---------- Учёт трафика через ретранслятор (по месяцам) ----------

export class UsageDO {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(req: Request): Promise<Response> {
    const month = new Date().toISOString().slice(0, 7); // «2026-09» — новый месяц = чистый счётчик
    const key = (p: string) => `${month}:${p}`;
    const url = new URL(req.url);
    // Медиа: общий объём бакета (не месячный — он не сбрасывается) и лимит
    // пользователя за текущий месяц.
    if (url.pathname === '/media') {
      const uid = url.searchParams.get('uid') || '';
      return Response.json({
        total: (await this.state.storage.get<number>('media:total')) ?? 0,
        user: (await this.state.storage.get<number>(key(`media:${uid}`))) ?? 0,
      });
    }
    if (url.pathname === '/media/add') {
      const { uid, bytes } = (await req.json()) as { uid: string; bytes: number };
      const total = (await this.state.storage.get<number>('media:total')) ?? 0;
      const user = (await this.state.storage.get<number>(key(`media:${uid}`))) ?? 0;
      await this.state.storage.put('media:total', total + bytes);
      await this.state.storage.put(key(`media:${uid}`), user + bytes);
      return Response.json({ ok: true });
    }
    // Диагностика сети: только числа, без текстов и имён.
    if (url.pathname === '/diag') {
      const { total, failed, platform, at } = (await req.json()) as {
        total: number;
        failed: number;
        platform: string;
        at: string;
      };
      const runs = ((await this.state.storage.get<number>(key('diag:runs'))) ?? 0) + 1;
      const failedRuns = ((await this.state.storage.get<number>(key('diag:fail'))) ?? 0) + (failed > 0 ? 1 : 0);
      const last = ((await this.state.storage.get<Array<Record<string, unknown>>>(key('diag:last'))) ?? []).slice(-19);
      last.push({ at, total, failed, platform });
      await this.state.storage.put(key('diag:runs'), runs);
      await this.state.storage.put(key('diag:fail'), failedRuns);
      await this.state.storage.put(key('diag:last'), last);
      return Response.json({ ok: true });
    }
    if (url.pathname === '/diag/get') {
      return Response.json({
        count: (await this.state.storage.get<number>(key('diag:runs'))) ?? 0,
        failed: (await this.state.storage.get<number>(key('diag:fail'))) ?? 0,
        last: ((await this.state.storage.get<Array<Record<string, unknown>>>(key('diag:last'))) ?? []).slice(-5),
      });
    }
    if (url.pathname === '/add') {
      const { provider, bytes } = (await req.json()) as { provider: string; bytes: number };
      const cur = (await this.state.storage.get<number>(key(provider))) ?? 0;
      await this.state.storage.put(key(provider), cur + bytes);
      return Response.json({ ok: true });
    }
    return Response.json({
      cloudflare: (await this.state.storage.get<number>(key('cloudflare'))) ?? 0,
      metered: (await this.state.storage.get<number>(key('metered'))) ?? 0,
    });
  }
}

// ---------- Пользователь: его FCM-токены ----------

export class UserDO {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const tokens = ((await this.state.storage.get<string[]>('tokens')) ?? []);
    if (url.pathname === '/register') {
      const { token } = (await req.json()) as { token: string };
      // последние 5 устройств, новое — первым
      await this.state.storage.put('tokens', [token, ...tokens.filter((t) => t !== token)].slice(0, 5));
      return Response.json({ ok: true });
    }
    if (url.pathname === '/ring') {
      const data = (await req.json()) as Record<string, string>;
      if (tokens.length === 0) return Response.json({ delivered: 0, reason: 'no devices' });
      const results = await Promise.all(tokens.map((t) => sendData(this.env, t, data).catch(() => false)));
      return Response.json({ delivered: results.filter(Boolean).length });
    }
    return new Response('not found', { status: 404 });
  }
}

// ---------- Комната звонка: пересылка сигналов между участниками ----------

export class RoomDO {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(req: Request): Promise<Response> {
    const uid = req.headers.get('x-uid')!;
    const peers = this.state.getWebSockets();
    if (peers.length >= MAX_PEERS && !peers.some((ws) => ws.deserializeAttachment()?.uid === uid)) {
      return new Response('room full', { status: 409 });
    }
    const pair = new WebSocketPair();
    // Экономный режим (hibernation): простаивающие соединения не тратят лимит.
    this.state.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment({ uid });
    // Остальным — «вошёл такой-то»; вошедшему — кто уже в комнате.
    const present: string[] = [];
    for (const ws of peers) {
      const other = ws.deserializeAttachment()?.uid;
      if (other === uid) {
        ws.close(4000, 'replaced'); // тот же человек переподключился
        continue;
      }
      present.push(other);
      ws.send(JSON.stringify({ type: 'join', from: uid }));
    }
    pair[1].send(JSON.stringify({ type: 'peers', peers: present }));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    if (typeof raw !== 'string' || raw.length > 64_000) return;
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    const from = ws.deserializeAttachment()?.uid;
    const out = JSON.stringify({ ...msg, from });
    for (const other of this.state.getWebSockets()) {
      if (other === ws) continue;
      const to = other.deserializeAttachment()?.uid;
      if (msg.to && msg.to !== to) continue; // адресное (для группового звонка)
      try {
        other.send(out);
      } catch {}
    }
  }

  async webSocketClose(ws: WebSocket) {
    const from = ws.deserializeAttachment()?.uid;
    for (const other of this.state.getWebSockets()) {
      if (other === ws) continue;
      try {
        other.send(JSON.stringify({ type: 'leave', from }));
      } catch {}
    }
  }
}

// ---------- Новости: RSS → кэш в R2 ----------

function newsPick(block: string, tag: string): string {
  const m = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, 'i').exec(block);
  if (!m) return '';
  return newsStrip(m[1]);
}

function newsStrip(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
}

async function refreshNews(env: Env): Promise<{ items: number; sources: string[] }> {
  const feeds = (env.NEWS_FEEDS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const words = (env.NEWS_KEYWORDS || '').toLowerCase().split(',').map((s) => s.trim()).filter(Boolean);
  const items: Array<{ title: string; link: string; date: string; source: string; summary: string; image: string }> = [];
  for (const feed of feeds) {
    try {
      const res = await fetch(feed, { headers: { 'user-agent': 'NexusNews/1.0' } });
      if (!res.ok) continue;
      const xml = await res.text();
      const host = new URL(feed).host.replace(/^www\./, '');
      const blocks = [...xml.split(/<item[\s>]/i).slice(1), ...xml.split(/<entry[\s>]/i).slice(1)];
      for (const b of blocks) {
        const title = newsPick(b, 'title');
        if (!title) continue;
        const link = newsPick(b, 'link') || (/<link[^>]+href="([^"]+)"/i.exec(b)?.[1] ?? '');
        const summary = (newsPick(b, 'description') || newsPick(b, 'summary') || newsPick(b, 'content')).slice(0, 240);
        const date = newsPick(b, 'pubDate') || newsPick(b, 'updated') || '';
        const hay = `${title} ${summary}`.toLowerCase();
        if (words.length > 0 && !words.some((w) => hay.includes(w))) continue;
        // Картинка новости: enclosure, media:content или первая <img> в тексте.
        const imgMatch =
          /<enclosure[^>]+url="([^"]+)"/i.exec(b) ??
          /<media:content[^>]+url="([^"]+)"/i.exec(b) ??
          /<img[^>]+src="([^"]+)"/i.exec(b);
        const image = imgMatch ? imgMatch[1] : '';
        items.push({ title: title.slice(0, 180), link, date, source: host, summary, image });
      }
    } catch {
      // один недоступный источник не должен останавливать остальные
    }
  }
  const seen = new Set<string>();
  const unique = items.filter((i) => {
    const k = (i.link || i.title).toLowerCase();
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
  unique.sort((a, b) => String(b.date).localeCompare(String(a.date)));
  const feed = { updatedAt: new Date().toISOString(), items: unique.slice(0, 60) };
  await env.MEDIA.put('news/feed.json', JSON.stringify(feed));
  return { items: unique.length, sources: [...new Set(unique.map((i) => i.source))] };
}
