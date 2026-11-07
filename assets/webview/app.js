/**
 * STEP Viewer — просмотр .stp/.step прямо в браузере.
 *
 * Конвейер: файл → OpenCascade (occt-import-js, WASM) → треугольные сетки → three.js.
 * Всё выполняется локально на клиенте: ни сервер, ни конвертация в отдельный формат не нужны.
 * Такая же страница подходит для встраивания в WebView (Android) и iframe (Flutter Web).
 */

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

const MODEL_COLOR = 0xc7d0dd;
const EDGE_COLOR = 0x151a22;
const MAX_EDGE_FLOATS = 9_000_000;
const MAX_EDGE_TRIS = 2_500_000;
const MAX_FILE_BYTES = 220 * 1024 * 1024;

// Две темы 3D-сцены: тёмная под светлые детали, светлая под тёмные (например, чёрный анодированный металл).
const THEMES = {
  dark: { bg: 0x0a0d12, gridCenter: 0x3d4f6b, gridLine: 0x232d3c },
  light: { bg: 0xe9edf3, gridCenter: 0x94a2b8, gridLine: 0xc2cbd9 },
};

// Качество триангуляции: доля габарита + угловой шаг в радианах.
// Меньше значения — больше треугольников и глаже кривые поверхности.
const TESSELLATION = {
  linearUnit: 'millimeter',
  linearDeflectionType: 'bounding_box_ratio',
  linearDeflection: 0.0004,
  angularDeflection: 0.25,
};

const VIEWS = {
  iso: new THREE.Vector3(0.85, -1, 0.72),
  front: new THREE.Vector3(0, -1, 0),
  top: new THREE.Vector3(0, -0.0015, 1),
  right: new THREE.Vector3(1, 0, 0),
};

const dom = {
  viewport: document.getElementById('viewport'),
  openBtn: document.getElementById('open-btn'),
  fileInput: document.getElementById('file-input'),
  fitBtn: document.getElementById('fit-btn'),
  edgesBtn: document.getElementById('edges-btn'),
  themeBtn: document.getElementById('theme-btn'),
  viewButtons: Array.from(document.querySelectorAll('[data-view]')),
  empty: document.getElementById('empty'),
  info: document.getElementById('info'),
  infoTitle: document.getElementById('info-title'),
  infoStats: document.getElementById('info-stats'),
  overlay: document.getElementById('overlay'),
  overlayText: document.getElementById('overlay-text'),
  overlaySub: document.getElementById('overlay-sub'),
  toast: document.getElementById('toast'),
};

const state = {
  loadId: 0,
  occlusionWarned: false,
  model: null,
  modelGroup: null,
  edges: null,
  edgesEnabled: true,
  edgeSources: [],
  bbox: null,
  grid: null,
  triangles: 0,
  parts: 0,
  fileName: '',
  loading: false,
  timings: {},
  theme: 'dark',
  themeUserPicked: false,
  modelLuminance: 0.7,
  edgeColor: EDGE_COLOR,
};

/* ------------------------------------------------------------------ */
/* three.js setup                                                      */
/* ------------------------------------------------------------------ */

const renderer = new THREE.WebGLRenderer({
  antialias: true,
  alpha: false,
  powerPreference: 'high-performance',
});
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NeutralToneMapping;
renderer.toneMappingExposure = 1.02;
dom.viewport.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0a0d12);

const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 1000);
camera.up.set(0, 0, 1); // STEP/OCCT — Z вверх
camera.position.set(3, -3, 2);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.075;
controls.rotateSpeed = 0.85;
controls.zoomSpeed = 0.95;
controls.panSpeed = 0.9;
controls.screenSpacePanning = true;
controls.zoomToCursor = true;
controls.mouseButtons = {
  LEFT: THREE.MOUSE.ROTATE,
  MIDDLE: THREE.MOUSE.DOLLY,
  RIGHT: THREE.MOUSE.PAN,
};
controls.target.set(0, 0, 0);

renderer.domElement.addEventListener('contextmenu', (e) => e.preventDefault());

const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.02).texture;
scene.environmentIntensity = 0.55;

scene.add(new THREE.HemisphereLight(0xdce7f7, 0x1a1f27, 1.1));

const keyLight = new THREE.DirectionalLight(0xffffff, 2.1);
keyLight.position.set(0.6, -0.9, 1.1);
scene.add(keyLight);

const fillLight = new THREE.DirectionalLight(0x8fb4ff, 0.8);
fillLight.position.set(-1, 0.7, 0.4);
scene.add(fillLight);

