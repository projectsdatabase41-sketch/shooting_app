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
import { MassTools, scanStepMaterials } from './mass.js';
import {
  hashBytes,
  readCache,
  writeCache,
  deserializeMeshes,
  cacheStats,
  clearCache,
} from './cache.js';

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
/**
 * Два уровня триангуляции: черновик открывается заметно быстрее, точный —
 * даёт полную детализацию. Большие файлы сначала показываем черновиком,
 * а точное качество включается кнопкой (или сразу из кэша).
 */
const TESSELLATION_PRESETS = {
  draft: {
    linearUnit: 'millimeter',
    linearDeflectionType: 'bounding_box_ratio',
    linearDeflection: 0.008,
    angularDeflection: 0.7,
  },
  fine: {
    linearUnit: 'millimeter',
    linearDeflectionType: 'bounding_box_ratio',
    linearDeflection: 0.0004,
    angularDeflection: 0.25,
  },
};

/** Файлы больше 4 МБ сначала открываются черновиком. */
const DRAFT_THRESHOLD_BYTES = 4 * 1024 * 1024;

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
  edgesBtn: document.getElementById('edges-btn'),
  themeBtn: document.getElementById('theme-btn'),
  // Блок ракурсов ([data-view]) убран из разметки (замечание 1 владельца
  // 24.11: виды могут быть перепутаны) — отдельного dom-поля больше нет.
  empty: document.getElementById('empty'),
  info: document.getElementById('info'),
  infoTitle: document.getElementById('info-title'),
  infoStats: document.getElementById('info-stats'),
  overlay: document.getElementById('overlay'),
  overlayText: document.getElementById('overlay-text'),
  overlaySub: document.getElementById('overlay-sub'),
  toast: document.getElementById('toast'),
  qualityBtn: document.getElementById('quality-btn'),
  cacheClearBtn: document.getElementById('cache-clear'),
  cacheInfo: document.getElementById('cache-info'),
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
  userInteracted: false,
  theme: 'dark',
  themeUserPicked: false,
  modelLuminance: 0.7,
  edgeColor: EDGE_COLOR,
  quality: 'fine',
  qualityUserChoice: null,
  lastBuffer: null,
  currentHash: '',
  modelKind: 'step',
  cacheHit: false,
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

// Если пользователь ещё не трогал камеру, окно можно ресайзить — вписываем заново.
controls.addEventListener('start', () => {
  state.userInteracted = true;
});

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

// Масса, центр тяжести, карта массы
/* ------------------------------------------------------------------ */
/* Чувствительность мыши (сохраняется в localStorage)                  */
/* ------------------------------------------------------------------ */

const SENSITIVITY_KEY = 'stepViewer.sensitivity';
const SENSITIVITY_DEFAULTS = { rotate: 1, pan: 1, zoom: 1 };
const BASE_SPEEDS = { rotate: 0.85, pan: 0.9, zoom: 0.95 };

function loadSensitivity() {
  try {
    const raw = localStorage.getItem(SENSITIVITY_KEY);
    if (raw) {
      const parsed = JSON.parse(raw);
      return {
        rotate: clampSensitivity(parsed.rotate),
        pan: clampSensitivity(parsed.pan),
        zoom: clampSensitivity(parsed.zoom),
      };
    }
  } catch {
    // битые настройки — берём значения по умолчанию
  }
  return { ...SENSITIVITY_DEFAULTS };
}

function clampSensitivity(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return 1;
  return Math.min(2.5, Math.max(0.2, number));
}

const sensitivity = loadSensitivity();

function applySensitivity() {
  controls.rotateSpeed = BASE_SPEEDS.rotate * sensitivity.rotate;
  controls.panSpeed = BASE_SPEEDS.pan * sensitivity.pan;
  controls.zoomSpeed = BASE_SPEEDS.zoom * sensitivity.zoom;
}

function saveSensitivity() {
  try {
    localStorage.setItem(SENSITIVITY_KEY, JSON.stringify(sensitivity));
  } catch {
    // приватный режим — не страшно
  }
}

