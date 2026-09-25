// Сервер звонков Pusl (Cloudflare Worker + Durable Objects). Supabase не
// участвует: пользователь проверяется по подписи его токена входа в
// мессенджер (открытый ключ ES256 из JWKS чат-базы), сам разговор идёт
// напрямую между телефонами (WebRTC), здесь — только «знакомство».
//
//   POST /register        {token}                  — FCM-токен устройства (для входящих)
//   GET  /ice                                      — STUN/TURN для WebRTC (временные доступы)
//   POST /call            {callId, to, name, video} — позвонить: push «входящий звонок»
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

// ---------- Worker ----------

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
    const url = new URL(req.url);

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

    const uid = await verifyUser(env, bearer(req));
    if (!uid) return json({ error: 'unauthorized' }, 401);

    if (url.pathname === '/ice' && req.method === 'GET') {
      const ice: RTCIceServerLike[] = [{ urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] }];
      if (env.TURN_KEY_ID && env.TURN_KEY_API_TOKEN) {
        const res = await fetch(
          `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
          {
            method: 'POST',
            headers: { Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ ttl: 3 * 3600 }),
          },
        );
        if (res.ok) ice.push(...((await res.json()) as { iceServers: RTCIceServerLike[] }).iceServers);
      }
      if (env.METERED_ICE_URL) {
        try {
          const res = await fetch(env.METERED_ICE_URL);
          if (res.ok) {
            const list = (await res.json()) as RTCIceServerLike[];
            // только TURN — STUN у нас уже есть
            ice.push(...list.filter((s) => JSON.stringify(s.urls).includes('turn')));
          }
        } catch {}
      }
      return json({ iceServers: ice });
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
};

type RTCIceServerLike = { urls: string | string[]; username?: string; credential?: string };

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
