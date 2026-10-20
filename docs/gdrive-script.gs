/**
 * Nexus ↔ Google Диск: мост на Google Apps Script.
 * Этот код готовит сам Nexus: пароль уже вписан в строку SECRET ниже — ничего править не нужно.
 * Вставьте код целиком в новый проект на script.google.com и разверните как веб-приложение.
 * Без пароля скрипт ничего не отдаёт и не меняет.
 */
const SECRET = '__SECRET__';
const MAX_GET_BYTES = 10 * 1024 * 1024; // крупнее за один раз не отдаём
const LIST_LIMIT = 500;

function doGet() {
  return out({ ok: true, data: 'Nexus Drive bridge' });
}

function authorized(req) {
  if (typeof SECRET !== 'string') return false;
  if (SECRET.length < 12) return false;
  if (SECRET.charAt(0) === '_') return false; // шаблон без пароля
  return req.secret === SECRET;
}

function doPost(e) {
  try {
    const req = JSON.parse(e.postData.contents);
    if (!authorized(req)) {
      return out({ ok: false, error: 'unauthorized' });
    }
    const fn = ACTIONS[req.action];
    if (!fn) return out({ ok: false, error: 'unknown action' });
    return out({ ok: true, data: fn(req) });
  } catch (err) {
    return out({ ok: false, error: String(err) });
  }
}

function out(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

function folderOf(id) {
  return !id || id === 'root' ? DriveApp.getRootFolder() : DriveApp.getFolderById(id);
}

// Файл или папка по id.
function itemOf(id) {
  try {
    return DriveApp.getFileById(id);
  } catch (e) {
    return DriveApp.getFolderById(id);
  }
}

function meta(it, isFolder) {
  return {
    id: it.getId(),
    name: it.getName(),
    mime: isFolder ? 'folder' : it.getMimeType(),
    size: isFolder ? 0 : it.getSize(),
    modified: it.getLastUpdated().getTime(),
    url: it.getUrl(),
    isFolder: isFolder,
  };
}

function esc(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

function collect(iter, isFolder, limit) {
  const res = [];
  while (iter.hasNext() && res.length < limit) res.push(meta(iter.next(), isFolder));
  return res;
}

function ensurePath(path) {
  let cur = DriveApp.getRootFolder();
  String(path).split('/').filter(function (p) { return p; }).forEach(function (name) {
    const it = cur.getFoldersByName(name);
    cur = it.hasNext() ? it.next() : cur.createFolder(name);
  });
  return cur;
}

const ACTIONS = {
  ping: function () {
    return { root: DriveApp.getRootFolder().getId() };
  },

  list: function (r) {
    const f = folderOf(r.folderId);
    const parents = f.getParents();
    return {
      id: f.getId(),
      name: f.getName(),
      parent: parents.hasNext() ? parents.next().getId() : null,
      folders: collect(f.getFolders(), true, LIST_LIMIT),
      files: collect(f.getFiles(), false, LIST_LIMIT),
    };
  },

  search: function (r) {
    const q = "title contains '" + esc(r.q) + "' and trashed = false";
    return {
      folders: collect(DriveApp.searchFolders(q), true, 100),
      files: collect(DriveApp.searchFiles(q), false, 100),
    };
  },

  // Содержимое файла (до MAX_GET_BYTES). Документы Google отдаются как PDF.
  get: function (r) {
    const f = DriveApp.getFileById(r.id);
    const native = f.getMimeType().indexOf('application/vnd.google-apps') === 0;
    if (!native && f.getSize() > MAX_GET_BYTES) throw new Error('too large');
    const blob = native ? f.getAs('application/pdf') : f.getBlob();
    const bytes = blob.getBytes();
    if (bytes.length > MAX_GET_BYTES) throw new Error('too large');
    return {
      name: native ? f.getName() + '.pdf' : f.getName(),
      mime: blob.getContentType(),
      size: bytes.length,
      b64: Utilities.base64Encode(bytes),
      url: f.getUrl(),
    };
  },

  // Создать файл; с overwriteId — заменить текстовый файл на месте (иначе старый уходит в корзину).
  put: function (r) {
    const bytes = Utilities.base64Decode(r.b64);
    return putBytes(r.parentId, r.name, r.mime, bytes, r.overwriteId);
  },

  // Большие файлы: части по порядку (chunk), затем finish.
  chunk: function (r) {
    const tmp = ensurePath('Nexus/.tmp');
    tmp.createFile(r.uploadId + '.' + ('0000' + r.n).slice(-4), r.b64, 'text/plain');
    return true;
  },

  finish: function (r) {
    const tmp = ensurePath('Nexus/.tmp');
    let all = [];
    for (let n = 0; n < r.total; n++) {
      const it = tmp.getFilesByName(r.uploadId + '.' + ('0000' + n).slice(-4));
      if (!it.hasNext()) throw new Error('missing chunk ' + n);
      const part = it.next();
      all = all.concat(Utilities.base64Decode(part.getBlob().getDataAsString()));
      part.setTrashed(true);
    }
    return putBytes(r.parentId, r.name, r.mime, all, r.overwriteId);
  },

  mkdir: function (r) {
    return meta(folderOf(r.parentId).createFolder(r.name), true);
  },

  ensurePath: function (r) {
    return { id: ensurePath(r.path).getId() };
  },

  rename: function (r) {
    const it = itemOf(r.id);
    it.setName(r.name);
    return true;
  },

  trash: function (r) {
    itemOf(r.id).setTrashed(true);
    return true;
  },

  move: function (r) {
    const it = itemOf(r.id);
    it.moveTo(folderOf(r.toId));
    return true;
  },
};

function putBytes(parentId, name, mime, bytes, overwriteId) {
  const m = mime || 'application/octet-stream';
  if (overwriteId) {
    const old = DriveApp.getFileById(overwriteId);
    const textual = function (t) { return /^(text\/|application\/(json|xml))/.test(t); };
    if (textual(old.getMimeType()) && textual(m)) {
      old.setContent(Utilities.newBlob(bytes).getDataAsString());
      return meta(old, false);
    }
    old.setTrashed(true);
  }
  const blob = Utilities.newBlob(bytes, m, name);
  return meta(folderOf(parentId).createFile(blob), false);
}
