// Edge Function: прослойка к Apps Script на ВЫДЕЛЕННОМ Google Drive для
// больших вложений чата (свыше ChatMediaUtils.maxAttachmentBytes, см.
// lib/logic/chat_media_utils.dart) — сама функция байты файла не видит
// и не трогает, только просит у Apps Script короткоживущий OAuth-токен
// (action: getUploadToken) или удаление файла после скачивания
// (action: delete). Дальше клиент сам работает с googleapis.com
// напрямую — см. google-apps-script/chat-drive-relay.gs.
//
// JWT чата Supabase проверяет сама на входе (verify_jwt включён по
// умолчанию для Edge Functions) — вызвать эту функцию может только
// залогиненный пользователь чата, отдельно тут ничего не проверяем.
//
// Деплой (ДРУГОЙ Supabase-проект, не тот, что подключён к MCP в этой
// сессии — доступа к CLI/дашборду нет, только вручную):
//   supabase functions deploy chat-drive-token --project-ref frbptucrvmyikencyspu
// Secrets:
//   supabase secrets set --project-ref frbptucrvmyikencyspu \
//     DRIVE_SCRIPT_URL=https://script.google.com/macros/s/ВАШ_ID/exec \
//     DRIVE_API_TOKEN=<тот же секрет, что в Код.gs выделенного Диска>

const DRIVE_SCRIPT_URL = Deno.env.get('DRIVE_SCRIPT_URL') ?? '';
const DRIVE_API_TOKEN = Deno.env.get('DRIVE_API_TOKEN') ?? '';

Deno.serve(async (req: Request) => {
  if (!DRIVE_SCRIPT_URL || !DRIVE_API_TOKEN) {
    return new Response(JSON.stringify({ error: 'not configured' }), { status: 500 });
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'method not allowed' }), { status: 405 });
  }

  let body: { action?: string; fileId?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'bad json' }), { status: 400 });
  }

  const url = new URL(DRIVE_SCRIPT_URL);
  url.searchParams.set('token', DRIVE_API_TOKEN);

  if (body.action === 'getUploadToken') {
    url.searchParams.set('action', 'getUploadToken');
  } else if (body.action === 'delete') {
    if (!body.fileId) return new Response(JSON.stringify({ error: 'fileId required' }), { status: 400 });
    url.searchParams.set('action', 'delete');
    url.searchParams.set('fileId', body.fileId);
  } else {
    return new Response(JSON.stringify({ error: 'unknown action' }), { status: 400 });
  }

  // Apps Script Web App иногда отвечает редиректом (302) на сам себя —
  // fetch с redirect: 'follow' (по умолчанию) уже это разруливает.
  const res = await fetch(url.toString());
  const json = await res.json().catch(() => ({ error: 'bad response from script' }));
  return new Response(JSON.stringify(json), { headers: { 'Content-Type': 'application/json' } });
});