applySensitivity();

const massTools = new MassTools({
  scene,
  modelRoot,
  getTheme: () => state.theme,
  setTheme: (theme) => applyTheme(theme, true),
});

function resize() {
  const w = dom.viewport.clientWidth || window.innerWidth;
  const h = dom.viewport.clientHeight || window.innerHeight;
  renderer.setSize(w, h, false);
  renderer.domElement.style.width = w + 'px';
  renderer.domElement.style.height = h + 'px';
  camera.aspect = w / Math.max(h, 1);
  camera.updateProjectionMatrix();

  // Окно изменило размер до первого движения камеры (например, развернулось
  // на весь экран после загрузки модели) — вписываем модель заново.
  if (state.modelGroup && !state.userInteracted) fitView();
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

    // передаём воркеру копию: исходные байты нужны для кэша и повторного разбора
    const transferable = bytes.slice();
    worker.postMessage({ id, bytes: transferable, params }, [transferable.buffer]);
  });
}

/* ------------------------------------------------------------------ */
/* Загрузка файлов                                                     */
/* ------------------------------------------------------------------ */

/** Единая точка входа: STEP читаем через OCCT, GLB/glTF — напрямую. */
function loadBuffer(buffer, fileName) {
  const name = fileName || 'model.stp';
  if (/\.(glb|gltf)$/i.test(name)) return loadGltfBuffer(buffer, name);

  // новый файл — снова выбираем качество автоматически
  state.currentHash = '';
  state.qualityUserChoice = null;
  state.cacheHit = false;
  return loadStepBuffer(buffer, name);
}