const modelRoot = new THREE.Group();
scene.add(modelRoot);

const emptyGroupState = new THREE.Group(); // резерв под будущие вспомогательные объекты
scene.add(emptyGroupState);

function resize() {
  const w = dom.viewport.clientWidth || window.innerWidth;
  const h = dom.viewport.clientHeight || window.innerHeight;
  renderer.setSize(w, h, false);
  renderer.domElement.style.width = w + 'px';
  renderer.domElement.style.height = h + 'px';
  camera.aspect = w / Math.max(h, 1);
  camera.updateProjectionMatrix();
}

window.addEventListener('resize', resize);
if (typeof ResizeObserver !== 'undefined') new ResizeObserver(resize).observe(dom.viewport);
resize();

renderer.setAnimationLoop(() => {
  controls.update();
  renderer.render(scene, camera);
});

/* ------------------------------------------------------------------ */
/* OCCT (WASM): fallback в основном потоке + воркер                     */
/* ------------------------------------------------------------------ */

let occtPromise = null;

function getOcct() {
  if (!occtPromise) {
    if (typeof window.occtimportjs !== 'function') {
      return Promise.reject(new Error('Модуль чтения STEP (OCCT) не загрузился'));
    }
    const wasmBase = new URL('./vendor/', import.meta.url);
    occtPromise = window.occtimportjs({
      locateFile: (name) => new URL(name, wasmBase).href,
    });
  }
  return occtPromise;
}

let stepWorker = null;
let workerRequestId = 0;

function getStepWorker() {
  if (!stepWorker) {
    stepWorker = new Worker(new URL('./viewer-worker.js', import.meta.url), { name: 'step-parse' });
  }
  return stepWorker;
}

/** Разбор STEP в воркере; результат в форме, совместимой с occt.ReadStepFile. */
function parseStepInWorker(bytes, params) {
  return new Promise((resolve, reject) => {
    let worker;
    try {
      worker = getStepWorker();
    } catch (error) {
      reject(error);
      return;
    }

    const id = ++workerRequestId;

    const cleanup = () => {
      worker.removeEventListener('message', onMessage);
      worker.removeEventListener('error', onError);
    };

    const onMessage = (event) => {
      const data = event.data || {};
      if (data.id !== id) return;
      cleanup();
      if (data.error) {
        reject(new Error(data.error));
        return;
      }
      resolve({
        success: !!data.success,
        meshes: (data.meshes || []).map((mesh) => ({
          name: mesh.name,
          color: mesh.color || undefined,
          brep_faces: mesh.brep_faces || undefined,
          attributes: {
            position: { array: mesh.position },
            normal: mesh.normal ? { array: mesh.normal } : undefined,
          },
          index: { array: mesh.index },
        })),
      });
    };

    const onError = (event) => {
      cleanup();
      reject(new Error('Worker: ' + (event.message || 'ошибка инициализации')));
    };

    worker.addEventListener('message', onMessage);
    worker.addEventListener('error', onError);
    worker.postMessage({ id, bytes, params }, [bytes.buffer]);
  });
}

/* ------------------------------------------------------------------ */
/* Загрузка файлов                                                     */
/* ------------------------------------------------------------------ */

/** Единая точка входа: STEP читаем через OCCT, GLB/glTF — напрямую. */
function loadBuffer(buffer, fileName) {
  const name = fileName || 'model.stp';
  if (/\.(glb|gltf)$/i.test(name)) return loadGltfBuffer(buffer, name);
  return loadStepBuffer(buffer, name);
}

