/**
 * «Толщина материала» — простое свечение массы по поверхности детали.
 *
 * Идея: для каждой вершины пускаем луч внутрь детали (против нормали) и измеряем,
 * через сколько миллиметров он выйдет с другой стороны. Это и есть локальная
 * толщина стенки — она прямо связана с тем, сколько материала в этом месте.
 *
 * Дальше вершина окрашивается в оттенок своей детали:
 *   • тонкая стенка — тусклый, почти прозрачный цвет;
 *   • толстый массив — насыщенный яркий цвет, почти непрозрачный.
 * В сборке у каждой детали свой оттенок, чтобы части не сливались.
 *
 * Лучи считаются по BVH (three-mesh-bvh), поэтому даже на 100–200 тыс.
 * треугольников это секунды, а не минуты.
 */

import * as THREE from 'three';
import { MeshBVH } from './vendor/three-mesh-bvh.js';

/** Оттенки для деталей сборки (градусы HSL). */
export const PART_HUES = [205, 28, 145, 285, 350, 48, 185, 320, 100, 265, 15, 170];

const DEFAULTS = {
  minAlpha: 0.10,
  maxAlpha: 0.97,
  gamma: 0.75,
  percentiles: { low: 0.08, high: 0.92 },
};

/**
 * Считает толщину по вершинам для каждого меша.
 * @returns {Array<{thickness: Float32Array, max: number, diag: number} | null>}
 */
export function computeThickness(meshes, onProgress = null) {
  const results = [];

  for (let meshIndex = 0; meshIndex < meshes.length; meshIndex += 1) {
    const mesh = meshes[meshIndex];
    const geometry = mesh.geometry;
    const position = geometry.getAttribute('position');

    if (!position || position.count < 3) {
      results.push(null);
      continue;
    }

    if (!geometry.getAttribute('normal')) {
      geometry.computeVertexNormals();
    }
    const normal = geometry.getAttribute('normal');

    let bvh;
    try {
      bvh = new MeshBVH(geometry, { targetLeafSize: 8 });
    } catch (error) {
      console.warn('[thickness] BVH failed', error);
      results.push(null);
      continue;
    }

    const box = new THREE.Box3().setFromBufferAttribute(position);
    const diagonal = box.getSize(new THREE.Vector3()).length() || 1;
    const far = diagonal * 1.05;
    const epsilon = Math.max(diagonal * 2e-4, 1e-5);

    const thickness = new Float32Array(position.count);
    const origin = new THREE.Vector3();
    const direction = new THREE.Vector3();
    const ray = new THREE.Ray();
    let max = 0;

    for (let i = 0; i < position.count; i += 1) {
      origin.fromBufferAttribute(position, i);
      direction.fromBufferAttribute(normal, i);

      const length = direction.length();
      if (!Number.isFinite(length) || length < 1e-9) {
        thickness[i] = 0;
        continue;
      }

      direction.multiplyScalar(-1 / length);

      let value = measureRay(bvh, origin, direction, epsilon, far, ray);

      // Вывернутые нормали (бывает в STEP): пробуем в обратную сторону.
      if (value <= 0) {
        direction.multiplyScalar(-1);
        value = measureRay(bvh, origin, direction, epsilon, far, ray);
      }

      thickness[i] = value > 0 ? value : far;
      if (thickness[i] > max) {
        max = thickness[i];
      }
    }

    // Сглаживаем по соседним вершинам: на рёбрах/узких фасках луч внутрь идёт
    // вдоль стенки и даёт большую «толщину», из-за чего край светился бы ярче
    // самой стенки. Несколько итераций убирают этот артефакт.
    const smoothed = smoothValues(geometry, thickness, 3);
    results.push({ thickness: smoothed, max, diag: diagonal });

    if (onProgress) {
      onProgress(meshIndex + 1, meshes.length);
    }
  }

  return results;
}

/** Усреднение по соседним вершинам (сетка индексированная). */
function smoothValues(geometry, values, iterations) {
  const index = geometry.getIndex();
  if (!index || iterations <= 0) {
    return values;
  }

  const count = values.length;
  let current = values;

  for (let iteration = 0; iteration < iterations; iteration += 1) {
    const sums = new Float64Array(count);
    const counts = new Int32Array(count);

    for (let i = 0; i < index.count; i += 3) {
      const a = index.getX(i);
      const b = index.getX(i + 1);
      const c = index.getX(i + 2);

      sums[a] += current[b] + current[c];
      counts[a] += 2;
      sums[b] += current[a] + current[c];
      counts[b] += 2;
      sums[c] += current[a] + current[b];
      counts[c] += 2;
    }

    const next = new Float32Array(count);
    for (let i = 0; i < count; i += 1) {
      next[i] = counts[i] > 0 ? (sums[i] + current[i]) / (counts[i] + 1) : current[i];
    }

    current = next;
  }

  return current;
}

/** Асинхронный вариант: между деталями отдаём кадр, чтобы интерфейс не замирал. */
export async function computeThicknessAsync(meshes, onProgress = null) {
  const results = [];

  for (let meshIndex = 0; meshIndex < meshes.length; meshIndex += 1) {
    results.push(...computeThickness([meshes[meshIndex]], null));

    if (onProgress) {
      onProgress(meshIndex + 1, meshes.length);
    }

    // eslint-disable-next-line no-await-in-loop
    await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
  }

  return results;
}

