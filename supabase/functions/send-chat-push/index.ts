// Edge Function: отправляет push через Firebase (FCM), когда в чате
// появляется новое сообщение — вызывается Database Webhook'ом Supabase
// (Dashboard → Database → Webhooks) на INSERT в chat_messages и
// chat_global_messages. Сама переписка остаётся полностью на Supabase —
// эта функция только "будит" закрытое приложение (см. lib/services/push_service.dart).
//
// Деплой (нужно сделать вручную, у меня нет доступа к CLI/дашборду):
//   1. supabase functions deploy send-chat-push --project-ref <ref>
//   2. supabase secrets set FCM_SERVER_KEY=<ключ из Firebase Console →
//      Project settings → Cloud Messaging → Server key ("Cloud Messaging
//      API (Legacy)" — если раздел скрыт, включить его там же)
//   3. Dashboard → Database → Webhooks → Create:
//      - таблица chat_messages, событие INSERT, URL этой функции
//      - таблица chat_global_messages, событие INSERT, тот же URL
//
// Ограничение: используется LEGACY FCM API (Authorization: key=...), а
// не новый v1 (OAuth2 service-account JWT) — проще для Deno без лишних
// библиотек. Google может отключать legacy API по умолчанию на новых
// проектах — тогда его нужно явно включить в консоли, либо переписать
// функцию на v1 (это отдельная, более сложная задача).

const FCM_SERVER_KEY = Deno.env.get('FCM_SERVER_KEY') ?? '';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

Deno.serve(async (req: Request) => {
  if (!FCM_SERVER_KEY || !SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return new Response('not configured', { status: 500 });
  }

  const payload = await req.json();
  const row = payload.record;
  if (!row) return new Response('ok');

  // chat_messages (личное) — получатель известен напрямую;
  // chat_global_messages (общий чат) — уведомляем всех, кроме автора.
  const isGlobal = payload.table === 'chat_global_messages';
  const senderId = row.sender_id as string;

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

  const body = isGlobal ? (row.text ?? 'Новое сообщение') : 'Новое сообщение в чате';

  await fetch('https://fcm.googleapis.com/fcm/send', {
    method: 'POST',
    headers: {
      Authorization: `key=${FCM_SERVER_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      registration_ids: tokens,
      notification: {
        title: isGlobal ? 'Общий чат' : 'Личное сообщение',
        body,
      },
    }),
  });

  return new Response('ok');
});