async function loadStepBuffer(buffer, fileName) {
  if (!buffer || buffer.byteLength < 32) throw new Error('Файл пустой или повреждён');
  if (buffer.byteLength > MAX_FILE_BYTES) throw new Error('Файл слишком большой для просмотра в браузере');

  const loadId = ++state.loadId;
  const t0 = performance.now();
  const marks = {};
  state.loading = true;
  state.fileName = fileName || 'model.stp';

  try {
    const bytes = new Uint8Array(buffer);
    const fallback = bytes.slice(); // на случай, если Worker недоступен
    startElapsed('Читаю STEP…', buffer.byteLength);

    let parsed = null;
    try {
      parsed = await parseStepInWorker(bytes, TESSELLATION);
      marks.worker = true;
    } catch (error) {
      console.warn('[viewer] Worker недоступен, читаю в основном потоке:', error);
    }

    if (loadId !== state.loadId) return;

    if (!parsed) {
      showOverlay('Разбираю геометрию…', formatBytes(buffer.byteLength));
      await paint();
      const occt = await getOcct();
      marks.wasm = performance.now() - t0;
      const result = occt.ReadStepFile(fallback, TESSELLATION);
      parsed = {
        success: result && result.success,
        meshes: (result?.meshes || []).map((mesh) => ({
          name: mesh.name,
          color: mesh.color,
          brep_faces: mesh.brep_faces,
          attributes: { position: mesh.attributes?.position, normal: mesh.attributes?.normal },
          index: mesh.index,
        })),
      };
      marks.parse = performance.now() - t0 - marks.wasm;
    } else {
      marks.parse = performance.now() - t0;
    }

    if (loadId !== state.loadId) return;

    if (!parsed.success || !Array.isArray(parsed.meshes) || parsed.meshes.length === 0) {
      throw new Error('Не удалось прочитать геометрию — возможно, файл не STEP или содержит только пустую сборку');
    }

    showOverlay('Строю сцену…', formatBytes(buffer.byteLength));
    await paint();

    const tBuild = performance.now();
    buildScene(parsed, loadId);
    marks.build = performance.now() - tBuild;

    finishLoad(loadId, performance.now() - t0, marks);
  } catch (error) {
    if (loadId === state.loadId) abortLoading();
    throw error;
  }
}

/** Быстрый путь: готовый GLB/glTF (например, заранее сконвертированный STEP). */
async function loadGltfBuffer(buffer, fileName) {
  const loadId = ++state.loadId;
  const t0 = performance.now();
  state.loading = true;
  state.fileName = fileName || 'model.glb';

  try {
    startElapsed('Читаю GLB…', buffer.byteLength);
    const loader = new GLTFLoader();
    const gltf = await loader.parseAsync(buffer, '');
    if (loadId !== state.loadId) return;

    const { group, sources, parts, triangles } = collectFromObject(gltf.scene);
    if (loadId !== state.loadId) return;

    installGroup(group, sources, parts, triangles, loadId);
    finishLoad(loadId, performance.now() - t0, { glb: true });
  } catch (error) {
    if (loadId === state.loadId) abortLoading();
    throw error;
  }
}

function finishLoad(loadId, elapsed, marks) {
  if (loadId !== state.loadId) return;
  stopElapsed();
  hideOverlay();
  state.loading = false;
  dom.empty.classList.add('is-hidden');
  updateInfo(elapsed);
  fitView();
  marks.total = elapsed;
  state.timings = marks;
}

function abortLoading() {
  stopElapsed();
  hideOverlay();
  state.loading = false;
}

/** Общие объекты (three.js GLTFLoader) → та же сцена, что и после STEP. */
function collectFromObject(object) {
  const group = new THREE.Group();
  group.name = 'glb-model';
  const sources = [];
  let parts = 0;
  let triangles = 0;

  object.updateMatrixWorld(true);
  object.traverse((child) => {
    if (!child.isMesh || !child.geometry) return;
    const geometry = child.geometry.clone();
    geometry.applyMatrix4(child.matrixWorld);
    if (!geometry.index) {
      const count = geometry.getAttribute('position').count;
      const index = new Uint32Array(count);
      for (let i = 0; i < count; i += 1) index[i] = i;
      geometry.setIndex(new THREE.BufferAttribute(index, 1));
    }
    if (!geometry.getAttribute('normal')) geometry.computeVertexNormals();

    const materials = Array.isArray(child.material) ? child.material : [child.material];
    materials.forEach((material) => {
      if (material && material.side !== undefined) material.side = THREE.DoubleSide;
    });

    const mesh = new THREE.Mesh(geometry, child.material);
    mesh.name = child.name || 'part';
    group.add(mesh);
    parts += 1;
    triangles += geometry.index.count / 3;
    sources.push({ geometry, faces: null });
  });

  return { group, sources, parts, triangles };
}

function buildScene(result, loadId) {
  disposeModel();

  const group = new THREE.Group();
  group.name = 'step-model';
  const sources = [];
  let parts = 0;
  let triangles = 0;

  for (const meshData of result.meshes) {
    const built = buildMeshFromOcct(meshData);
    if (!built) continue;
    group.add(built.mesh);
    parts += 1;
    triangles += built.triangleCount;
    sources.push({ geometry: built.geometry, faces: built.faces });
    if (loadId !== state.loadId) return;
  }

  state.model = result;
  installGroup(group, sources, parts, triangles, loadId);
}

