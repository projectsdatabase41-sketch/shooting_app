// Edge Function: отправляет push через Firebase (FCM), когда в чате
// появляется новое сообщение — вызывается триггером chat_push_gate
// (sql/chat-push-gate.sql; он шлёт push не чаще раза в 2 минуты на пару
// отправитель→получатель, чтобы уложиться в квоту Edge Function) или, пока
// он не установлен, Database Webhook'ом на INSERT в chat_messages. Сама переписка остаётся полностью на Supabase —
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
//      (либо вместо вебхука — sql/chat-push-gate.sql и секрет PUSH_SECRET)

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

async function sendPush(token: string, title: string, body: string, data: Record<string, string>) {
  const accessToken = await getAccessToken();
  await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: { token, notification: { title, body }, data } }),
  });
}

// "Позвать" — БЕЗ `notification`-поля (данными), намеренно: иначе ОС
// показала бы его сама, в канале по умолчанию с обычным звуком —
// нужный канал (`coach_call`, рингтон устройства + вибрация, см.
// lib/services/push_service.dart) применяется только когда приложение
// рисует уведомление САМО через flutter_local_notifications. `priority:
// high` — чтобы data-сообщение доставилось сразу, а не с задержкой
// (Android иначе может придержать его до следующей синхронизации).
async function sendCallPush(token: string, title: string, body: string, contactId: string) {
  const accessToken = await getAccessToken();
  await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: { token, data: { type: 'call', title, body, contact_id: contactId }, android: { priority: 'high' } },
    }),
  });
}

// Обычное сообщение: на Android — ДАННЫМИ (приложение само рисует
// уведомление с фото отправителя и значком приложения, см.
// showMessageNotification в push_service.dart); на iOS/вебе — обычное
// уведомление, как раньше.
async function sendMessagePush(token: string, title: string, body: string, contactId: string) {
  const accessToken = await getAccessToken();
  await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: {
        token,
        data: { type: 'msg', title, body: body.slice(0, 500), contact_id: contactId },
        android: { priority: 'high' },
        apns: { payload: { aps: { alert: { title, body } } } },
        webpush: { notification: { title, body } },
      },
    }),
  });
}

// Только данные, без показа — приложение само решает (например, убрать уведомление).
async function sendDataOnly(token: string, data: Record<string, string>) {
  const accessToken = await getAccessToken();
  await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: { token, data, android: { priority: 'high' } } }),
  });
}

// ---- Обработчик webhook'а ----

