// Локальная проверка сервера звонков: node test/smoke.mjs
// Поднимает свой JWKS (как у чат-базы), `wrangler dev` против него и два
// WebSocket-клиента с подписанными ES256 токенами.
import { spawn } from 'node:child_process';
import http from 'node:http';
import { webcrypto as crypto } from 'node:crypto';

const JWKS_PORT = 8788, DEV_PORT = 8799;
const { publicKey, privateKey } = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const pub = { ...(await crypto.subtle.exportKey('jwk', publicKey)), kid: 'test-kid', alg: 'ES256' };
const jwksServer = http.createServer((req, res) => {
  // тот же сервер изображает и выдачу доступов Metered
  if (req.url.startsWith('/metered')) {
    return res.end(JSON.stringify([
      { urls: 'stun:stun.relay.metered.ca:80' },
      { urls: 'turn:global.relay.metered.ca:80', username: 'u', credential: 'c' },
    ]));
  }
  res.end(JSON.stringify({ keys: [pub] }));
}).listen(JWKS_PORT);

const b64u = (b) => Buffer.from(b).toString('base64url');
async function token(sub, { exp = Math.floor(Date.now() / 1000) + 600, kid = 'test-kid' } = {}) {
  const h = b64u(JSON.stringify({ alg: 'ES256', kid, typ: 'JWT' }));
  const p = b64u(JSON.stringify({ sub, exp }));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, new TextEncoder().encode(`${h}.${p}`));
  return `${h}.${p}.${b64u(sig)}`;
}

const dev = spawn('npx', ['wrangler', 'dev', '--port', String(DEV_PORT), '--var', `JWKS_URL:http://127.0.0.1:${JWKS_PORT}/`, '--var', `METERED_ICE_URL:http://127.0.0.1:${JWKS_PORT}/metered?apiKey=x`], { shell: true, stdio: ['ignore', 'pipe', 'pipe'] });
await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error('wrangler dev не поднялся')), 90000);
  const onData = (d) => { if (/Ready on/.test(`${d}`)) { clearTimeout(t); resolve(); } };
  dev.stdout.on('data', onData);
  dev.stderr.on('data', onData);
});

const base = `http://127.0.0.1:${DEV_PORT}`;
const A = '11111111-1111-1111-1111-111111111111', B = '22222222-2222-2222-2222-222222222222';
const callId = '33333333-3333-3333-3333-333333333333';
let failed = 0;
const ok = (c, m) => { console.log(c ? 'OK  ' : 'FAIL', m); if (!c) failed++; };

try {
  ok((await fetch(`${base}/ice`)).status === 401, 'без токена — 401');
  ok((await fetch(`${base}/ice`, { headers: { authorization: `Bearer ${await token(A, { exp: 1 })}` } })).status === 401, 'просроченный токен — 401');
  ok((await fetch(`${base}/ice`, { headers: { authorization: `Bearer ${await token(A, { kid: 'other' })}` } })).status === 401, 'чужой ключ — 401');
  const ice = await (await fetch(`${base}/ice`, { headers: { authorization: `Bearer ${await token(A)}` } })).json();
  ok(Array.isArray(ice.iceServers) && JSON.stringify(ice).includes('stun:'), 'ICE-серверы выдаются (STUN)');
  ok(JSON.stringify(ice).includes('turn:global.relay.metered.ca') && !JSON.stringify(ice).includes('stun.relay.metered'), 'TURN от Metered добавлен (без их STUN)');
  const call = await (await fetch(`${base}/call`, {
    method: 'POST', headers: { authorization: `Bearer ${await token(A)}`, 'content-type': 'application/json' },
    body: JSON.stringify({ callId, to: B, name: 'Ваня' }),
  })).json();
  ok(call.delivered === 0 && call.reason === 'no devices', 'звонок тому, у кого нет устройств — честно «не доставлено»');

  const open = async (uid) => {
    const ws = new WebSocket(`ws://127.0.0.1:${DEV_PORT}/room/${callId}?token=${await token(uid)}`);
    const inbox = [];
    ws.addEventListener('message', (e) => inbox.push(JSON.parse(e.data)));
    await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
    return { ws, inbox };
  };
  const until = async (f) => { for (let i = 0; i < 100 && !f(); i++) await new Promise((r) => setTimeout(r, 30)); return f(); };

  const a = await open(A);
  await until(() => a.inbox.length);
  ok(a.inbox[0]?.type === 'peers' && a.inbox[0].peers.length === 0, 'первый в комнате — пусто');
  const b = await open(B);
  ok(await until(() => a.inbox.some((m) => m.type === 'join' && m.from === B)), 'первый видит вход второго');
  ok(await until(() => b.inbox.some((m) => m.type === 'peers' && m.peers.includes(A))), 'второй видит, кто уже в комнате');
  a.ws.send(JSON.stringify({ type: 'offer', sdp: 'v=0...' }));
  ok(await until(() => b.inbox.some((m) => m.type === 'offer' && m.from === A && m.sdp === 'v=0...')), 'offer доходит с подписью отправителя');
  b.ws.send(JSON.stringify({ type: 'answer', sdp: 'ans', from: A }));
  ok(await until(() => a.inbox.some((m) => m.type === 'answer' && m.from === B)), 'answer доходит, подделать «from» нельзя');
  const bad = new WebSocket(`ws://127.0.0.1:${DEV_PORT}/room/${callId}?token=garbage`);
  ok(await new Promise((r) => { bad.addEventListener('error', () => r(true)); bad.addEventListener('open', () => r(false)); }), 'в комнату без токена не пускает');
  b.ws.close();
  ok(await until(() => a.inbox.some((m) => m.type === 'leave' && m.from === B)), 'выход второго виден первому');
  a.ws.close();
} finally {
  dev.kill();
  jwksServer.close();
  spawn('taskkill', ['/F', '/T', '/PID', String(dev.pid)], { shell: true });
}
console.log(failed ? `${failed} проверок не прошли` : 'Все проверки прошли');
process.exit(failed ? 1 : 0);