/** Ставит готовую группу в сцену: тема, сетка, рёбра, статистика. */
function installGroup(group, sources, parts, triangles, loadId) {
  if (!parts) {
    throw new Error('В файле не найдено поверхностей для отображения');
  }

  // Масштаб не нормализуем: STEP обычно уже в мм, камера подгоняется по габаритам.
  modelRoot.add(group);

  state.modelGroup = group;
  state.edgeSources = sources;
  state.parts = parts;
  state.triangles = triangles;
  state.edges = null;
  state.modelLuminance = computeLuminance(group);

  // Тёмная деталь на тёмном фоне не видна — автоматически переключаем фон.
  applyTheme(state.themeUserPicked ? state.theme : state.modelLuminance < 0.34 ? 'light' : 'dark', true);

  if (state.edgesEnabled && triangles <= MAX_EDGE_TRIS) {
    buildEdges(loadId);
  } else if (state.edgesEnabled) {
    setEdgesEnabled(false);
    showToast('Модель очень подробная — рёбра отключены для производительности');
  }
}

function buildMeshFromOcct(meshData) {
  const position = meshData?.attributes?.position?.array;
  const index = meshData?.index?.array;
  if (!position || !index || index.length < 3) return null;

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(position, 3));

  const normal = meshData?.attributes?.normal?.array;
  if (normal && normal.length === position.length) {
    geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normal, 3));
  }

  geometry.setIndex(new THREE.BufferAttribute(Uint32Array.from(index), 1));

  const faces = Array.isArray(meshData.brep_faces) && meshData.brep_faces.length ? meshData.brep_faces : null;
  const baseColor = occtColor(meshData.color) ?? new THREE.Color(MODEL_COLOR);

  const faceColors = faces ? faces.map((f) => occtColor(f.color)) : [];
  const hasFaceColors = faceColors.some((c) => c !== null);

  let material;
  if (hasFaceColors) {
    const materials = [makeMaterial(baseColor)];
    for (const color of faceColors) materials.push(makeMaterial(color ?? baseColor));
    applyFaceGroups(geometry, faces, index.length / 3);
    material = materials;
  } else {
    material = makeMaterial(baseColor);
  }

  const mesh = new THREE.Mesh(geometry, material);
  mesh.name = meshData.name || 'part';

  return { mesh, geometry, faces, triangleCount: index.length / 3 };
}

function makeMaterial(color) {
  return new THREE.MeshStandardMaterial({
    color: color.clone ? color.clone() : new THREE.Color(color),
    metalness: 0.18,
    roughness: 0.52,
    envMapIntensity: 1,
    // В CAD-моделях встречаются вывернутые грани; двусторонний режим надёжнее.
    side: THREE.DoubleSide,
  });
}

function occtColor(rgb) {
  if (!rgb || rgb.length < 3) return null;
  // OCCT отдаёт sRGB-компоненты 0..1
  return new THREE.Color().setRGB(rgb[0], rgb[1], rgb[2], THREE.SRGBColorSpace);
}

/** Разбивает геометрию на группы по граням B-rep, чтобы пер-гранные цвета работали. */
function applyFaceGroups(geometry, faces, triangleCount) {
  let groupIndex = 0;
  let triangleIndex = 0;
  while (triangleIndex < triangleCount) {
    let lastTriangle;
    let materialIndex;
    if (groupIndex >= faces.length) {
      lastTriangle = triangleCount;
      materialIndex = 0;
    } else if (triangleIndex < faces[groupIndex].first) {
      lastTriangle = Math.min(faces[groupIndex].first, triangleCount);
      materialIndex = 0;
    } else {
      lastTriangle = Math.min(faces[groupIndex].last + 1, triangleCount);
      materialIndex = groupIndex + 1;
      groupIndex += 1;
    }
    if (lastTriangle <= triangleIndex) lastTriangle = triangleIndex + 1;
    geometry.addGroup(triangleIndex * 3, (lastTriangle - triangleIndex) * 3, materialIndex);
    triangleIndex = lastTriangle;
  }
}

/* ------------------------------------------------------------------ */
/* Рёбра (границы B-rep-граней)                                        */
/* ------------------------------------------------------------------ */

