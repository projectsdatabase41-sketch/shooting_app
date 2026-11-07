/**
 * Разбор STEP в Web Worker.
 *
 * Главная причина: OCCT на больших файлах думает десятки секунд, и в основном
 * потоке страница всё это время висит (браузер даже показывает «страница не
 * отвечает»). В воркере интерфейс остаётся живым, работает индикатор времени,
 * а неудачный разбор можно прервать, просто убив воркер.
 *
 * Сообщения:
 *   → { id, bytes: ArrayBuffer, params }
 *   ← { id, success, meshes: [{ name, color, brep_faces, position, normal, index }] }
 *   ← { id, error }
 * Массивы передаются как transferable, без копирования.
 */

importScripts('./vendor/occt-import-js.js');

let occtPromise = null;

function getOcct() {
  if (!occtPromise) {
    occtPromise = self.occtimportjs({
      locateFile: (name) => new URL('./vendor/' + name, self.location.href).href,
    });
  }
  return occtPromise;
}

self.onmessage = async (event) => {
  const { id, bytes, params } = event.data || {};
  try {
    const occt = await getOcct();
    const result = occt.ReadStepFile(new Uint8Array(bytes), params || null);

    const transfer = [];
    const seen = new Set();
    const keep = (array) => {
      if (!array || !array.buffer || seen.has(array.buffer)) return;
      seen.add(array.buffer);
      transfer.push(array.buffer);
    };

    const meshes = (result.meshes || []).map((mesh) => {
      const position = mesh.attributes?.position?.array || null;
      const normal = mesh.attributes?.normal?.array || null;
      const index = mesh.index?.array || null;
      keep(position);
      keep(normal);
      keep(index);
      return {
        name: mesh.name,
        color: mesh.color || null,
        brep_faces: mesh.brep_faces || null,
        position,
        normal,
        index,
      };
    });

    self.postMessage({ id, success: !!result.success, meshes }, transfer);
  } catch (error) {
    self.postMessage({ id, error: String((error && error.message) || error) });
  }
};
