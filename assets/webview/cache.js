/**
 * Кэш разобранной геометрии в IndexedDB.
 *
 * Разбор STEP — самая долгая операция (OCCT строит B-rep и триангулирует).
 * Поэтому результат складывается в браузерное хранилище: повторное открытие
 * того же файла с тем же качеством — мгновенное, без OCCT.
 *
 * Формат записи — компактный двоичный:
 *   [magic "SVC1"][длина JSON-заголовка][JSON][positions][normals][indices]
 *
 * Нормали храним как есть: пересчёт «на лету» даёт артефакты освещения на
 * CAD-сетке с дублированными вершинами на гранях.
 */

const DB_NAME = 'stepViewerGeometry';
const DB_VERSION = 1;
const STORE = 'geometries';
const MAGIC = 0x53464331; // 'SFC1'
const MAX_ENTRIES = 12;

let dbPromise = null;

function openDb() {
  if (dbPromise) return dbPromise;

  dbPromise = new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') {
      reject(new Error('IndexedDB недоступен'));
      return;
    }

    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: 'key' });
        store.createIndex('savedAt', 'savedAt');
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).catch((error) => {
    dbPromise = null;
    throw error;
  });

  return dbPromise;
}

export async function hashBytes(bytes) {
  try {
    if (globalThis.crypto?.subtle) {
      const digest = await crypto.subtle.digest('SHA-256', bytes);
      return Array.from(new Uint8Array(digest))
        .map((value) => value.toString(16).padStart(2, '0'))
        .join('');
    }
  } catch {
    // ниже — простой запасной вариант
  }

  let hash = 2166136261;
  for (let i = 0; i < bytes.length; i += 1) {
    hash ^= bytes[i];
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16) + ':' + bytes.length.toString(16);
}

export function serializeMeshes(meshes) {
  const pieces = [];
  const header = { meshes: [] };
  let offset = 0;

  for (const mesh of meshes) {
    const position = mesh.attributes?.position?.array;
    const index = mesh.index?.array;
    if (!position || !index) continue;

    // occt-import-js может вернуть обычные Array, а не типизированные
    const positionArray = position instanceof Float32Array ? position : Float32Array.from(position);
    const indexArray = index instanceof Uint32Array ? index : Uint32Array.from(index);
    const normalArrayRaw = mesh.attributes?.normal?.array;
    const normalArray = normalArrayRaw
      ? (normalArrayRaw instanceof Float32Array ? normalArrayRaw : Float32Array.from(normalArrayRaw))
      : null;

    const positionBytes = new Uint8Array(positionArray.buffer, positionArray.byteOffset, positionArray.byteLength);
    const indexBytes = new Uint8Array(indexArray.buffer, indexArray.byteOffset, indexArray.byteLength);
    const normalBytes = normalArray
      ? new Uint8Array(normalArray.buffer, normalArray.byteOffset, normalArray.byteLength)
      : null;

    header.meshes.push({
      name: mesh.name || '',
      color: mesh.color ? Array.from(mesh.color) : null,
      faces: (mesh.brep_faces || []).map((face) => [
        face.first,
        face.last,
        face.color ? Array.from(face.color) : null,
      ]),
      positionOffset: offset,
      positionBytes: positionBytes.byteLength,
      normalOffset: normalBytes ? offset + positionBytes.byteLength : -1,
      normalBytes: normalBytes ? normalBytes.byteLength : 0,
      indexOffset: offset + positionBytes.byteLength + (normalBytes ? normalBytes.byteLength : 0),
      indexBytes: indexBytes.byteLength,
    });

    if (normalBytes) {
      pieces.push(positionBytes, normalBytes, indexBytes);
      offset += positionBytes.byteLength + normalBytes.byteLength + indexBytes.byteLength;
    } else {
      pieces.push(positionBytes, indexBytes);
      offset += positionBytes.byteLength + indexBytes.byteLength;
    }
  }

  const headerJson = new TextEncoder().encode(JSON.stringify(header));
  const total = 8 + headerJson.byteLength + offset;
  const buffer = new ArrayBuffer(total);
  const view = new DataView(buffer);
  view.setUint32(0, MAGIC, true);
  view.setUint32(4, headerJson.byteLength, true);

  const bytes = new Uint8Array(buffer);
  bytes.set(headerJson, 8);
  let cursor = 8 + headerJson.byteLength;
  for (const piece of pieces) {
    bytes.set(piece, cursor);
    cursor += piece.byteLength;
  }

  return buffer;
}