async function buildEdges(loadId) {
  const pieces = [];
  let totalFloats = 0;
  let work = 0;

  for (const source of state.edgeSources) {
    if (loadId !== state.loadId || !state.edgesEnabled) return;

    const { geometry, faces } = source;
    const indexAttribute = geometry.getIndex();
    if (!indexAttribute) continue;

    const indexArray = indexAttribute.array;
    const triangleCount = indexArray.length / 3;
    const positionAttribute = geometry.getAttribute('position');
    const localPieces = [];

    if (faces && faces.length) {
      for (let i = 0; i < faces.length; i += 1) {
        if (loadId !== state.loadId || !state.edgesEnabled) return;

        const face = faces[i];
        const first = Math.max(0, Math.min(triangleCount, face.first | 0));
        const last = Math.max(first, Math.min(triangleCount - 1, face.last | 0));
        if (last < first) continue;

        const patch = new THREE.BufferGeometry();
        patch.setAttribute('position', positionAttribute);
        patch.setIndex(new THREE.BufferAttribute(indexArray.subarray(first * 3, (last + 1) * 3), 1));

        const edgesGeometry = new THREE.EdgesGeometry(patch, 180); // 180° → только настоящие границы грани
        const array = edgesGeometry.getAttribute('position')?.array;
        if (array && array.length) {
          localPieces.push(array);
          totalFloats += array.length;
        }
        edgesGeometry.dispose();
        patch.dispose();

        if (totalFloats > MAX_EDGE_FLOATS) break;
        work += 1;
        if (work % 24 === 0) await nextFrame();
      }
    } else {
      const edgesGeometry = new THREE.EdgesGeometry(geometry, 24);
      const array = edgesGeometry.getAttribute('position')?.array;
      if (array && array.length) localPieces.push(array);
      edgesGeometry.dispose();
    }

    if (localPieces.length) pieces.push(concatFloat32(localPieces));
    if (totalFloats > MAX_EDGE_FLOATS) break;
    await nextFrame();
  }

  if (loadId !== state.loadId || !state.edgesEnabled) return;

  const merged = concatFloat32(pieces);
  if (merged.length === 0) return;

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(merged, 3));

  const material = new THREE.LineBasicMaterial({
    color: state.edgeColor,
    transparent: true,
    opacity: 0.9,
    depthWrite: false,
  });

  const lines = new THREE.LineSegments(geometry, material);
  lines.name = 'edges';
  lines.renderOrder = 2;

  state.edges = lines;
  if (state.modelGroup) state.modelGroup.add(lines);
  renderer.render(scene, camera);
}

function concatFloat32(pieces) {
  if (!pieces.length) return new Float32Array(0);
  let total = 0;
  for (const piece of pieces) total += piece.length;
  const out = new Float32Array(total);
  let offset = 0;
  for (const piece of pieces) {
    out.set(piece, offset);
    offset += piece.length;
  }
  return out;
}

function setEdgesEnabled(enabled) {
  state.edgesEnabled = enabled;
  dom.edgesBtn.classList.toggle('is-on', enabled);

  if (!enabled) {
    if (state.edges) {
      state.edges.removeFromParent();
      disposeObject(state.edges);
      state.edges = null;
    }
    return;
  }

  if (state.modelGroup && !state.edges) buildEdges(state.loadId);
}

/* ------------------------------------------------------------------ */
/* Камера, сетка, габариты                                             */
/* ------------------------------------------------------------------ */

function fitView() {
  const box = new THREE.Box3().setFromObject(modelRoot);
  if (box.isEmpty()) return;
  state.bbox = box;

  const center = box.getCenter(new THREE.Vector3());
  const radius = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 1e-6);

  const direction = camera.position.clone().sub(controls.target);
  if (direction.lengthSq() < 1e-12) direction.copy(VIEWS.iso);
  direction.normalize();

  const distance = fitDistance(box, center, direction);

  camera.position.copy(center).addScaledVector(direction, distance);
  controls.target.copy(center);
  applyClipPlanes(radius, distance);
  controls.minDistance = radius * 0.02;
  controls.maxDistance = radius * 30;
  controls.update();
}

function setView(name) {
  const box = state.bbox;
  if (!box) return;

  const center = box.getCenter(new THREE.Vector3());
  const radius = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 1e-6);
  const direction = (VIEWS[name] || VIEWS.iso).clone().normalize();
  const distance = fitDistance(box, center, direction);

  camera.position.copy(center).addScaledVector(direction, distance);
  controls.target.copy(center);
  applyClipPlanes(radius, distance);
  controls.update();

  dom.viewButtons.forEach((btn) => btn.classList.toggle('is-on', btn.dataset.view === name));
}

/**
 * Минимальная дистанция, при которой все 8 углов габарита попадают в кадр.
 * Точнее, чем по описанной сфере: длинные тонкие детали заполняют экран.
 */
