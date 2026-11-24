/**
 * Объёмная визуализация массы: «дым» и «частицы».
 *
 * Основа — карта расстояний до стенок (SDF), посчитанная по воксельной сетке:
 * у самой стенки расстояние ≈ 0, в середине массива — максимально.
 *
 * Дальше два способа показать это в 3D:
 *   • дым — шейдер, который прокачивает луч через 3D-текстуру: оптическая
 *     плотность растёт с расстоянием до стенки, поэтому тонкая стенка почти
 *     прозрачна, а сквозь массив материала дым становится плотным;
 *   • частицы — точки, которые ставятся в самые «толстые» участки объёма.
 *
 * «Контраст» задаёт масштаб расстояния: чем выше, тем ближе к стенкам начинает
 * появляться дым/точки (и тем резче переход).
 */

import * as THREE from 'three';

/** Бюджет вокселей на деталь: больше — точнее «дым», но дороже по памяти/времени. */
const VOXEL_BUDGET = 1_800_000;
const DEFAULT_RESOLUTION = 192;

/**
 * Строит карту плотности (расстояние до стенки) для геометрии детали.
 * density[i] = 0..255, где 0 — у стенки/снаружи, 255 — в самой глубокой точке.
 */
export function buildDensityVolume(geometry, options = {}) {
  const position = geometry.getAttribute('position');
  if (!position || position.count < 3) return null;

  const index = geometry.getIndex();
  const triangleCount = index ? index.count / 3 : position.count / 3;
  if (triangleCount < 4) return null;

  const box = new THREE.Box3().setFromBufferAttribute(position);
  const size = box.getSize(new THREE.Vector3());
  const maxDim = Math.max(size.x, size.y, size.z) || 1;

  // Шаг сетки подбираем так, чтобы воксель был мелким относительно самой тонкой
  // стороны детали: иначе у стенок остаётся «мёртвая зона» в несколько мм и дым
  // не доходит до края. Ограничитель — бюджет вокселей.
  const minDim = Math.max(1e-6, Math.min(size.x, size.y, size.z));
  const requested = options.resolution ?? DEFAULT_RESOLUTION;
  const budget = options.voxelBudget ?? VOXEL_BUDGET;

  let cell = Math.max(Math.min(maxDim / requested, minDim / 24), maxDim / 512);
  let nx = Math.max(4, Math.ceil(size.x / cell) + 1);
  let ny = Math.max(4, Math.ceil(size.y / cell) + 1);
  let nz = Math.max(4, Math.ceil(size.z / cell) + 1);

  while (nx * ny * nz > budget) {
    cell *= 1.2;
    nx = Math.max(4, Math.ceil(size.x / cell) + 1);
    ny = Math.max(4, Math.ceil(size.y / cell) + 1);
    nz = Math.max(4, Math.ceil(size.z / cell) + 1);
  }

  const total = nx * ny * nz;
  const origin = box.min.clone();

  const surface = new Uint8Array(total);
  markSurfaceVoxels(position, index, triangleCount, surface, origin, nx, ny, nz, cell);

  const sealed = surface.slice();
  dilate(sealed, nx, ny, nz);

  const inside = new Uint8Array(total);
  floodOutside(sealed, inside, nx, ny, nz);

  const distance = surfaceDistance(surface, nx, ny, nz);
  let maxDistanceCells = 0;
  for (let i = 0; i < total; i += 1) {
    if (inside[i] && distance[i] > maxDistanceCells) maxDistanceCells = distance[i];
  }

  if (maxDistanceCells <= 0) return null;

  // 0 — снаружи детали, 1..255 — внутри (1 = у самой стенки). Так шейдер
  // отличает пустоту вокруг детали от стенки и не заливает весь габарит.
  const density = new Uint8Array(total);
  for (let i = 0; i < total; i += 1) {
    if (!inside[i]) continue;
    density[i] = 1 + Math.round(Math.min(1, distance[i] / maxDistanceCells) * 254);
  }

  return {
    density,
    dims: [nx, ny, nz],
    box,
    cell,
    maxDistanceUnits: maxDistanceCells * cell,
  };
}