Deno.serve(async (req: Request) => {
  if (!FIREBASE_CLIENT_EMAIL || !FIREBASE_PRIVATE_KEY || !FIREBASE_PROJECT_ID || !SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return new Response('not configured', { status: 500 });
  }

  // Секрет общий с триггером chat_push_gate (sql/chat-push-gate.sql): без него
  // любой мог бы вызвать функцию и рассылать push от чужого имени. Пока
  // PUSH_SECRET не задан, работает как раньше (Database Webhook).
  const expected = Deno.env.get('PUSH_SECRET') ?? '';
  if (expected && req.headers.get('x-push-secret') !== expected) return new Response('forbidden', { status: 403 });

  const payload = await req.json();
  const row = payload.record;
  // Общий чат убран — только личные сообщения (chat_messages).
  if (!row || payload.table === 'chat_global_messages') return new Response('ok');

  const senderId = row.sender_id as string;

  // edit/delete — служебные сигналы к уже отправленному сообщению (см.
  // ChatSyncService.editMessage/deleteMessage), не новые сообщения —
  // пуш по ним слать нечего и незачем.
  const msgType = row.msg_type as string | undefined;
  if (msgType === 'edit' || msgType === 'read') return new Response('ok');
  if (msgType === 'delete') {
    // Сообщение удалили — убрать у получателя уведомление с его текстом.
    const threadId = (row.group_id as string | undefined) ?? senderId;
    const H0 = { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` };
    // В группе триггер вызвал нас один раз — чистим уведомление у всех участников.
    let targets = [row.recipient_id as string];
    if (row.group_id) {
      const m = await fetch(`${SUPABASE_URL}/rest/v1/chat_group_members?select=user_id&group_id=eq.${row.group_id}&user_id=neq.${senderId}`, { headers: H0 });
      targets = ((await m.json()) as { user_id: string }[]).map((x) => x.user_id);
    }
    if (targets.length === 0) return new Response('ok');
    const res = await fetch(`${SUPABASE_URL}/rest/v1/chat_push_tokens?select=token&user_id=in.(${targets.join(',')})`, { headers: H0 });
    const toks = ((await res.json()) as { token: string }[]).map((t) => t.token);
    await Promise.all(toks.map((t) => sendDataOnly(t, { type: 'msg_delete', contact_id: threadId }).catch(() => {})));
    return new Response('ok');
  }

  const H = { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` };
  const groupId = row.group_id as string | undefined;
  let groupName: string | undefined;

  const recipientIds: string[] = [];
  const recipientId = row.recipient_id as string;
  if (groupId) {
    // Группа: триггер вызвал нас один раз на сообщение — рассылаем всем
    // участникам, кроме автора, у кого не выключены уведомления.
    const [membersRes, groupRes] = await Promise.all([
      fetch(`${SUPABASE_URL}/rest/v1/chat_group_members?select=user_id&group_id=eq.${groupId}&user_id=neq.${senderId}`, { headers: H }),
      fetch(`${SUPABASE_URL}/rest/v1/chat_groups?select=name&id=eq.${groupId}`, { headers: H }),
    ]);
    const ids = ((await membersRes.json()) as { user_id: string }[]).map((m) => m.user_id);
    groupName = ((await groupRes.json()) as { name: string }[])[0]?.name;
    if (ids.length > 0) {
      const modesRes = await fetch(
        `${SUPABASE_URL}/rest/v1/chat_profiles?select=user_id,personal_push_mode&user_id=in.(${ids.join(',')})`,
        { headers: H },
      );
      const off = new Set(
        ((await modesRes.json()) as { user_id: string; personal_push_mode?: string }[])
          .filter((p) => p.personal_push_mode === 'none')
          .map((p) => p.user_id),
      );
      recipientIds.push(...ids.filter((id) => !off.has(id)));
    }
  } else
  // "Позвать" и его сигналы (call_ack — тренер идёт, call_cancel —
  // спортсмен передумал) — мимо настройки "Уведомления личных чатов"
  // (тот же принцип, что звонок мимо беззвучного режима телефона):
  // это явный разовый вызов и ответ на него, а не рядовое сообщение,
  // которое можно отложить.
  if (msgType === 'call' || msgType === 'call_ack' || msgType === 'call_cancel') {
    recipientIds.push(recipientId);
  } else {
    const profileRes = await fetch(
      `${SUPABASE_URL}/rest/v1/chat_profiles?select=personal_push_mode&user_id=eq.${recipientId}`,
      { headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` } },
    );
    const rows = await profileRes.json();
    const mode = rows[0]?.personal_push_mode ?? 'all';
    if (mode !== 'none') recipientIds.push(recipientId);
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

  // FCM v1 шлёт одно сообщение на один токен — параллельно на все
  // устройства получателя (обычно одно, но пользователь может быть
  // залогинен на нескольких).
  if (msgType === 'call') {
    // Тренер мог отключить громкий канал (chat_profiles.call_alerts_enabled,
    // см. ChatAuthService.callAlertsEnabled) — тогда шлём как обычное
    // уведомление, а не рингтон+вибрацию поверх всего.
    const prefRes = await fetch(
      `${SUPABASE_URL}/rest/v1/chat_profiles?select=call_alerts_enabled&user_id=eq.${recipientIds[0]}`,
      { headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` } },
    );
    const prefRows = await prefRes.json();
    const alertsEnabled = prefRows[0]?.call_alerts_enabled ?? true;
    const title = senderNickname ?? 'Звонок';
    const body = 'вызывает вас';
    if (alertsEnabled) {
      await Promise.all(tokens.map((t) => sendCallPush(t, title, body, senderId).catch(() => {})));
    } else {
      await Promise.all(
        tokens.map((t) => sendPush(t, title, body, { type: 'chat', contact_id: senderId }).catch(() => {})),
      );
    }
    return new Response('ok');
  }
  if (msgType === 'call_ack') {
    const title = senderNickname ?? 'Тренер';
    const body = 'идёт к вам';
    await Promise.all(
      tokens.map((t) => sendPush(t, title, body, { type: 'chat', contact_id: senderId }).catch(() => {})),
    );
    return new Response('ok');
  }
  if (msgType === 'call_cancel') {
    const title = senderNickname ?? 'Спортсмен';
    const body = 'отменил вызов — помощь больше не нужна';
    await Promise.all(
      tokens.map((t) => sendPush(t, title, body, { type: 'chat', contact_id: senderId }).catch(() => {})),
    );
    return new Response('ok');
  }

  const preview = (r: Record<string, unknown>): string => {
    if (r.text) {
      // График (```chart) в уведомлении — просто пометкой.
      const caption = (r.text as string).replace(/```chart[\s\S]*?```/g, '').trim();
      return caption || '📊 График';
    }
    switch (r.msg_type) {
      case 'image': return '📷 Фото';
      case 'video': return '🎥 Видео';
      case 'audio': return '🎤 Голосовое';
      case 'file': return `📎 ${r.attachment_name ?? 'Файл'}`;
      default: return 'Новое сообщение';
    }
  };

  const title = groupName ?? senderNickname ?? 'Личное сообщение';
  const body = groupName ? `${senderNickname ?? '—'}: ${preview(row)}` : preview(row);
  // Тап по уведомлению открывает диалог группы, а не личку с автором.
  const threadId = groupId ?? senderId;

  await Promise.all(tokens.map((t) => sendMessagePush(t, title, body, threadId).catch(() => {})));

  return new Response('ok');
});