function fitDistance(box, center, direction) {
  const vFov = (camera.fov * Math.PI) / 180;
  const tanV = Math.tan(vFov / 2);
  const tanH = tanV * Math.max(camera.aspect, 0.05);

  const worldUp = new THREE.Vector3(0, 0, 1);
  let right = new THREE.Vector3().crossVectors(worldUp, direction);
  if (right.lengthSq() < 1e-10) right = new THREE.Vector3(1, 0, 0);
  right.normalize();
  const up = new THREE.Vector3().crossVectors(direction, right).normalize();

  const corner = new THREE.Vector3();
  let distance = 0;
  for (let i = 0; i < 8; i += 1) {
    corner.set(i & 1 ? box.max.x : box.min.x, i & 2 ? box.max.y : box.min.y, i & 4 ? box.max.z : box.min.z);
    const v = corner.sub(center);
    const depth = v.dot(direction);
    const alongRight = Math.abs(v.dot(right));
    const alongUp = Math.abs(v.dot(up));
    distance = Math.max(distance, depth + alongRight / tanH, depth + alongUp / tanV);
  }

  return Math.max(distance, 1e-6) * 1.04;
}

function applyClipPlanes(radius, distance) {
  camera.near = Math.max(distance / 400, radius / 5000, 0.01);
  camera.far = Math.max(distance * 40, radius * 60, 100);
  camera.updateProjectionMatrix();
}

function updateGrid() {
  if (state.grid) {
    state.grid.removeFromParent();
    disposeObject(state.grid);
    state.grid = null;
  }

  const box = new THREE.Box3().setFromObject(modelRoot);
  if (box.isEmpty()) return;

  const size = box.getSize(new THREE.Vector3());
  const maxDim = Math.max(size.x, size.y, size.z, 1e-3);
  const cell = Math.pow(10, Math.floor(Math.log10(maxDim / 8)));
  const gridSize = cell * 20;
  const theme = THEMES[state.theme] || THEMES.dark;

  const grid = new THREE.GridHelper(gridSize, 20, theme.gridCenter, theme.gridLine);
  grid.rotation.x = Math.PI / 2; // из XZ в XY (Z вверх)
  grid.position.set(box.getCenter(new THREE.Vector3()).x, box.getCenter(new THREE.Vector3()).y, box.min.z);
  const materials = Array.isArray(grid.material) ? grid.material : [grid.material];
  materials.forEach((m) => {
    m.transparent = true;
    m.opacity = state.theme === 'light' ? 0.7 : 0.5;
    m.depthWrite = false;
  });
  grid.renderOrder = -1;

  state.grid = grid;
  scene.add(grid);
}

/* ------------------------------------------------------------------ */
/* Тема сцены (фон/сетка/рёбра)                                        */
/* ------------------------------------------------------------------ */

/** Средняя яркость материалов модели (0 — чёрный, 1 — белый). */
function computeLuminance(group) {
  let weighted = 0;
  let weight = 0;

  group.traverse((child) => {
    if (!child.isMesh || !child.geometry) return;
    const position = child.geometry.getAttribute('position');
    const count = child.geometry.index ? child.geometry.index.count / 3 : position ? position.count / 3 : 0;
    const materials = Array.isArray(child.material) ? child.material : [child.material];
    for (const material of materials) {
      if (!material || !material.color) continue;
      const c = material.color;
      weighted += (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) * count;
      weight += count;
    }
  });

  return weight > 0 ? weighted / weight : 0.7;
}

function applyTheme(theme, silent) {
  state.theme = theme === 'light' ? 'light' : 'dark';
  const palette = THEMES[state.theme];

  scene.background = new THREE.Color(palette.bg);

  // Рёбра должны контрастировать с деталью, а не с фоном.
  state.edgeColor = state.modelLuminance < 0.34
    ? 0xc3ccda
    : state.theme === 'light'
      ? 0x3a4250
      : EDGE_COLOR;
  if (state.edges && state.edges.material) state.edges.material.color.setHex(state.edgeColor);

  updateGrid();
  renderer.toneMappingExposure = state.theme === 'light' ? 0.95 : 1.02;
  dom.themeBtn?.classList.toggle('is-on', state.theme === 'light');
  document.documentElement.dataset.theme = state.theme;

  if (!silent) state.themeUserPicked = true;
  renderer.render(scene, camera);
}

/* ------------------------------------------------------------------ */
/* UI                                                                  */
/* ------------------------------------------------------------------ */