/* ------------------------------------------------------------------ */
/* Вокселизация                                                        */
/* ------------------------------------------------------------------ */

function markSurfaceVoxels(position, index, triangleCount, solid, origin, nx, ny, nz, cell) {
  const radiusSquared = (cell * 0.75) ** 2;

  for (let t = 0; t < triangleCount; t += 1) {
    const i0 = index ? index.getX(t * 3) : t * 3;
    const i1 = index ? index.getX(t * 3 + 1) : t * 3 + 1;
    const i2 = index ? index.getX(t * 3 + 2) : t * 3 + 2;

    const ax = position.getX(i0);
    const ay = position.getY(i0);
    const az = position.getZ(i0);
    const bx = position.getX(i1);
    const by = position.getY(i1);
    const bz = position.getZ(i1);
    const cx = position.getX(i2);
    const cy = position.getY(i2);
    const cz = position.getZ(i2);

    const minX = Math.min(ax, bx, cx) - cell;
    const maxX = Math.max(ax, bx, cx) + cell;
    const minY = Math.min(ay, by, cy) - cell;
    const maxY = Math.max(ay, by, cy) + cell;
    const minZ = Math.min(az, bz, cz) - cell;
    const maxZ = Math.max(az, bz, cz) + cell;

    const x0 = Math.max(0, Math.floor((minX - origin.x) / cell));
    const x1 = Math.min(nx - 1, Math.ceil((maxX - origin.x) / cell));
    const y0 = Math.max(0, Math.floor((minY - origin.y) / cell));
    const y1 = Math.min(ny - 1, Math.ceil((maxY - origin.y) / cell));
    const z0 = Math.max(0, Math.floor((minZ - origin.z) / cell));
    const z1 = Math.min(nz - 1, Math.ceil((maxZ - origin.z) / cell));

    for (let z = z0; z <= z1; z += 1) {
      const pz = origin.z + (z + 0.5) * cell;
      for (let y = y0; y <= y1; y += 1) {
        const py = origin.y + (y + 0.5) * cell;
        const row = nx * (y + ny * z);
        for (let x = x0; x <= x1; x += 1) {
          const px = origin.x + (x + 0.5) * cell;
          if (pointTriangleDistanceSq(px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz) <= radiusSquared) {
            solid[row + x] = 1;
          }
        }
      }
    }
  }
}

/** Квадрат расстояния от точки до треугольника. */
function pointTriangleDistanceSq(px, py, pz, ax, ay, az, bx, by, bz, cx, cy, cz) {
  const abx = bx - ax;
  const aby = by - ay;
  const abz = bz - az;
  const acx = cx - ax;
  const acy = cy - ay;
  const acz = cz - az;
  const apx = px - ax;
  const apy = py - ay;
  const apz = pz - az;

  const d1 = abx * apx + aby * apy + abz * apz;
  const d2 = acx * apx + acy * apy + acz * apz;
  if (d1 <= 0 && d2 <= 0) return apx * apx + apy * apy + apz * apz;

  const bpx = px - bx;
  const bpy = py - by;
  const bpz = pz - bz;
  const d3 = abx * bpx + aby * bpy + abz * bpz;
  const d4 = acx * bpx + acy * bpy + acz * bpz;
  if (d3 >= 0 && d4 <= d3) return bpx * bpx + bpy * bpy + bpz * bpz;

  const vc = d1 * d4 - d3 * d2;
  if (vc <= 0 && d1 >= 0 && d3 <= 0) {
    const v = d1 / (d1 - d3);
    const dx = px - (ax + abx * v);
    const dy = py - (ay + aby * v);
    const dz = pz - (az + abz * v);
    return dx * dx + dy * dy + dz * dz;
  }

  const cpx = px - cx;
  const cpy = py - cy;
  const cpz = pz - cz;
  const d5 = abx * cpx + aby * cpy + abz * cpz;
  const d6 = acx * cpx + acy * cpy + acz * cpz;
  if (d6 >= 0 && d5 <= d6) return cpx * cpx + cpy * cpy + cpz * cpz;

  const vb = d5 * d2 - d1 * d6;
  if (vb <= 0 && d2 >= 0 && d6 <= 0) {
    const w = d2 / (d2 - d6);
    const dx = px - (ax + acx * w);
    const dy = py - (ay + acy * w);
    const dz = pz - (az + acz * w);
    return dx * dx + dy * dy + dz * dz;
  }

  const va = d3 * d6 - d5 * d4;
  if (va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0) {
    const w = (d4 - d3) / (d4 - d3 + (d5 - d6));
    const dx = px - (bx + (cx - bx) * w);
    const dy = py - (by + (cy - by) * w);
    const dz = pz - (bz + (cz - bz) * w);
    return dx * dx + dy * dy + dz * dz;
  }

  const denom = 1 / (va + vb + vc);
  const v = vb * denom;
  const w = vc * denom;
  const dx = px - (ax + abx * v + acx * w);
  const dy = py - (ay + aby * v + acy * w);
  const dz = pz - (az + abz * v + acz * w);
  return dx * dx + dy * dy + dz * dz;
}

