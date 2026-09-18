// Отдельный Apps Script — привязан к ВЫДЕЛЕННОМУ Google-аккаунту/Диску
// для больших вложений чата Puls, НЕ к личному Диску и НЕ к тому
// скрипту, что уже используется для работы ИИ с файлами. Задача этого
// скрипта — только команды (токен, удаление), сами байты файла через
// него не идут: Web App Apps Script ограничен ~50 МБ на тело
// запроса/ответа, для файлов до 5 ГБ это не подходит в принципе.
// Клиент (приложение Puls) получает отсюда короткоживущий Google OAuth
// токен и дальше сам стучится напрямую в googleapis.com (resumable
// upload / скачивание), минуя этот скрипт.

const API_TOKEN = 'ЗАМЕНИ_НА_СВОЙ_СЕКРЕТ'; // server-to-server: Supabase Edge Function -> сюда, наружу не светится
const UPLOAD_FOLDER_ID = 'ЗАМЕНИ_НА_ID_ПАПКИ'; // отдельная папка на этом Диске под вложения чата

function checkAuth(e) {
  if (!e || !e.parameter) {
    return respond({ error: 'Direct execution not supported. Use HTTP request.' }, 400);
  }
  if (e.parameter.token !== API_TOKEN) {
    return respond({ error: 'Unauthorized: Invalid token' }, 401);
  }
  return null;
}

function respond(data) {
  return ContentService.createTextOutput(JSON.stringify(data)).setMimeType(ContentService.MimeType.JSON);
}

function doGet(e) {
  const authErr = checkAuth(e);
  if (authErr) return authErr;

  const action = e.parameter.action;
  try {
    switch (action) {
      case 'health': return health();
      case 'getUploadToken': return getUploadToken();
      case 'delete': return deleteItem(e);
      default: return respond({ error: 'Unknown action: ' + action });
    }
  } catch (err) {
    return respond({ error: 'Server error: ' + err.message });
  }
}

// === HEALTH CHECK — проверить, что OAuth Drive авторизован ===
function health() {
  try {
    const folder = DriveApp.getFolderById(UPLOAD_FOLDER_ID); // заодно проверяет, что папка существует и доступна
    return respond({
      status: 'ok',
      folderName: folder.getName(),
      email: Session.getActiveUser().getEmail(),
    });
  } catch (err) {
    return respond({ status: 'auth_required', error: err.message });
  }
}

// === ГЛАВНОЕ: короткоживущий токен для прямой работы клиента с Drive API ===
//
// ScriptApp.getOAuthToken() — токен ЭТОГО скрипта (~1 час, Google сам
// обновляет его ближе к истечению). Он выдаётся клиенту (отправителю
// или получателю файла) через Supabase Edge Function, и клиент этим
// токеном напрямую грузит/качает файл через googleapis.com — сюда,
// в Apps Script, файл целиком уже не заходит.
//
// Область действия токена определяется правами (oauthScopes) в
// appsscript.json этого проекта — если там указан
// "https://www.googleapis.com/auth/drive.file" (а не полный "drive"),
// токен сможет работать ТОЛЬКО с файлами, которые сам же и создал —
// то есть даже утёкший токен не даёт доступа ко всему Диску.
// Настроить: меню проекта -> Настройки проекта -> "Показать файл
// manifest" -> появится appsscript.json -> прописать oauthScopes.
function getUploadToken() {
  return respond({
    token: ScriptApp.getOAuthToken(),
    folderId: UPLOAD_FOLDER_ID,
  });
}

// === Удаление файла с Диска — вызывается после подтверждённого
// скачивания получателем (самоочистка) ===
function deleteItem(e) {
  const fileId = e.parameter.fileId;
  if (!fileId) return respond({ error: 'fileId is required' });
  try {
    Drive.Files.remove(fileId); // ТРЕБУЕТ включённого расширенного сервиса "Drive API" (см. инструкцию ниже)
    return respond({ deleted: true });
  } catch (err) {
    return respond({ error: 'Delete failed: ' + err.message });
  }
}

// === Тестовая функция — прогнать вручную из редактора Apps Script ===
function testDoGet() {
  const mockEvent = { parameter: { action: 'health', token: API_TOKEN } };
  Logger.log(doGet(mockEvent).getContent());
}