function showOverlay(text, sub) {
  dom.overlayText.textContent = text || '';
  dom.overlaySub.textContent = sub || '';
  dom.overlay.hidden = false;
}

function hideOverlay() {
  dom.overlay.hidden = true;
}

/* Оверлей с «живым» счётчиком времени: разбор STEP может идти десятки секунд. */
let elapsedTimer = 0;
let elapsedStart = 0;
let elapsedLabel = '';

function startElapsed(label, bytes) {
  elapsedLabel = label;
  elapsedStart = performance.now();
  showOverlay(label, formatBytes(bytes));
  stopElapsed(false);
  elapsedTimer = setInterval(() => {
    const seconds = (performance.now() - elapsedStart) / 1000;
    dom.overlaySub.textContent = `${formatBytes(bytes)} · ${seconds.toFixed(0)} с`;
  }, 250);
}

function stopElapsed(clearSub = true) {
  if (elapsedTimer) {
    clearInterval(elapsedTimer);
    elapsedTimer = 0;
  }
  if (clearSub) dom.overlaySub.textContent = '';
}

let toastTimer = 0;

function showToast(message) {
  dom.toast.textContent = message;
  dom.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    dom.toast.hidden = true;
  }, 6000);
}

function updateInfo(elapsedMs) {
  const name = state.fileName || 'model.stp';
  dom.infoTitle.textContent = name;
  dom.infoTitle.title = name;

  const parts = formatNumber(state.parts);
  const tris = formatNumber(state.triangles);
  const time = elapsedMs ? `${(elapsedMs / 1000).toFixed(1)} с` : '—';

  let dims = '';
  const box = state.bbox;
  if (box && !box.isEmpty()) {
    const s = box.getSize(new THREE.Vector3());
    dims = ` · габарит ${formatNumber(s.x)} × ${formatNumber(s.y)} × ${formatNumber(s.z)}`;
  }

  dom.infoStats.textContent = `${parts} тел · ${tris} треугольников · ${time}${dims}`;
  dom.info.classList.remove('is-empty');
}

function formatNumber(value) {
  return Math.round(value).toLocaleString('ru-RU');
}

function formatBytes(bytes) {
  const mb = bytes / (1024 * 1024);
  return mb >= 1 ? `${mb.toFixed(1)} МБ` : `${Math.max(1, Math.round(bytes / 1024))} КБ`;
}

function paint() {
  return new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
}

function nextFrame() {
  return new Promise((resolve) => requestAnimationFrame(resolve));
}

/* ------------------------------------------------------------------ */
/* Загрузка через файл / drag&drop / примеры                           */
/* ------------------------------------------------------------------ */

async function loadFile(file) {
  if (!file) return;
  try {
    const buffer = await file.arrayBuffer();
    await loadBuffer(buffer, file.name);
  } catch (err) {
    fail(err);
  }
}