function dilate(mask, nx, ny, nz) {
  const copy = mask.slice();
  for (let z = 0; z < nz; z += 1) {
    for (let y = 0; y < ny; y += 1) {
      const row = nx * (y + ny * z);
      for (let x = 0; x < nx; x += 1) {
        if (copy[row + x]) continue;
        let hit = false;
        for (let dz = -1; dz <= 1 && !hit; dz += 1) {
          const zz = z + dz;
          if (zz < 0 || zz >= nz) continue;
          for (let dy = -1; dy <= 1 && !hit; dy += 1) {
            const yy = y + dy;
            if (yy < 0 || yy >= ny) continue;
            for (let dx = -1; dx <= 1; dx += 1) {
              const xx = x + dx;
              if (xx < 0 || xx >= nx) continue;
              if (copy[nx * (yy + ny * zz) + xx]) {
                hit = true;
                break;
              }
            }
          }
        }
        if (hit) mask[row + x] = 1;
      }
    }
  }
}

function floodOutside(solid, inside, nx, ny, nz) {
  const total = nx * ny * nz;
  const outside = new Uint8Array(total);
  const queue = new Int32Array(total);
  let head = 0;
  let tail = 0;

  const push = (index) => {
    if (outside[index] || solid[index]) return;
    outside[index] = 1;
    queue[tail++] = index;
  };

  for (let z = 0; z < nz; z += 1) {
    for (let y = 0; y < ny; y += 1) {
      for (let x = 0; x < nx; x += 1) {
        if (x === 0 || y === 0 || z === 0 || x === nx - 1 || y === ny - 1 || z === nz - 1) {
          push(nx * (y + ny * z) + x);
        }
      }
    }
  }

  while (head < tail) {
    const index = queue[head++];
    const z = Math.floor(index / (nx * ny));
    const rem = index - z * nx * ny;
    const y = Math.floor(rem / nx);
    const x = rem - y * nx;

    if (x > 0) push(index - 1);
    if (x < nx - 1) push(index + 1);
    if (y > 0) push(index - nx);
    if (y < ny - 1) push(index + nx);
    if (z > 0) push(index - nx * ny);
    if (z < nz - 1) push(index + nx * ny);
  }

  for (let i = 0; i < total; i += 1) {
    inside[i] = !outside[i] && !solid[i] ? 1 : 0;
  }
}

/**
 * Точное евклидово расстояние до поверхности (в вокселях).
 * Разделимое преобразование Фельзеншвальба: три прохода по осям, O(N) —
 * заметно быстрее чамферной аппроксимации и без систематической ошибки.
 */
