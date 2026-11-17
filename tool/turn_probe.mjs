// Проверка TURN-сервера: делает реальную TURN-аллокацию (Allocate с
// MESSAGE-INTEGRITY), а не просто STUN Binding.
//
// Зачем: бесплатный `openrelay.metered.ca` в резерве приложения оказался
// мёртвым (домен отдаёт 192.0.2.1), и звонки за NAT не поднимались. Этот скрипт
// проверяет, живой ли сервер и принимает ли он учётные данные, — прежде чем
// закладывать его в конфиг.
//
// Запуск:
//   node tool/turn_probe.mjs turn:freestun.net:3478 free free
//   node tool/turn_probe.mjs turn:openrelay.metered.ca:80 openrelayproject openrelayproject
//
// Код выхода: 0 — аллокация удалась, 1 — нет.

import dgram from 'node:dgram';
import crypto from 'node:crypto';

const [url, user = '', pass = ''] = process.argv.slice(2);
if (!url) {
  console.error('usage: node tool/turn_probe.mjs turn:host:port [user] [pass]');
  process.exit(2);
}
const m = /^turn:(?:([^@]+)@)?([^:?]+):(\d+)/.exec(url);
if (!m) {
  console.error('bad url, expected turn:host:port');
  process.exit(2);
}
const host = m[2];
const port = Number(m[3]);

const MAGIC = 0x2112a442;
const ATTR = {
  USERNAME: 0x0006,
  MESSAGE_INTEGRITY: 0x0008,
  ERROR_CODE: 0x0009,
  REALM: 0x0014,
  NONCE: 0x001d,
  XOR_RELAYED_ADDRESS: 0x0016,
  REQUESTED_TRANSPORT: 0x0019,
};

const pad4 = (n) => (n + 3) & ~3;

function attr(type, value) {
  const len = value.length;
  const buf = Buffer.alloc(4 + pad4(len));
  buf.writeUInt16BE(type, 0);
  buf.writeUInt16BE(len, 2);
  value.copy(buf, 4);
  return buf;
}

function strAttr(type, text) {
  return attr(type, Buffer.from(text, 'utf8'));
}

function build(type, attrs, integrityKey) {
  const bodyLen = attrs.reduce((s, a) => s + a.length, 0);
  const header = Buffer.alloc(20);
  header.writeUInt16BE(type, 0);
  header.writeUInt16BE(integrityKey ? bodyLen + 24 : bodyLen, 2);
  header.writeUInt32BE(MAGIC, 4);
  crypto.randomBytes(12).copy(header, 8);
  const body = Buffer.concat(attrs);
  const msg = Buffer.concat([header, body]);
  if (!integrityKey) return msg;
  const hmac = crypto.createHmac('sha1', integrityKey).update(msg).digest();
  return Buffer.concat([msg, attr(ATTR.MESSAGE_INTEGRITY, hmac)]);
}

function parse(buf) {
  const type = buf.readUInt16BE(0);
  const len = buf.readUInt16BE(2);
  const out = [];
  let off = 20;
  while (off + 4 <= 20 + len) {
    const t = buf.readUInt16BE(off);
    const l = buf.readUInt16BE(off + 2);
    out.push({ t, v: buf.subarray(off + 4, off + 4 + l) });
    off += 4 + pad4(l);
  }
  return { type, attrs: out };
}

const codeName = (type) =>
  type === 0x0103 ? 'Allocate success' : type === 0x0113 ? 'Allocate error' : `0x${type.toString(16)}`;

async function send(socket, msg, ms = 4000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), ms);
    const onMsg = (buf) => {
      clearTimeout(timer);
      socket.off('message', onMsg);
      resolve(buf);
    };
    socket.on('message', onMsg);
    socket.send(msg, port, host, (err) => {
      if (err) {
        clearTimeout(timer);
        reject(err);
      }
    });
  });
}

const socket = dgram.createSocket('udp4');
try {
  // 1. Аллокация без авторизации: сервер должен ответить 401 с realm и nonce.
  const reqTransport = attr(ATTR.REQUESTED_TRANSPORT, Buffer.from([17, 0, 0, 0]));
  const first = parse(await send(socket, build(0x0003, [reqTransport])));
  if (first.type === 0x0103) {
    console.log(`${url}: Allocate без авторизации — сервер открыт`);
    process.exit(0);
  }
  if (first.type !== 0x0113) {
    console.log(`${url}: неожиданный ответ ${codeName(first.type)}`);
    process.exit(1);
  }
  const errAttr = first.attrs.find((a) => a.t === ATTR.ERROR_CODE);
  const errCode = errAttr ? (errAttr.v[2] & 0x07) * 100 + errAttr.v[3] : 0;
  const realm = first.attrs.find((a) => a.t === ATTR.REALM)?.v.toString('utf8') ?? '';
  const nonce = first.attrs.find((a) => a.t === ATTR.NONCE)?.v ?? Buffer.alloc(0);
  console.log(`${url}: 401? code=${errCode} realm="${realm}" nonceLen=${nonce.length}`);
  if (errCode === 0) {
    console.log(`${url}: не TURN-сервер или недоступен`);
    process.exit(1);
  }

  // 2. Аллокация с MESSAGE-INTEGRITY.
  const key = crypto.createHash('md5').update(`${user}:${realm}:${pass}`).digest();
  const second = parse(
    await send(
      socket,
      build(
        0x0003,
        [reqTransport, strAttr(ATTR.USERNAME, user), strAttr(ATTR.REALM, realm), attr(ATTR.NONCE, nonce)],
        key,
      ),
    ),
  );
  if (second.type !== 0x0103) {
    const e = second.attrs.find((a) => a.t === ATTR.ERROR_CODE);
    const code2 = e ? (e.v[2] & 0x07) * 100 + e.v[3] : 0;
    console.log(`${url}: Allocate с учёткой отклонён (${code2})`);
    process.exit(1);
  }
  const relay = second.attrs.find((a) => a.t === ATTR.XOR_RELAYED_ADDRESS);
  let relayText = 'relay-адрес не пришёл';
  if (relay && relay.v.length >= 8) {
    const p = relay.v.readUInt16BE(2) ^ (MAGIC >> 16);
    const ip = [...relay.v.subarray(4, 8)].map((b, i) => b ^ (MAGIC >> (24 - 8 * i)) & 0xff).join('.');
    relayText = `relay ${ip}:${p}`;
  }
  console.log(`${url}: OK, аллокация работает (${relayText})`);
  process.exit(0);
} catch (e) {
  console.log(`${url}: ошибка — ${e.message}`);
  process.exit(1);
} finally {
  socket.close();
}