async function loadUrl(url, name) {
  try {
    showOverlay('Скачиваю файл…', url);
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Не удалось скачать файл (HTTP ${response.status})`);
    const buffer = await response.arrayBuffer();
    hideOverlay();
    await loadBuffer(buffer, name || url.split('/').pop());
  } catch (err) {
    fail(err);
  }
}

function fail(err) {
  console.error(err);
  hideOverlay();
  state.loading = false;
  const message = err && err.message ? err.message : String(err);
  showToast('Не удалось открыть файл: ' + message);
}

/* ------------------------------------------------------------------ */
/* Очистка                                                             */
/* ------------------------------------------------------------------ */

function disposeObject(object) {
  object.traverse((child) => {
    if (child.geometry) child.geometry.dispose();
    const material = child.material;
    if (Array.isArray(material)) material.forEach((m) => m.dispose());
    else if (material) material.dispose();
  });
  object.removeFromParent?.();
}

function disposeModel() {
  state.modelGroup = null;
  state.edgeSources = [];
  state.edges = null;
  state.model = null;
  state.bbox = null;
  for (const child of [...modelRoot.children]) {
    disposeObject(child);
    modelRoot.remove(child);
  }
  if (state.grid) {
    disposeObject(state.grid);
    state.grid = null;
  }
}

/* ------------------------------------------------------------------ */
/* Обработчики                                                         */
/* ------------------------------------------------------------------ */

dom.openBtn.addEventListener('click', () => dom.fileInput.click());

dom.fileInput.addEventListener('change', () => {
  const file = dom.fileInput.files?.[0];
  dom.fileInput.value = '';
  if (file) loadFile(file);
});

dom.fitBtn.addEventListener('click', () => fitView());

dom.edgesBtn.addEventListener('click', () => setEdgesEnabled(!state.edgesEnabled));

dom.themeBtn?.addEventListener('click', () => applyTheme(state.theme === 'light' ? 'dark' : 'light'));

dom.viewButtons.forEach((btn) => {
  btn.addEventListener('click', () => setView(btn.dataset.view));
});

document.querySelectorAll('[data-sample]').forEach((btn) => {
  btn.addEventListener('click', () => loadUrl(btn.dataset.sample));
});

let dragDepth = 0;

window.addEventListener('dragenter', (event) => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  dragDepth += 1;
  document.body.classList.add('is-dragging');
});

window.addEventListener('dragover', (event) => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = 'copy';
});

window.addEventListener('dragleave', (event) => {
  if (!hasFiles(event)) return;
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0) document.body.classList.remove('is-dragging');
});

window.addEventListener('drop', (event) => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  dragDepth = 0;
  document.body.classList.remove('is-dragging');
  const file = event.dataTransfer?.files?.[0];
  if (file) loadFile(file);
});

function hasFiles(event) {
  const types = event.dataTransfer?.types;
  return !!types && Array.from(types).includes('Files');
}

window.addEventListener('keydown', (event) => {
  if (event.target instanceof HTMLInputElement) return;
  const key = event.key.toLowerCase();
  if (key === 'f') { event.preventDefault(); fitView(); }
  else if (key === 'e') { event.preventDefault(); setEdgesEnabled(!state.edgesEnabled); }
  else if (key === 'o') { event.preventDefault(); dom.fileInput.click(); }
  else if (key === 't') { event.preventDefault(); applyTheme(state.theme === 'light' ? 'dark' : 'light'); }
  else if (key === '1') setView('iso');
  else if (key === '2') setView('front');
  else if (key === '3') setView('top');
  else if (key === '4') setView('right');
});

/* ------------------------------------------------------------------ */
/* Публичное API для встраивания (Flutter WebView / iframe)            */
/* ------------------------------------------------------------------ */

window.StepViewer = {
  version: '1.0.0',
  openPicker: () => dom.fileInput.click(),
  loadArrayBuffer: (buffer, name) =>
    loadBuffer(buffer, name || 'model.stp').catch(fail),
  loadBase64: (base64, name) => {
    try {
      const binary = atob(base64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
      return loadBuffer(bytes.buffer, name || 'model.stp').catch(fail);
    } catch (err) {
      fail(err);
    }
  },
  loadUrl: (url, name) => loadUrl(url, name),
  fit: () => fitView(),
  setView: (name) => setView(name),
  setEdges: (enabled) => setEdgesEnabled(!!enabled),
  setTheme: (theme) => applyTheme(theme === 'light' ? 'light' : 'dark'),
  autoTheme: () => {
    state.themeUserPicked = false;
    applyTheme(state.modelLuminance < 0.34 ? 'light' : 'dark', true);
  },
  isReady: () => !!state.modelGroup,
  getState: () => ({
    ready: !!state.modelGroup,
    fileName: state.fileName,
    parts: state.parts,
    triangles: state.triangles,
    edges: !!state.edges,
    camera: camera.position.toArray(),
    target: controls.target.toArray(),
    bbox: state.bbox ? { min: state.bbox.min.toArray(), max: state.bbox.max.toArray() } : null,
    timings: state.timings,
    theme: state.theme,
    luminance: +state.modelLuminance.toFixed(3),
  }),
};

/* ------------------------------------------------------------------ */
/* Автозагрузка (?model=...)                                           */
/* ------------------------------------------------------------------ */

// На тач-устройствах перетаскивания нет — подсказываем кнопку.
if (window.matchMedia && window.matchMedia('(hover: none)').matches) {
  const sub = document.getElementById('empty-sub');
  if (sub) sub.textContent = 'Нажмите «Открыть STEP» или выберите пример — файл обрабатывается локально, на устройстве';
}

const params = new URLSearchParams(window.location.search);

// Для встраивания (Тильда/iframe): ?ui=min — только 3D, без панелей и подсказок.
if (params.get('ui') === 'min' || params.get('minimal') === '1') {
  document.body.classList.add('ui-minimal');
}
const modelUrl = params.get('model') || params.get('url');
if (modelUrl) {
  loadUrl(modelUrl, params.get('name') || undefined);
}