function surfaceDistance(surface, nx, ny, nz) {
  const total = nx * ny * nz;
  const INF = 1e20;
  const field = new Float32Array(total);

  for (let i = 0; i < total; i += 1) {
    field[i] = surface[i] ? 0 : INF;
  }

  const maxDim = Math.max(nx, ny, nz);
  const line = new Float32Array(maxDim);
  const output = new Float32Array(maxDim);
  const envelope = new Int32Array(maxDim);
  const boundaries = new Float32Array(maxDim + 1);

  // вдоль X
  for (let z = 0; z < nz; z += 1) {
    for (let y = 0; y < ny; y += 1) {
      const base = nx * (y + ny * z);
      for (let x = 0; x < nx; x += 1) line[x] = field[base + x];
      edt1d(line, nx, output, envelope, boundaries);
      for (let x = 0; x < nx; x += 1) field[base + x] = output[x];
    }
  }

  // вдоль Y
  for (let z = 0; z < nz; z += 1) {
    for (let x = 0; x < nx; x += 1) {
      for (let y = 0; y < ny; y += 1) line[y] = field[nx * (y + ny * z) + x];
      edt1d(line, ny, output, envelope, boundaries);
      for (let y = 0; y < ny; y += 1) field[nx * (y + ny * z) + x] = output[y];
    }
  }

  // вдоль Z
  for (let y = 0; y < ny; y += 1) {
    for (let x = 0; x < nx; x += 1) {
      for (let z = 0; z < nz; z += 1) line[z] = field[nx * (y + ny * z) + x];
      edt1d(line, nz, output, envelope, boundaries);
      for (let z = 0; z < nz; z += 1) field[nx * (y + ny * z) + x] = output[z];
    }
  }

  for (let i = 0; i < total; i += 1) {
    field[i] = Math.sqrt(field[i]);
  }

  return field;
}

/** Одномерное преобразование квадратов расстояний по строке. */
function edt1d(source, length, destination, envelope, boundaries) {
  let k = 0;
  envelope[0] = 0;
  boundaries[0] = -Infinity;
  boundaries[1] = Infinity;

  for (let q = 1; q < length; q += 1) {
    let s = ((source[q] + q * q) - (source[envelope[k]] + envelope[k] * envelope[k])) / (2 * q - 2 * envelope[k]);
    while (s <= boundaries[k]) {
      k -= 1;
      s = ((source[q] + q * q) - (source[envelope[k]] + envelope[k] * envelope[k])) / (2 * q - 2 * envelope[k]);
    }
    k += 1;
    envelope[k] = q;
    boundaries[k] = s;
    boundaries[k + 1] = Infinity;
  }

  k = 0;
  for (let q = 0; q < length; q += 1) {
    while (boundaries[k + 1] < q) k += 1;
    const delta = q - envelope[k];
    destination[q] = delta * delta + source[envelope[k]];
  }
}
/* Текстура объёма                                                     */
/* ------------------------------------------------------------------ */

export function createVolumeTexture(volume) {
  const [nx, ny, nz] = volume.dims;
  const texture = new THREE.Data3DTexture(volume.density, nx, ny, nz);
  texture.format = THREE.RedFormat;
  texture.type = THREE.UnsignedByteType;
  texture.minFilter = THREE.LinearFilter;
  texture.magFilter = THREE.LinearFilter;
  texture.wrapS = THREE.ClampToEdgeWrapping;
  texture.wrapT = THREE.ClampToEdgeWrapping;
  texture.wrapR = THREE.ClampToEdgeWrapping;
  texture.unpackAlignment = 1;
  texture.needsUpdate = true;
  return texture;
}

/* ------------------------------------------------------------------ */
/* Дым                                                                 */
/* ------------------------------------------------------------------ */

const CLOUD_VERTEX = /* glsl */ `
  varying vec3 vWorld;
  void main() {
    vec4 world = modelMatrix * vec4(position, 1.0);
    vWorld = world.xyz;
    gl_Position = projectionMatrix * viewMatrix * world;
  }
`;