async function loadStepBuffer(buffer, fileName, options = {}) {
  if (!buffer || buffer.byteLength < 32) throw new Error('Файл пустой или повреждён');
  if (buffer.byteLength > MAX_FILE_BYTES) throw new Error('Файл слишком большой для просмотра в браузере');

  const loadId = ++state.loadId;
  const t0 = performance.now();
  const marks = {};
  state.loading = true;
  state.fileName = fileName || 'model.stp';
  state.lastBuffer = buffer;
  state.modelKind = 'step';

  const quality = options.quality
    || state.qualityUserChoice
    || pickQuality(buffer.byteLength);
  state.quality = quality;

  try {
    const bytes = new Uint8Array(buffer);
    const hash = state.currentHash || (await hashBytes(bytes));
    state.currentHash = hash;

    showQualityState(quality, false);
    startElapsed(
      quality === 'draft' ? 'Черновой разбор STEP…' : 'Точный разбор STEP…',
      buffer.byteLength
    );

    // 1) сначала смотрим кэш разобранной геометрии
    let cached = await readCache(hash, quality);
    if (loadId !== state.loadId) return;

    // если точная версия уже лежит в кэше — берём её, даже когда файл большой
    const autoQuality = !options.quality && !state.qualityUserChoice;
    if (!cached && autoQuality && quality === 'draft') {
      const fineCache = await readCache(hash, 'fine');
      if (fineCache) {
        cached = fineCache;
        quality = 'fine';
        state.quality = 'fine';
        showQualityState('fine', true);
      }
    }

    if (cached) {
      marks.cache = true;
      marks.cacheBytes = cached.size || 0;
      showOverlay('Беру из кэша…', formatBytes(cached.size || 0));
      await paint();
      const result = deserializeMeshes(cached.data);
      const tBuild = performance.now();
      buildScene(result, loadId);
      marks.build = performance.now() - tBuild;
      finishLoad(loadId, performance.now() - t0, marks);
      return;
    }

    const fallback = bytes.slice(); // на случай, если Worker недоступен
    const tessellation = TESSELLATION_PRESETS[quality];
    let parsed = null;

    try {
      parsed = await parseStepInWorker(bytes, tessellation);
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
      const result = occt.ReadStepFile(fallback, tessellation);
      parsed = {
        success: result && result.success,
        materials: scanStepMaterials(fallback),
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

    // 2) сохраняем в кэш, чтобы следующее открытие было мгновенным
    if (parsed.meshes.length) {
      void writeCache(hash, quality, state.fileName, parsed.meshes).then((bytes) => {
        if (bytes) console.info(`[cache] сохранено ${formatBytes(bytes)} (${quality})`);
      });
    }
  } catch (error) {
    if (loadId === state.loadId) abortLoading();
    throw error;
  }
}

/** Выбор качества: большие файлы сначала показываем черновиком. */
function pickQuality(bytesLength) {
  if (state.qualityUserChoice) return state.qualityUserChoice;
  // Отзыв владельца 26.11: по умолчанию SD (черновик) — открывается быстро,
  // HD пользователь включает кнопкой. Большие файлы больше не решают за него.
  return 'draft';
}

/**
 * Переключение качества уже загруженного STEP: сначала кэш, иначе повторный разбор.
 */
async function switchQuality(quality) {
  if (!state.lastBuffer || state.modelKind !== 'step') return;
  if (state.quality === quality) return;

  state.qualityUserChoice = quality;
  if (quality === 'fine' && state.lastBuffer.byteLength > DRAFT_THRESHOLD_BYTES) {
    showToast('Точный разбор — это повторное чтение файла, может занять десятки секунд');
  }

  try {
    await loadStepBuffer(state.lastBuffer, state.fileName, { quality });
  } catch (error) {
    fail(error);
  }
}

function showQualityState(quality, fromCache) {
  if (!dom.qualityBtn) return;
  dom.qualityBtn.hidden = state.modelKind !== 'step';
  // Отзыв владельца 26.11: качество называется SD/HD, а не «черновик/точно».
  dom.qualityBtn.textContent = quality === 'draft' ? 'SD' : 'HD';
  dom.qualityBtn.classList.toggle('is-on', quality === 'fine');
  dom.qualityBtn.title = fromCache
    ? 'Геометрия взята из кэша — переключение мгновенное'
    : 'SD — быстрый черновик, HD — полная точность (может занять до минуты)';
}
/** Быстрый путь: готовый GLB/glTF (например, заранее сконвертированный STEP). */
async function loadGltfBuffer(buffer, fileName) {
  const loadId = ++state.loadId;
  const t0 = performance.now();
  state.loading = true;
  state.fileName = fileName || 'model.glb';
  state.modelKind = 'glb';
  state.lastBuffer = null;
  state.currentHash = '';
  state.cacheHit = false;
  showQualityState('fine', false);

  try {
    startElapsed('Читаю GLB…', buffer.byteLength);
    const loader = new GLTFLoader();
    const gltf = await loader.parseAsync(buffer, '');
    if (loadId !== state.loadId) return;

    const { group, sources, parts, triangles } = collectFromObject(gltf.scene);
    if (loadId !== state.loadId) return;

    installGroup(group, sources, parts, triangles, loadId, []);
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
  state.cacheHit = !!marks.cache;
  updateInfo(elapsed);
  fitView();
  marks.total = elapsed;
  marks.quality = state.quality;
  state.timings = marks;
  showQualityState(state.quality, !!marks.cache);
  updateCacheInfo();
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
  installGroup(group, sources, parts, triangles, loadId, []);
}

/** Ставит готовую группу в сцену: тема, сетка, рёбра, статистика. */
function installGroup(group, sources, parts, triangles, loadId, materials = []) {
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
  state.userInteracted = false;
  massTools.onModelInstalled(group, { materials });

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
  } else {
    // кэш не хранит нормали — считаем их сами (CAD-сетка уже с разрывом граней)
    geometry.computeVertexNormals();
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

  // Кнопок ракурсов в шапке больше нет (убраны, замечание 1 владельца
  // 24.11): подсветка .is-on не нужна, состояние никуда не рисуем.
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

const LOADING_TIPS = [
  'Извлекаю геометрию из файла…',
  'Разбираю сборку на детали…',
  'Считаю поверхности и кромки…',
  'Упрощаю сетку для быстрого показа…',
  'Тяжёлая сборка — это нормально, ждём до 4 минут…',
  'Почти готово: собираю сцену…',
];
let overlayTipTimer = 0;
let overlayTipIndex = 0;

function startOverlayTips() {
  const tipEl = document.getElementById('overlay-tip');
  if (!tipEl) return;
  overlayTipIndex = 0;
  tipEl.textContent = LOADING_TIPS[0];
  clearInterval(overlayTipTimer);
  // Отзыв владельца 26.11: подсказки меняются раз в 10 секунд, чтобы при
  // тяжёлом файле не казалось, что приложение зависло.
  overlayTipTimer = setInterval(() => {
    overlayTipIndex = (overlayTipIndex + 1) % LOADING_TIPS.length;
    tipEl.textContent = LOADING_TIPS[overlayTipIndex];
  }, 10000);
}

function stopOverlayTips() {
  clearInterval(overlayTipTimer);
  overlayTipTimer = 0;
}

function showOverlay(text, sub) {
  dom.overlayText.textContent = text || '';
  dom.overlaySub.textContent = sub || '';
  dom.overlay.hidden = false;
  startOverlayTips();
}

function hideOverlay() {
  dom.overlay.hidden = true;
  stopOverlayTips();
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
  // Отзыв владельца 26.11: внизу не показываем ни имя файла (это ID на
  // Google Диске), ни время генерации. Только состав модели.
  dom.infoTitle.textContent = state.parts ? 'Модель загружена' : 'Модель не загружена';
  dom.infoTitle.title = '';

  const parts = formatNumber(state.parts);
  const tris = formatNumber(state.triangles);

  let dims = '';
  const box = state.bbox;
  if (box && !box.isEmpty()) {
    const s = box.getSize(new THREE.Vector3());
    dims = ` · габарит ${formatNumber(s.x)} × ${formatNumber(s.y)} × ${formatNumber(s.z)}`;
  }

  let extra = '';
  if (state.modelKind === 'step') {
    extra += state.quality === 'draft' ? ' · SD' : ' · HD';
    if (state.cacheHit) extra += ' · из кэша';
  }

  dom.infoStats.textContent = state.parts
    ? `${parts} деталей · ${tris} треугольников${dims}${extra}`
    : 'Откройте .stp / .step / .glb файл';
  dom.info.classList.remove('is-empty');
  buildPartsStrip();
}

/** Список деталей внизу: каждую можно скрыть (она становится прозрачной). */
function buildPartsStrip() {
  const strip = document.getElementById('parts-strip');
  if (!strip) return;
  const all = [];
  if (state.modelGroup) {
    state.modelGroup.traverse((child) => {
      if (child.isMesh && child.name !== 'edges') all.push(child);
    });
  }
  strip.textContent = '';
  if (!all.length) return;
  all.slice(0, 80).forEach((mesh, index) => {
    const hidden = mesh.userData.hiddenPart === true;
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'part-chip' + (hidden ? ' is-hidden' : '');
    chip.title = mesh.name || `Деталь ${index + 1}`;
    chip.textContent = `${hidden ? '◌' : '◉'} ${mesh.name || `Деталь ${index + 1}`}`;
    chip.addEventListener('click', () => togglePart(mesh));
    strip.appendChild(chip);
  });
}

/** Скрыть/показать деталь: прозрачность, а не удаление — сборку видно без неё. */
function togglePart(mesh) {
  if (!mesh.userData.origMaterial) {
    const list = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
    mesh.userData.origMaterial = mesh.material;
    const ghosts = list.map((m) => {
      const copy = m.clone();
      copy.transparent = true;
      copy.opacity = 0.06;
      copy.depthWrite = false;
      return copy;
    });
    mesh.userData.ghostMaterial = Array.isArray(mesh.material) ? ghosts : ghosts[0];
  }
  const hidden = mesh.userData.hiddenPart === true;
  mesh.material = hidden ? mesh.userData.origMaterial : mesh.userData.ghostMaterial;
  mesh.userData.hiddenPart = !hidden;
  buildPartsStrip();
  renderer.render(scene, camera);
}

/** Размер кэша в настройках. */
async function updateCacheInfo() {
  if (!dom.cacheInfo) return;
  const stats = await cacheStats();
  dom.cacheInfo.textContent = stats.count
    ? `${stats.count} модел${stats.count === 1 ? 'ь' : 'ей'} · ${formatBytes(stats.bytes)}`
    : 'пусто';
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
    // Отзыв владельца 26.11: адрес модели в оверлее не показываем — вместо
    // него крупная «N» и меняющиеся подсказки (см. startOverlayTips).
    showOverlay('Скачиваю файл…', '');
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Не удалось скачать файл (HTTP ${response.status})`);
    let buffer = await response.arrayBuffer();
    // Модели каталога лежат в репозитории сжатыми (.stp.gz): ChromeDrive
    // отдаёт их с CORS, а обычные файлы на Drive браузер блокирует.
    buffer = await maybeGunzip(buffer);
    hideOverlay();
    await loadBuffer(buffer, (name || url.split('/').pop() || 'model.stp').replace(/\.gz$/i, ''));
  } catch (err) {
    fail(err);
  }
}

/** Распаковывает gzip-буфер, если он сжат (по сигнатуре 1f 8b). */
async function maybeGunzip(buffer) {
  const head = new Uint8Array(buffer, 0, Math.min(2, buffer.byteLength));
  if (head.length < 2 || head[0] !== 0x1f || head[1] !== 0x8b) return buffer;
  if (typeof DecompressionStream === 'undefined') {
    throw new Error('браузер не умеет распаковывать gzip');
  }
  const stream = new Blob([buffer]).stream().pipeThrough(new DecompressionStream('gzip'));
  return await new Response(stream).arrayBuffer();
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
  massTools.clear();
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

// Кнопка «Каталог» — первая слева в шапке (замечания владельца 24.11):
// открывает окошко каталога в приложении через мост. Показываем кнопку,
// только когда мост есть (window.NexusApp, который поднимает Flutter,
// или window.flutter_inappwebview на Android-WebView); на вебе и в
// standalone кнопка остаётся скрытой — «Каталог» там рисует сам Flutter.
const catalogBtn = document.getElementById('catalog-btn');

/** Показать кнопку и привязать клик (защита от повторного вызова). */
let _catalogWired = false;

function wireCatalogBtn() {
  if (!catalogBtn || _catalogWired) return;
  _catalogWired = true;
  catalogBtn.hidden = false;
  catalogBtn.addEventListener('click', () => {
    if (window.NexusApp && typeof window.NexusApp.openCatalog === 'function') {
      window.NexusApp.openCatalog();
    } else {
      // Приложение ещё не подставило NexusApp — зовём хендлер напрямую
      // (Flutter регистрирует JS-хендлер «NexusApp», см. step_viewer_io.dart).
      window.flutter_inappwebview?.callHandler?.('NexusApp', 'openCatalog');
    }
  });
}

if (window.NexusApp || window.flutter_inappwebview) {
  wireCatalogBtn();
} else {
  // Мост может появиться после старта модуля: плагин объявляет
  // готовность событием flutterInAppWebViewPlatformReady — реагируем и на
  // него, чтобы «Каталог» не потерялся при медленной инициализации WebView.
  window.addEventListener('flutterInAppWebViewPlatformReady', wireCatalogBtn, { once: true });
}

// Кнопки «Подогнать» в панели больше нет (отзыв владельца 26.11) — вид
// подгоняется сам при загрузке и по клавише F.

dom.edgesBtn.addEventListener('click', () => setEdgesEnabled(!state.edgesEnabled));

dom.themeBtn?.addEventListener('click', () => applyTheme(state.theme === 'light' ? 'dark' : 'light'));

/* Настройки чувствительности мыши */
const settingsBtn = document.getElementById('settings-btn');
const settingsPanel = document.getElementById('settings-panel');
const sensitivityControls = {
  rotate: document.getElementById('sensitivity-rotate'),
  pan: document.getElementById('sensitivity-pan'),
  zoom: document.getElementById('sensitivity-zoom'),
};
const sensitivityOutputs = {
  rotate: document.getElementById('sensitivity-rotate-out'),
  pan: document.getElementById('sensitivity-pan-out'),
  zoom: document.getElementById('sensitivity-zoom-out'),
};

function syncSensitivityUi() {
  for (const key of Object.keys(sensitivityControls)) {
    const input = sensitivityControls[key];
    const output = sensitivityOutputs[key];
    if (input) input.value = String(sensitivity[key]);
    if (output) output.textContent = sensitivity[key].toFixed(1);
  }
}

syncSensitivityUi();

settingsBtn?.addEventListener('click', (event) => {
  event.stopPropagation();
  if (!settingsPanel) return;
  const willShow = settingsPanel.hidden;
  settingsPanel.hidden = !willShow;
  settingsBtn.classList.toggle('is-on', willShow);
  if (willShow) {
    syncSensitivityUi();
    void updateCacheInfo();
    // не перекрываем панель массы, если она открыта
    const massPanel = document.getElementById('mass-panel');
    const offset = massPanel && !massPanel.hidden ? massPanel.offsetWidth + 28 : 14;
    settingsPanel.style.right = `${offset}px`;
  }
});

document.addEventListener('click', (event) => {
  if (!settingsPanel || settingsPanel.hidden) return;
  if (settingsPanel.contains(event.target) || settingsBtn?.contains(event.target)) return;
  settingsPanel.hidden = true;
  settingsBtn?.classList.remove('is-on');
});

for (const key of Object.keys(sensitivityControls)) {
  sensitivityControls[key]?.addEventListener('input', () => {
    sensitivity[key] = clampSensitivity(sensitivityControls[key].value);
    if (sensitivityOutputs[key]) sensitivityOutputs[key].textContent = sensitivity[key].toFixed(1);
    applySensitivity();
    saveSensitivity();
  });
}

dom.qualityBtn?.addEventListener('click', () => {
  if (state.modelKind !== 'step' || !state.lastBuffer) return;
  void switchQuality(state.quality === 'fine' ? 'draft' : 'fine');
});

dom.cacheClearBtn?.addEventListener('click', async () => {
  await clearCache();
  await updateCacheInfo();
  showToast('Кэш геометрии очищен');
});

document.getElementById('sensitivity-reset')?.addEventListener('click', () => {
  Object.assign(sensitivity, SENSITIVITY_DEFAULTS);
  syncSensitivityUi();
  applySensitivity();
  saveSensitivity();
});

// Слушатели кнопок ракурсов ([data-view]) удалены вместе с самими
// кнопками (замечание 1 владельца 24.11). Быстрые клавиши 1–4 (ниже,
// window keydown) оставлены: на ПК они не загромождают интерфейс.

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
  else if (key === 'm') { event.preventDefault(); massTools.togglePanel(); }
  else if (key === '1') setView('iso');
  else if (key === '2') setView('front');
  else if (key === '3') setView('top');
  else if (key === '4') setView('right');
});

/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* Превью для проводника Windows (рендер в offscreen-таргет)           */
/* ------------------------------------------------------------------ */

/**
 * Рисует модель в PNG (data URL) без изменения видимой сцены.
 * Нужно для превью в проводнике: Windows-миниатюры делает shell-расширение,
 * которому этот файл передаёт приложение.
 */
function renderThumbnailDataUrl(size = 800) {
  if (!state.modelGroup) return null;

  const s = Math.max(128, Math.min(1600, Math.round(Number(size)) || 800));
  const box = new THREE.Box3().setFromObject(modelRoot);
  if (box.isEmpty()) return null;

  const savedBackground = scene.background;
  const savedGridVisible = state.grid ? state.grid.visible : null;
  const savedMarkerVisible = massTools.marker ? massTools.marker.visible : null;

  const target = new THREE.WebGLRenderTarget(s, s, {
    colorSpace: THREE.SRGBColorSpace,
    samples: 4,
  });

  try {
    scene.background = new THREE.Color(0xf2f5f9);
    if (state.grid) state.grid.visible = false;
    if (massTools.marker) massTools.marker.visible = false;

    const center = box.getCenter(new THREE.Vector3());
    const direction = VIEWS.iso.clone().normalize();

    const prevAspect = camera.aspect;
    camera.aspect = 1;
    const distance = fitDistance(box, center, direction);
    camera.aspect = prevAspect;

    const thumbCamera = camera.clone();
    thumbCamera.aspect = 1;
    thumbCamera.position.copy(center).addScaledVector(direction, distance);
    thumbCamera.up.copy(camera.up);
    thumbCamera.near = Math.max(distance / 400, 0.01);
    thumbCamera.far = Math.max(distance * 40, 100);
    thumbCamera.lookAt(center);
    thumbCamera.updateProjectionMatrix();

    renderer.setRenderTarget(target);
    renderer.render(scene, thumbCamera);
    const pixels = new Uint8Array(s * s * 4);
    renderer.readRenderTargetPixels(target, 0, 0, s, s, pixels);
    renderer.setRenderTarget(null);

    const canvas = document.createElement('canvas');
    canvas.width = s;
    canvas.height = s;
    const context = canvas.getContext('2d');
    const image = context.createImageData(s, s);
    const rowBytes = s * 4;
    for (let y = 0; y < s; y += 1) {
      const sourceStart = (s - 1 - y) * rowBytes;
      image.data.set(pixels.subarray(sourceStart, sourceStart + rowBytes), y * rowBytes);
    }
    context.putImageData(image, 0, 0);
    return canvas.toDataURL('image/png');
  } finally {
    scene.background = savedBackground;
    if (state.grid && savedGridVisible !== null) state.grid.visible = savedGridVisible;
    if (massTools.marker && savedMarkerVisible !== null) massTools.marker.visible = savedMarkerVisible;
    renderer.setRenderTarget(null);
    target.dispose();
    renderer.render(scene, camera);
  }
}/* Публичное API для встраивания (Flutter WebView / iframe)            */
/* ------------------------------------------------------------------ */

// Отладочная ручка (используется тестами): доступ к внутреннему состоянию панели массы
window.__massTools = massTools;

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
  toggleMass: (visible) => massTools.togglePanel(visible),
  renderThumbnail: (size) => renderThumbnailDataUrl(size),
  getMassReport: () => massTools.report(),
  setMassUnits: (units) => {
    const allowed = ['mm', 'cm', 'm', 'inch'];
    if (allowed.includes(units)) {
      massTools.units = units;
      if (massTools.dom.units) massTools.dom.units.value = units;
      massTools.update();
    }
  },

  setMassHeatmap: (enabled) => massTools.setViewMode(enabled ? 'cloud' : 'off'),
  setMassView: (mode) => massTools.setViewMode(mode),
  setSensitivity: (values = {}) => {
    for (const key of ['rotate', 'pan', 'zoom']) {
      if (values[key] !== undefined) sensitivity[key] = clampSensitivity(values[key]);
    }
    applySensitivity();
    saveSensitivity();
    syncSensitivityUi();
    return { ...sensitivity };
  },
  getSensitivity: () => ({ ...sensitivity }),
  setMassContrast: (value) => massTools.setCloudContrast(Number(value) || 1),
  setMassOpacity: (value) => massTools.setVisualOpacity(Number(value) || 0.85),
  setMassFill: (value) => massTools.setWallFill(Number(value)),
  setMassSolid: (enabled) => {
    if (enabled !== massTools.isSolid()) massTools.toggleSolidFill();
    return massTools.isSolid();
  },
  setQuality: (quality) => switchQuality(quality === 'draft' ? 'draft' : 'fine'),
  getCacheInfo: () => cacheStats(),
  clearGeometryCache: () => clearCache(),
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
    quality: state.quality,
    cacheHit: state.cacheHit,
    modelKind: state.modelKind,
    theme: state.theme,
    luminance: +state.modelLuminance.toFixed(3),
  }),
};

/* ------------------------------------------------------------------ */
/* Публичный API для приложения (window.NexusViewer)                   */
/* ------------------------------------------------------------------ */

/**
 * Короткий адаптер для вызова из Flutter через evaluateJavascript
 * (просьба владельца 24.11): приложение вызывает
 * window.NexusViewer.openFile() / edges(true) / mass(true) / display(true) /
 * fit() / load(url). Все методы — тонкие обёртки над теми же функциями,
 * что дергают усыпальные¹ кнопки вьюера, поэтому поведение идентично
 * обычному режиму и ничего не дублируется.
 * ¹ — то есть существующие обработчики кнопок (open-btn / edges-btn / mass-btn).
 */
window.NexusViewer = {
  /** «Открыть файл»: тот же клик по скрытому input #file-input, что и у кнопки «Открыть STEP». */
  openFile: () => dom.fileInput.click(),

  /** Рёбра: true — включить, false — выключить, без аргумента — переключить (как кнопка «Рёбра» / E). */
  edges: (on) => setEdgesEnabled(typeof on === 'boolean' ? on : !state.edgesEnabled),

  /** Панель «Масса и центр тяжести»: true — открыть, false — закрыть (как кнопка «Масса» / M). */
  mass: (open) => massTools.togglePanel(typeof open === 'boolean' ? open : true),

  /**
   * Блок «Отображение» в панели массы: показать ползунки заливки/прозрачности
   * (нужны приложению для оценки объёма материала) и прокрутить к ним.
   * open=false — снова спрятать ползунки, как это делает смена «Вида» на «Обычный».
   */
  display: (open = true) => {
    if (open === false) {
      massTools.hideFill?.();
      massTools.hideContrast?.();
      return false;
    }
    massTools.togglePanel(true); // панель должна быть открыта, иначе прокручивать нечего
    massTools.showContrast?.(); // поднимает и прозрачность
    massTools.showFill?.(); // отвечает за ползунок «Заливка» и кнопку «Сплошная заливка»
    const target = massTools.dom?.fillField || massTools.dom?.opacityField;
    if (target) {
      requestAnimationFrame(() =>
        target.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
      );
    }
    return true;
  },

  /** Подогнать модель под экран (как кнопка «Подогнать» / F). */
  fit: () => fitView(),

  /** Загрузить модель по прямой ссылке — то же, что ?url=/?model= при старте. */
  load: (url, name) => {
    if (typeof url !== 'string' || !url.trim()) return false;
    loadUrl(url.trim(), name || undefined);
    return true;
  },
};

/* ------------------------------------------------------------------ */
/* Автозагрузка (?model=...)                                           */
/* ------------------------------------------------------------------ */

// На тач-устройствах перетаскивания нет — подсказываем кнопку.
// (Владелец, 24.11: в приложении чипы примеров не бандлятся — см. index.html,
// поэтому подсказку о «примерах» в этой сборке тоже убираем.)
if (window.matchMedia && window.matchMedia('(hover: none)').matches) {
  const sub = document.getElementById('empty-sub');
  if (sub) sub.textContent = 'Нажмите «Открыть STEP» — файл обрабатывается локально, на устройстве';
}

const params = new URLSearchParams(window.location.search);

// Для встраивания (Тильда/iframe): ?ui=min — только 3D, без панелей и подсказок.
if (params.get('ui') === 'min' || params.get('minimal') === '1') {
  document.body.classList.add('ui-minimal');
}

// Режим встраивания в приложение (?embed=1, просьба владельца 24.11):
// страхуем inline-скрипт в index.html — класс вешаем и здесь, если его ещё
// нет (например, страницу открыли по ссылке, собранной без параметров шапки).
if (params.get('embed') === '1') {
  document.documentElement.classList.add('embed-viewer');
}
const modelUrl = params.get('model') || params.get('url');
if (modelUrl) {
  loadUrl(modelUrl, params.get('name') || undefined);
}

