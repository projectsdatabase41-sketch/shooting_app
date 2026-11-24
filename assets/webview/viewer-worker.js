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

/** Материалы из текста STEP (см. mass.js.scanStepMaterials) — здесь копия, воркер классический. */
function scanMaterials(bytes) {
  try {
    const text = new TextDecoder('utf-8', { fatal: false }).decode(new Uint8Array(bytes));
    if (!/MATERIAL|DENSITY/i.test(text)) return [];

    const names = new Set();
    for (const match of text.matchAll(/MATERIAL_DESIGNATION\s*\(\s*'([^']{1,80})'/gi)) {
      const name = match[1].trim();
      if (name) names.add(name);
    }

    const densities = [];
    for (const match of text.matchAll(/MASS_DENSITY_MEASURE\s*\(\s*([0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?)/gi)) {
      const value = Number(match[1]);
      if (Number.isFinite(value) && value > 1) densities.push(value / 1000);
    }

    if (names.size === 0 && densities.length === 0) return [];

    const density = densities.length ? densities[0] : null;
    const list = names.size === 0
      ? [{ name: 'материал из файла', density }]
      : Array.from(names).map((name) => ({ name, density }));
    return list.slice(0, 20);
  } catch {
    return [];
  }
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

    self.postMessage({ id, success: !!result.success, meshes, materials: scanMaterials(bytes) }, transfer);
  } catch (error) {
    self.postMessage({ id, error: String((error && error.message) || error) });
  }
};