const CLOUD_FRAGMENT = /* glsl */ `
  precision highp float;
  precision highp sampler3D;

  uniform sampler3D uVolume;
  uniform vec3 uBoxMin;
  uniform vec3 uBoxSize;
  uniform vec3 uColor;
  uniform float uPartMax;       // максимальное расстояние до стенки в детали (мм)
  uniform float uGap;           // сколько мм от стенки остаётся «пустыми» (контраст)
  uniform float uContrast;      // текущее значение контраста (для плотности дыма)
  uniform float uFillFloor;     // минимальная плотность внутри детали (тонкие стенки)
  uniform float uFeather;       // ширина мягкого перехода у границы зазора
  uniform float uSteps;
  uniform float uSigma;         // оптическая плотность дыма
  uniform float uGamma;
  uniform float uOpacity;       // общий уровень прозрачности облака

  varying vec3 vWorld;

  void main() {
    vec3 rayOrigin = cameraPosition;
    vec3 rayDirection = normalize(vWorld - cameraPosition);

    // пересечение с параллелепипедом детали (мировые координаты, мм)
    vec3 inverseDirection = 1.0 / rayDirection;
    vec3 t0s = (uBoxMin - rayOrigin) * inverseDirection;
    vec3 t1s = (uBoxMin + uBoxSize - rayOrigin) * inverseDirection;
    vec3 tNear = min(t0s, t1s);
    vec3 tFar = max(t0s, t1s);

    float t0 = max(max(tNear.x, tNear.y), tNear.z);
    float t1 = min(min(tFar.x, tFar.y), tFar.z);
    t0 = max(t0, 0.0);
    if (t1 <= t0) discard;

    float stepLength = (t1 - t0) / uSteps;
    // джиттер по экрану убирает полосы от фиксированного шага
    float jitter = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);

    vec3 position = rayOrigin + rayDirection * (t0 + stepLength * jitter);
    vec3 inverseSize = 1.0 / uBoxSize;

    vec4 accumulated = vec4(0.0);

    for (int i = 0; i < 96; i += 1) {
      if (float(i) >= uSteps) break;

      float raw = texture(uVolume, (position - uBoxMin) * inverseSize).r;
      position += rayDirection * stepLength;
      if (raw <= 0.002) continue; // снаружи детали — дыма нет

      float normalized = clamp((raw * 255.0 - 1.0) / 254.0, 0.0, 1.0);
      float distanceToWall = normalized * uPartMax;

      // Контраст задаёт зазор: при максимальном значении дым доходит до самой
      // стенки, при минимальном — остаётся только в самом глубоком массиве.
      float fill = smoothstep(uGap - uFeather * 0.5, uGap + uFeather * 0.5, distanceToWall);
      float strength = 0.7 + 0.4 * clamp(uContrast / 4.0, 0.0, 1.0);
      // даже у самой стенки и в тонких рёбрах остаётся «пол» плотности:
      // деталь заполняется целиком, а не только её толстые места
      float density = mix(uFillFloor, 1.0, fill);
      float sigma = density * uSigma * (0.55 + 0.45 * normalized) * strength;
      float alpha = (1.0 - exp(-sigma * stepLength)) * uOpacity;

      if (alpha > 0.0004) {
        vec3 tint = mix(uColor, vec3(1.0, 0.86, 0.55), pow(normalized, 2.2) * 0.5);
        accumulated.rgb += (1.0 - accumulated.a) * tint * alpha;
        accumulated.a += (1.0 - accumulated.a) * alpha;
      }

      if (accumulated.a > 0.995) break;
    }

    if (accumulated.a < 0.004) discard;
    gl_FragColor = vec4(accumulated.rgb / max(accumulated.a, 1e-4), accumulated.a);
  }
`;