export function deserializeMeshes(buffer) {
  const view = new DataView(buffer);
  if (view.getUint32(0, true) !== MAGIC) {
    throw new Error('Повреждённый кэш геометрии');
  }

  const headerLength = view.getUint32(4, true);
  const headerJson = new TextDecoder().decode(new Uint8Array(buffer, 8, headerLength));
  const header = JSON.parse(headerJson);
  const payloadStart = 8 + headerLength;
  const payload = buffer.slice(payloadStart);

  const meshes = header.meshes.map((entry) => {
    const position = new Float32Array(payload.slice(entry.positionOffset, entry.positionOffset + entry.positionBytes));
    const index = new Uint32Array(payload.slice(entry.indexOffset, entry.indexOffset + entry.indexBytes));
    const normal = entry.normalBytes > 0 && entry.normalOffset >= 0
      ? new Float32Array(payload.slice(entry.normalOffset, entry.normalOffset + entry.normalBytes))
      : null;

    const attributes = { position: { array: position } };
    if (normal) attributes.normal = { array: normal };

    return {
      name: entry.name,
      color: entry.color || undefined,
      brep_faces: (entry.faces || []).map(([first, last, color]) => ({ first, last, color: color || null })),
      attributes,
      index: { array: index },
    };
  });

  return { meshes };
}

export async function readCache(hash, quality) {
  try {
    const db = await openDb();
    return await new Promise((resolve) => {
      const transaction = db.transaction(STORE, 'readonly');
      const request = transaction.objectStore(STORE).get(`${hash}:${quality}`);
      request.onsuccess = () => resolve(request.result || null);
      request.onerror = () => resolve(null);
    });
  } catch {
    return null;
  }
}

export async function writeCache(hash, quality, fileName, meshes) {
  try {
    const data = serializeMeshes(meshes);
    const db = await openDb();

    await new Promise((resolve, reject) => {
      const transaction = db.transaction(STORE, 'readwrite');
      transaction.objectStore(STORE).put({
        key: `${hash}:${quality}`,
        hash,
        quality,
        fileName,
        size: data.byteLength,
        savedAt: Date.now(),
        data,
      });
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });

    await prune(db);
    return data.byteLength;
  } catch (error) {
    console.warn('[cache] write failed', error);
    return 0;
  }
}

async function prune(db) {
  try {
    const entries = await new Promise((resolve) => {
      const transaction = db.transaction(STORE, 'readonly');
      const request = transaction.objectStore(STORE).getAll();
      request.onsuccess = () => resolve(request.result || []);
      request.onerror = () => resolve([]);
    });

    if (entries.length <= MAX_ENTRIES) return;

    entries.sort((a, b) => a.savedAt - b.savedAt);
    const remove = entries.slice(0, entries.length - MAX_ENTRIES);
    await new Promise((resolve) => {
      const transaction = db.transaction(STORE, 'readwrite');
      const store = transaction.objectStore(STORE);
      for (const entry of remove) store.delete(entry.key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => resolve();
    });
  } catch {
    // чистка кэша не критична
  }
}

export async function cacheStats() {
  try {
    const db = await openDb();
    const entries = await new Promise((resolve) => {
      const transaction = db.transaction(STORE, 'readonly');
      const request = transaction.objectStore(STORE).getAll();
      request.onsuccess = () => resolve(request.result || []);
      request.onerror = () => resolve([]);
    });

    return {
      count: entries.length,
      bytes: entries.reduce((sum, entry) => sum + (entry.size || 0), 0),
    };
  } catch {
    return { count: 0, bytes: 0 };
  }
}

export async function clearCache() {
  try {
    const db = await openDb();
    await new Promise((resolve) => {
      const transaction = db.transaction(STORE, 'readwrite');
      transaction.objectStore(STORE).clear();
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => resolve();
    });
    return true;
  } catch {
    return false;
  }
}