function measureRay(bvh, point, direction, epsilon, far, ray) {
  ray.origin.copy(point).addScaledVector(direction, epsilon);
  ray.direction.copy(direction);

  let hits;
  try {
    hits = bvh.raycast(ray, THREE.DoubleSide, 0, far);
  } catch (error) {
    return 0;
  }

  if (!hits || hits.length === 0) {
    return 0;
  }

  let best = Infinity;
  for (const hit of hits) {
    if (hit.distance < best) {
      best = hit.distance;
    }
  }

  return Number.isFinite(best) ? best + epsilon : 0;
}

/** Квантиль по копии массива (для устойчивой нормировки). */
function quantile(values, q) {
  if (!values.length) return 0;
  const sorted = Float32Array.from(values).sort();
  const index = Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * q)));
  return sorted[index];
}

/**
 * Красит поверхность по толщине: тонкое — прозрачное и тусклое, толстое — яркое.
 * Возвращает сводку (диапазон толщин в единицах модели).
 */
export function createThicknessMaterial() {
  // Без освещения: цвет — это и есть «карта массы», насыщенность читается точно.
  // Обычное смешивание + прозрачность: тонкая стенка почти исчезает,
  // массивный участок — плотный яркий цвет.
  return new THREE.MeshBasicMaterial({
    vertexColors: true,
    transparent: true,
    depthWrite: false,
    side: THREE.DoubleSide,
    toneMapped: false,
    opacity: 1,
  });
}

export function applyThicknessColors(meshes, results, material, options = {}) {
  const settings = { ...DEFAULTS, ...options };
  const summary = { min: Infinity, max: 0, parts: 0, reference: 0 };

  // Первый проход: диапазон толщин каждой детали и общий масштаб модели.
  const ranges = new Array(meshes.length).fill(null);
  let globalHigh = 0;

  for (let meshIndex = 0; meshIndex < meshes.length; meshIndex += 1) {
    const result = results[meshIndex];
    if (!result) continue;

    const low = quantile(result.thickness, settings.percentiles.low);
    const high = quantile(result.thickness, settings.percentiles.high);
    ranges[meshIndex] = { low, high };
    globalHigh = Math.max(globalHigh, high);
  }

  const globalReference = Math.max(globalHigh, 1e-6);

  // Второй проход: насыщенность — по диапазону детали (видна разница даже
  // у равномерной стенки), прозрачность — по абсолютной толщине в модели
  // (тонкие детали сборки остаются прозрачными, массивные — плотными).
  for (let meshIndex = 0; meshIndex < meshes.length; meshIndex += 1) {
    const mesh = meshes[meshIndex];
    const result = results[meshIndex];
    const range = ranges[meshIndex];
    const geometry = mesh.geometry;
    const position = geometry.getAttribute('position');
    if (!result || !range || !position) continue;

    const span = Math.max(range.high - range.low, Math.max(range.high * 0.02, 1e-6));

    summary.parts += 1;
    summary.min = Math.min(summary.min, range.low);
    summary.max = Math.max(summary.max, range.high);

    const hue = PART_HUES[meshIndex % PART_HUES.length] / 360;
    const saturated = new THREE.Color().setHSL(hue, 1.0, 0.58); // «много материала»
    const pale = new THREE.Color().setHSL(hue, 0.55, 0.30); // «тонкая стенка» — тускло
    const color = new THREE.Color();

    const colors = new Float32Array(position.count * 4);
    for (let i = 0; i < position.count; i += 1) {
      const value = result.thickness[i];
      const localT = Math.min(1, Math.max(0, (value - range.low) / span));
      const absoluteT = Math.min(1, Math.max(0, value / globalReference));

      const glows = Math.pow(localT, settings.gamma);
      const glowAbsolute = Math.pow(absoluteT, settings.gamma);

      color.copy(pale).lerp(saturated, 0.12 + 0.88 * glows);
      const alpha = settings.minAlpha + (settings.maxAlpha - settings.minAlpha) * glowAbsolute;

      colors[i * 4] = color.r;
      colors[i * 4 + 1] = color.g;
      colors[i * 4 + 2] = color.b;
      colors[i * 4 + 3] = alpha;
    }

    geometry.setAttribute('color', new THREE.BufferAttribute(colors, 4));

    if (!mesh.userData.thicknessOriginalMaterial) {
      mesh.userData.thicknessOriginalMaterial = mesh.material;
    }
    mesh.material = material;
    mesh.renderOrder = 3;
  }

  return {
    min: Number.isFinite(summary.min) ? summary.min : 0,
    max: summary.max,
    parts: summary.parts,
  };
}
/** Возвращает материалы и убирает атрибуты цвета. */
export function clearThicknessColors(meshes) {
  for (const mesh of meshes) {
    if (mesh.userData.thicknessOriginalMaterial) {
      mesh.material = mesh.userData.thicknessOriginalMaterial;
      delete mesh.userData.thicknessOriginalMaterial;
    }

    mesh.renderOrder = 0;
    const geometry = mesh.geometry;
    if (geometry.getAttribute('color')) {
      geometry.deleteAttribute('color');
    }
  }
}