export function createCloud(volume, color, options = {}) {
  const texture = options.texture ?? createVolumeTexture(volume);
  const size = volume.box.getSize(new THREE.Vector3());
  const center = volume.box.getCenter(new THREE.Vector3());
  const paddedSize = size.clone().addScalar(volume.cell * 2);

  // шагов тем меньше, чем «мельче» деталь — экономим без потери качества
  const diagonal = paddedSize.length();
  const steps = Math.min(72, Math.max(24, Math.round(diagonal / Math.max(volume.cell * 3, 1))));

  const material = new THREE.ShaderMaterial({
    uniforms: {
      uVolume: { value: texture },
      uBoxMin: { value: volume.box.min.clone().subScalar(volume.cell) },
      uBoxSize: { value: paddedSize },
      uColor: { value: color.clone() },
      uPartMax: { value: volume.maxDistanceUnits },
      uGap: { value: options.gap ?? 0 },
      uContrast: { value: options.contrast ?? 1 },
      uFillFloor: { value: options.fillFloor ?? 0.2 },
      uFeather: { value: options.feather ?? Math.max(volume.cell * 1.5, 0.05) },
      uSteps: { value: steps },
      uSigma: { value: options.sigma ?? 0.45 },
      uGamma: { value: 0.6 },
      uOpacity: { value: options.opacity ?? 0.85 },
    },
    vertexShader: CLOUD_VERTEX,
    fragmentShader: CLOUD_FRAGMENT,
    transparent: true,
    depthWrite: false,
    depthTest: true,
    side: THREE.BackSide,
    blending: THREE.NormalBlending,
  });

  const mesh = new THREE.Mesh(
    new THREE.BoxGeometry(paddedSize.x, paddedSize.y, paddedSize.z),
    material
  );
  mesh.position.copy(center);
  mesh.renderOrder = 1;
  mesh.name = 'mass-cloud';

  return { mesh, texture, material, volume, kind: 'cloud' };
}

/* ------------------------------------------------------------------ */
/* Частицы                                                             */
/* ------------------------------------------------------------------ */

/**
 * Точки в самых «толстых» участках: выбираем воксели, где расстояние до стенки
 * больше порога, и ставим точку с насыщенностью по глубине.
 */
export function createParticles(volume, color, options = {}) {
  // порог задаётся в миллиметрах от стенки: так контраст двигает частицы к краю
  const minDistance = Math.max(0, options.minDistance ?? (volume.maxDistanceUnits * 0.45));
  const maxPoints = options.maxPoints ?? 40_000;
  const [nx, ny, nz] = volume.dims;
  const { box, cell } = volume;
  const min = box.min;

  const positions = [];
  const colors = [];
  const baseColor = color.clone();

  const distanceScale = volume.maxDistanceUnits;
  const threshold = distanceScale > 0 ? minDistance / distanceScale : 1;

  let candidates = 0;
  for (let z = 0; z < nz; z += 1) {
    for (let y = 0; y < ny; y += 1) {
      for (let x = 0; x < nx; x += 1) {
        const raw = volume.density[nx * (y + ny * z) + x];
        if (raw === 0) continue;
        const value = (raw - 1) / 254;
        if (value < threshold) continue;
        candidates += 1;
      }
    }
  }

  if (candidates === 0) return null;

  const stride = Math.max(1, Math.round(candidates / maxPoints));

  let counter = 0;
  for (let z = 0; z < nz; z += 1) {
    for (let y = 0; y < ny; y += 1) {
      for (let x = 0; x < nx; x += 1) {
        const raw = volume.density[nx * (y + ny * z) + x];
        if (raw === 0) continue;
        const value = (raw - 1) / 254;
        if (value < threshold) continue;
        counter += 1;
        if (counter % stride !== 0) continue;

        // лёгкий сдвиг внутри вокселя, чтобы точки не выстраивались в решётку
        positions.push(
          min.x + (x + 0.5 + (Math.random() - 0.5) * 0.8) * cell,
          min.y + (y + 0.5 + (Math.random() - 0.5) * 0.8) * cell,
          min.z + (z + 0.5 + (Math.random() - 0.5) * 0.8) * cell
        );

        const intensity = Math.min(1, (value - threshold) / Math.max(0.001, 1 - threshold));
        const c = baseColor.clone().lerp(new THREE.Color(0xffe9b0), intensity * 0.65);
        colors.push(c.r, c.g, c.b);
      }
    }
  }

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));

  const material = new THREE.PointsMaterial({
    size: Math.max(cell * 2.4, 0.6),
    sizeAttenuation: true,
    vertexColors: true,
    transparent: true,
    opacity: options.opacity ?? 0.9,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
    toneMapped: false,
  });

  const points = new THREE.Points(geometry, material);
  points.renderOrder = 1;
  points.name = 'mass-particles';

  return { mesh: points, material, volume, kind: 'particles', count: positions.length / 3 };
}
