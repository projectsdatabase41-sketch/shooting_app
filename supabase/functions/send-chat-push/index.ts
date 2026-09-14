// Edge Function: отправляет push через Firebase (FCM), когда в чате
// появляется новое сообщение — вызывается Database Webhook'ом Supabase
// (Dashboard → Database → Webhooks) на INSERT в chat_messages и
// chat_global_messages. Сама переписка остаётся полностью на Supabase —
// эта функция только "будит" закрытое приложение (см. lib/services/push_service.dart).
//
// Использует FCM HTTP v1 API (legacy-ключ Google полностью отключил в
// 2024 — см. Firebase Console → Project settings → Cloud Messaging,
// "Cloud Messaging API (Legacy)" там навсегда Disabled). v1 требует
// OAuth2-токен, подписанный приватным ключом сервисного аккаунта —
// здесь это сделано вручную через Web Crypto (RS256), без Admin SDK
// и без npm-зависимостей, которые в Deno утяжелили бы холодный старт.
//
// Деплой (нужно сделать вручную, у меня нет доступа к CLI/дашборду
// проекта frbptucrvmyikencyspu — это ДРУГОЙ Supabase-проект, не тот,
// что подключён к MCP в этой сессии):
//   1. supabase functions deploy send-chat-push --project-ref frbptucrvmyikencyspu
//   2. Secrets (Dashboard → Edge Functions → Manage secrets, или CLI
//      `supabase secrets set --project-ref frbptucrvmyikencyspu KEY=value`):
//        FIREBASE_CLIENT_EMAIL   — client_email из .local/firebase-service-account.json
//        FIREBASE_PRIVATE_KEY    — private_key оттуда же (весь блок,
//                                  вместе с -----BEGIN/END PRIVATE KEY-----)
//        FIREBASE_PROJECT_ID     — shooting-app-chat
//        SUPABASE_URL            — уже подставляется Supabase автоматически
//        SUPABASE_SERVICE_ROLE_KEY — тоже автоматически (project secrets)
//   3. Dashboard → Database → Webhooks → Create:
//      - таблица chat_messages, событие INSERT, URL этой функции
//      - таблица chat_global_messages, событие INSERT, тот же URL

const FIREBASE_CLIENT_EMAIL = Deno.env.get('FIREBASE_CLIENT_EMAIL') ?? '';
const FIREBASE_PRIVATE_KEY = (Deno.env.get('FIREBASE_PRIVATE_KEY') ?? '').replace(/\\n/g, '\n');
const FIREBASE_PROJECT_ID = Deno.env.get('FIREBASE_PROJECT_ID') ?? '';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// ---- OAuth2-токен для FCM v1 (JWT bearer grant, RFC 7523) ----

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = '';
  for (const b of arr) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----/, '').replace(/-----END PRIVATE KEY-----/, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
}

let cachedToken: { value: string; expiresAt: number } | null = null;

async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 30_000) return cachedToken.value;

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: FIREBASE_CLIENT_EMAIL,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64url(new TextEncoder().encode(JSON.stringify(header)))}.${base64url(new TextEncoder().encode(JSON.stringify(claims)))}`;
  const key = await importPrivateKey(FIREBASE_PRIVATE_KEY);
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const assertion = `${unsigned}.${base64url(signature)}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }),
  });
  const json = await res.json();
  if (!res.ok || !json.access_token) throw new Error(`token exchange failed: ${JSON.stringify(json)}`);
  cachedToken = { value: json.access_token, expiresAt: Date.now() + json.expires_in * 1000 };
  return json.access_token;
}

async function sendPush(token: string, title: string, body: string) {
  const accessToken = await getAccessToken();
  await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: { token, notification: { title, body } } }),
  });
}

// ---- Обработчик webhook'а ----

Deno.serve(async (req: Request) => {
  if (!FIREBASE_CLIENT_EMAIL || !FIREBASE_PRIVATE_KEY || !FIREBASE_PROJECT_ID || !SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return new Response('not configured', { status: 500 });
  }

  const payload = await req.json();
  const row = payload.record;
  if (!row) return new Response('ok');

  // chat_messages (личное) — получатель известен напрямую;
  // chat_global_messages (общий чат) — уведомляем всех, кроме автора.
  const isGlobal = payload.table === 'chat_global_messages';
  const senderId = row.sender_id as string;

  // edit/delete — служебные сигналы к уже отправленному сообщению (см.
  // ChatSyncService.editMessage/deleteMessage), не новые сообщения —
  // пуш по ним слать нечего и незачем.
  const msgType = row.msg_type as string | undefined;
  if (!isGlobal && (msgType === 'edit' || msgType === 'delete')) return new Response('ok');

  const recipientIds: string[] = [];
  if (isGlobal) {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/chat_push_tokens?select=user_id&user_id=neq.${senderId}`,
      { headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` } },
    );
    const rows = await res.json();
    for (const r of rows) recipientIds.push(r.user_id);
  } else {
    recipientIds.push(row.recipient_id as string);
  }
  if (recipientIds.length === 0) return new Response('ok');

  const tokensRes = await fetch(
    `${SUPABASE_URL}/rest/v1/chat_push_tokens?select=token&user_id=in.(${recipientIds.join(',')})`,
    { headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` } },
  );
  const tokenRows = await tokensRes.json();
  const tokens: string[] = tokenRows.map((t: { token: string }) => t.token);
  if (tokens.length === 0) return new Response('ok');

  // Ник отправителя — раньше уведомление показывало только шаблонный
  // текст ("Личное сообщение"/заголовок без содержания), теперь то же
  // содержимое, что видно в самом приложении.
  const profileRes = await fetch(
    `${SUPABASE_URL}/rest/v1/chat_profiles?select=nickname&user_id=eq.${senderId}`,
    { headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` } },
  );
  const profileRows = await profileRes.json();
  const senderNickname = profileRows[0]?.nickname as string | undefined;

  const preview = (r: Record<string, unknown>): string => {
    if (r.text) return r.text as string;
    switch (r.msg_type) {
      case 'image': return '📷 Фото';
      case 'video': return '🎥 Видео';
      case 'audio': return '🎤 Голосовое';
      case 'file': return `📎 ${r.attachment_name ?? 'Файл'}`;
      default: return 'Новое сообщение';
    }
  };

  const title = isGlobal ? 'Общий чат' : (senderNickname ?? 'Личное сообщение');
  const body = isGlobal ? `${senderNickname ?? '—'}: ${preview(row)}` : preview(row);

  // FCM v1 шлёт одно сообщение на один токен — параллельно на все
  // устройства получателя (обычно одно, но пользователь может быть
  // залогинен на нескольких).
  await Promise.all(tokens.map((t) => sendPush(t, title, body).catch(() => {})));

  return new Response('ok');
});
