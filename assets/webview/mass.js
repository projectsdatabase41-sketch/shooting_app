/**
 * Масса, центр тяжести и визуализация «где материал».
 *
 * Данные:
 *  • объём и центр объёма каждой детали — по треугольной сетке (знаковые тетраэдры);
 *  • масса = объём × плотность (материал выбирается в таблице);
 *  • ЦТ сборки, смещение от центра габарита, статический момент, баланс по плоскостям.
 *
 * Два вида подсветки:
 *  • «Облако массы» — объёмное облако внутри детали: гуще там, где дальше до стенок
 *    (расстояние до поверхности), с ползунком контраста;
 *  • «Стенки (прозрачность)» — упрощённый вид по толщине стенки: тонкое прозрачное.
 */

import * as THREE from 'three';
import {
  PART_HUES,
  computeThicknessAsync,
  applyThicknessColors,
  clearThicknessColors,
  createThicknessMaterial,
} from './thickness.js';
import { buildDensityVolume, createCloud, createParticles } from './volume.js';

export const MATERIALS = [
  { key: 'steel', name: 'Сталь', density: 7.85 },
  { key: 'stainless', name: 'Нержавеющая сталь', density: 7.9 },
  { key: 'castIron', name: 'Чугун', density: 7.2 },
  { key: 'aluminium', name: 'Алюминий', density: 2.7 },
  { key: 'dural', name: 'Дюраль (Д16)', density: 2.78 },
  { key: 'titanium', name: 'Титан (ВТ1-0)', density: 4.5 },
  { key: 'brass', name: 'Латунь', density: 8.5 },
  { key: 'bronze', name: 'Бронза', density: 8.8 },
  { key: 'copper', name: 'Медь', density: 8.96 },
  { key: 'zinc', name: 'Цинк', density: 7.14 },
  { key: 'abs', name: 'ABS-пластик', density: 1.05 },
  { key: 'pom', name: 'POM (полиацеталь)', density: 1.41 },
  { key: 'pa6', name: 'Полиамид PA6', density: 1.14 },
  { key: 'carbon', name: 'Карбон (CFRP)', density: 1.6 },
  { key: 'glass', name: 'Стекло', density: 2.5 },
  { key: 'rubber', name: 'Резина', density: 1.2 },
  { key: 'wood', name: 'Дерево (сухое)', density: 0.7 },
  { key: 'custom', name: 'Свой материал', density: null },
];

const MATERIAL_BY_KEY = new Map(MATERIALS.map((m) => [m.key, m]));

/** 1 единица модели → сколько сантиметров. */
const UNIT_TO_CM = { mm: 0.1, cm: 1, m: 100, inch: 2.54 };
const UNITS_LABEL = { mm: 'мм', cm: 'см', m: 'м', inch: 'дюйм' };

const AXES = ['x', 'y', 'z'];
const AXIS_LABEL = { x: 'X', y: 'Y', z: 'Z' };
const SLICE_COUNT = 24;

/** Палитра облака массы: тускло-синий → голубой → жёлтый → красный. */
const CLOUD_STOPS = [
  [0.0, new THREE.Color(0x2a5bd7)],
  [0.35, new THREE.Color(0x1fb6c9)],
  [0.65, new THREE.Color(0x8bd63c)],
  [0.85, new THREE.Color(0xffc94d)],
  [1.0, new THREE.Color(0xff4d4d)],
];

function cloudColor(t) {
  const x = Math.min(1, Math.max(0, t));
  for (let i = 1; i < CLOUD_STOPS.length; i += 1) {
    const [prevT, prevColor] = CLOUD_STOPS[i - 1];
    const [nextT, nextColor] = CLOUD_STOPS[i];
    if (x <= nextT) {
      const k = (x - prevT) / (nextT - prevT || 1);
      return prevColor.clone().lerp(nextColor, k);
    }
  }
  return CLOUD_STOPS[CLOUD_STOPS.length - 1][1].clone();
}

/**
 * Объём и центр объёма по треугольной сетке (замкнутая сетка).
 */
export function computeVolumeCentroid(geometry) {
  const position = geometry.getAttribute('position');
  if (!position || position.count < 3) return null;

  const index = geometry.getIndex();
  const count = index ? index.count : position.count;
  if (count < 3) return null;

  let volume = 0;
  let cx = 0;
  let cy = 0;
  let cz = 0;

  for (let i = 0; i < count; i += 3) {
    const i0 = index ? index.getX(i) : i;
    const i1 = index ? index.getX(i + 1) : i + 1;
    const i2 = index ? index.getX(i + 2) : i + 2;

    const x0 = position.getX(i0);
    const y0 = position.getY(i0);
    const z0 = position.getZ(i0);
    const x1 = position.getX(i1);
    const y1 = position.getY(i1);
    const z1 = position.getZ(i1);
    const x2 = position.getX(i2);
    const y2 = position.getY(i2);
    const z2 = position.getZ(i2);

    const v = (x0 * (y1 * z2 - z1 * y2) - y0 * (x1 * z2 - z1 * x2) + z0 * (x1 * y2 - y1 * x2)) / 6;
    volume += v;
    cx += (v * (x0 + x1 + x2)) / 4;
    cy += (v * (y0 + y1 + y2)) / 4;
    cz += (v * (z0 + z1 + z2)) / 4;
  }

  if (volume < 0) {
    volume = -volume;
    cx = -cx;
    cy = -cy;
    cz = -cz;
  }

  if (!Number.isFinite(volume) || volume <= 1e-9) return null;

  return {
    volume,
    centroid: new THREE.Vector3(cx / volume, cy / volume, cz / volume),
  };
}


/**
 * Очень бережное извлечение материалов из текста STEP (AP242/AP214).
 *
 * occt-import-js не отдаёт свойства материалов, поэтому ищем их в тексте:
 *   MATERIAL_DESIGNATION('Сталь 45')
 *   MASS_DENSITY_MEASURE_WITH_UNIT(MASS_DENSITY_MEASURE(7850.),#unit)
 * Плотность в STEP задаётся в кг/м³ → переводим в г/см³.
 */
export function scanStepMaterials(bytes) {
  if (!bytes || bytes.length < 8) return [];

  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  } catch {
    return [];
  }

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
  if (names.size === 0) {
    return [{ name: 'материал из файла', density }];
  }

  return Array.from(names).slice(0, 20).map((name) => ({ name, density }));
}
export class MassTools {
  constructor({ scene, modelRoot, getTheme = null, setTheme = null }) {
    this.scene = scene;
    this.modelRoot = modelRoot;
    this.getTheme = getTheme;
    this.setTheme = setTheme;

    this.group = null;
    this.items = [];
    this.meshes = [];
    this.units = 'mm';
    this.totalMassG = 0;
    this.totalVolumeCm3 = 0;
    this.com = null;
    this.marker = null;

    this.viewMode = 'off';
    this.themeBeforeVisual = null;
    this.busy = false;

    this.thicknessMaterial = createThicknessMaterial();
    this.thicknessSummary = null;
    this.wallsBusy = false;

    this.visuals = [];
    this.volumeContrast = 1.2;
    this.visualOpacity = 0.85;
    this.wallFill = 0.35;
    this.solidBefore = null;
    this.volumeSummary = null;
    this.volumes = null;
    this.particlesTimer = null;
    this.ghostMaterial = new THREE.MeshBasicMaterial({
      color: 0x9fb4d8,
      transparent: true,
      opacity: 0.045,
      depthWrite: false,
      side: THREE.DoubleSide,
      toneMapped: false,
    });

    this.fileMaterials = [];

    this.dom = {
      button: document.getElementById('mass-btn'),
      panel: document.getElementById('mass-panel'),
      close: document.getElementById('mass-close'),
      units: document.getElementById('mass-units'),
      view: document.getElementById('mass-view'),
      contrast: document.getElementById('mass-contrast'),
      contrastField: document.getElementById('mass-contrast-field'),
      opacity: document.getElementById('mass-opacity'),
      opacityField: document.getElementById('mass-opacity-field'),
      opacityOut: document.getElementById('mass-opacity-out'),
      fill: document.getElementById('mass-fill'),
      fillField: document.getElementById('mass-fill-field'),
      fillOut: document.getElementById('mass-fill-out'),
      solidBtn: document.getElementById('mass-solid'),
      table: document.getElementById('mass-table'),
      totals: document.getElementById('mass-totals'),
      copy: document.getElementById('mass-copy'),
      note: document.getElementById('mass-note'),
      legend: document.getElementById('mass-legend'),
      legendText: document.getElementById('mass-legend-text'),
    };

    this.dom.button?.addEventListener('click', () => this.togglePanel());
    this.dom.close?.addEventListener('click', () => this.togglePanel(false));
    this.dom.units?.addEventListener('change', () => {
      this.units = this.dom.units.value;
      this.update();
    });
    this.dom.view?.addEventListener('change', () => {
      void this.setViewMode(this.dom.view.value);
    });
    this.dom.contrast?.addEventListener('input', () => {
      this.setCloudContrast(Number(this.dom.contrast.value) || 1);
    });
    this.dom.opacity?.addEventListener('input', () => {
      this.setVisualOpacity(Number(this.dom.opacity.value) || 0.85);
    });
    this.dom.fill?.addEventListener('input', () => {
      this.setWallFill(Number(this.dom.fill.value));
    });
    this.dom.solidBtn?.addEventListener('click', () => this.toggleSolidFill());
    this.dom.copy?.addEventListener('click', () => this.copyReport());
  }

  /* ---------------------------------------------------------------- */
  /* Жизненный цикл                                                   */
  /* ---------------------------------------------------------------- */

  onModelInstalled(group, options = {}) {
    this.clear();
    this.group = group;
    this.meshes = [];
    group.traverse((child) => {
      if (child.isMesh && child.geometry && !child.userData.cloud) this.meshes.push(child);
    });

    this.items = this.meshes.map((mesh, i) => {
      const measurement = computeVolumeCentroid(mesh.geometry);
      return {
        id: i,
        mesh,
        name: mesh.name && mesh.name !== 'part' ? mesh.name : `Деталь ${i + 1}`,
        volumeModelUnits: measurement ? measurement.volume : 0,
        centroid: measurement ? measurement.centroid : new THREE.Vector3(),
        valid: !!measurement,
        materialKey: 'steel',
        density: MATERIAL_BY_KEY.get('steel').density,
      };
    });

    // Имена деталей из STEP часто повторяются (SOLID, Body…) — нумеруем
    const nameCounts = new Map();
    for (const item of this.items) {
      nameCounts.set(item.name, (nameCounts.get(item.name) || 0) + 1);
    }
    const seen = new Map();
    for (const item of this.items) {
      if ((nameCounts.get(item.name) || 0) > 1) {
        const index = (seen.get(item.name) || 0) + 1;
        seen.set(item.name, index);
        item.name = `${item.name} #${index}`;
      }
    }

    this.fileMaterials = Array.isArray(options.materials) ? options.materials : [];
    if (this.fileMaterials.length === 1 && this.fileMaterials[0].density) {
      const density = this.fileMaterials[0].density;
      for (const item of this.items) {
        item.materialKey = 'custom';
        item.density = density;
      }
    }

    this.update();
  }

  clear() {
    this.clearWalls();
    this.clearVolumeView();
    this.volumes = null;
    this.viewMode = 'off';
    if (this.dom.view) this.dom.view.value = 'off';
    this.hideContrast();
    this.removeMarker();
    this.group = null;
    this.items = [];
    this.meshes = [];
    this.totalMassG = 0;
    this.totalVolumeCm3 = 0;
    this.com = null;
    this.fileMaterials = [];
  }

  /* ---------------------------------------------------------------- */
  /* Расчёт                                                           */
  /* ---------------------------------------------------------------- */

  get unitToCm() {
    return UNIT_TO_CM[this.units] ?? 0.1;
  }

  update() {
    if (!this.items.length) {
      this.renderEmpty();
      return;
    }

    const unitToCm = this.unitToCm;
    let mass = 0;
    let volumeCm3 = 0;
    const com = new THREE.Vector3();

    for (const item of this.items) {
      const volCm3 = item.volumeModelUnits * unitToCm ** 3;
      const itemMass = volCm3 * item.density;
      item.volumeCm3 = volCm3;
      item.massG = itemMass;
      volumeCm3 += volCm3;
      mass += itemMass;
      com.addScaledVector(item.centroid, itemMass);
    }

    if (mass > 1e-12) {
      com.divideScalar(mass);
      this.com = com;
    } else {
      this.com = null;
    }

    this.totalMassG = mass;
    this.totalVolumeCm3 = volumeCm3;

    this.updateMarker();
    this.renderTable();
    this.renderTotals();
  }

  /** Масса по срезам вдоль оси — нужно для баланса по плоскостям. */
  computeSlices(axis) {
    if (!this.group) return null;

    const box = new THREE.Box3().setFromObject(this.group);
    if (box.isEmpty()) return null;

    const min = box.min[axis];
    const max = box.max[axis];
    const span = max - min;
    const step = span / SLICE_COUNT || 1;
    const buckets = new Array(SLICE_COUNT).fill(0);
    const unitToCm = this.unitToCm;

    for (const item of this.items) {
      const geometry = item.mesh.geometry;
      const position = geometry.getAttribute('position');
      const index = geometry.getIndex();
      if (!position) continue;

      const count = index ? index.count : position.count;
      const massPerVolume = item.density * unitToCm ** 3;

      for (let i = 0; i < count; i += 3) {
        const i0 = index ? index.getX(i) : i;
        const i1 = index ? index.getX(i + 1) : i + 1;
        const i2 = index ? index.getX(i + 2) : i + 2;

        const x0 = position.getX(i0);
        const y0 = position.getY(i0);
        const z0 = position.getZ(i0);
        const x1 = position.getX(i1);
        const y1 = position.getY(i1);
        const z1 = position.getZ(i1);
        const x2 = position.getX(i2);
        const y2 = position.getY(i2);
        const z2 = position.getZ(i2);

        const v = Math.abs((x0 * (y1 * z2 - z1 * y2) - y0 * (x1 * z2 - z1 * x2) + z0 * (x1 * y2 - y1 * x2)) / 6);
        const coordinate = axis === 'x' ? (x0 + x1 + x2) / 3 : axis === 'y' ? (y0 + y1 + y2) / 3 : (z0 + z1 + z2) / 3;

        let bucket = Math.floor((coordinate - min) / step);
        if (bucket < 0) bucket = 0;
        if (bucket >= SLICE_COUNT) bucket = SLICE_COUNT - 1;
        buckets[bucket] += v * massPerVolume;
      }
    }

    return { min, max, step, buckets };
  }

  /** Доля массы слева/справа от плоскости через центр габарита. */
  computeBalance() {
    if (!this.group) return null;

    const box = new THREE.Box3().setFromObject(this.group);
    if (box.isEmpty()) return null;

    const result = {};
    for (const axis of AXES) {
      const data = this.computeSlices(axis);
      if (!data) continue;

      const center = (box.min[axis] + box.max[axis]) / 2;
      let left = 0;
      let right = 0;
      for (let i = 0; i < data.buckets.length; i += 1) {
        const bucketCenter = data.min + data.step * (i + 0.5);
        if (bucketCenter <= center) left += data.buckets[i];
        else right += data.buckets[i];
      }

      const total = left + right;
      result[axis] = total > 0 ? { leftShare: left / total, rightShare: right / total } : null;
    }

    return result;
  }

  /* ---------------------------------------------------------------- */
  /* Виды: облако массы и стенки                                      */
  /* ---------------------------------------------------------------- */

  async setViewMode(mode) {
    const next = ['cloud', 'points', 'walls'].includes(mode) ? mode : 'off';
    if (next === this.viewMode && next !== 'off') {
      return;
    }

    this.clearWalls();
    this.clearVolumeView();

    if (next !== this.viewMode && this.themeBeforeVisual) {
      this.setTheme?.(this.themeBeforeVisual);
      this.themeBeforeVisual = null;
    }

    this.viewMode = next;
    if (this.dom.view) this.dom.view.value = next;

    if (next === 'off') {
      this.dom.legend?.setAttribute('hidden', '');
      this.hideContrast();
      if (this.dom.legendText) this.dom.legendText.textContent = '';
      this.renderTable();
      return;
    }

    if (!this.themeBeforeVisual) {
      this.themeBeforeVisual = this.getTheme ? this.getTheme() : 'dark';
      this.setTheme?.('dark');
    }

    this.dom.legend?.removeAttribute('hidden');

    if (next === 'walls') {
      this.dom.contrastField?.setAttribute('hidden', '');
      this.showOpacity();
      await this.applyWalls();
      return;
    }

    this.showContrast();
    if (next === 'cloud') this.showFill();
    else this.hideFill();
    await this.applyVolumeView(next);
  }

  showContrast() {
    this.dom.contrastField?.removeAttribute('hidden');
    if (this.dom.contrast) this.dom.contrast.value = String(this.volumeContrast);
    this.showOpacity();
  }

  hideContrast() {
    this.dom.contrastField?.setAttribute('hidden', '');
    this.hideOpacity();
  }

  showOpacity() {
    this.dom.opacityField?.removeAttribute('hidden');
    if (this.dom.opacity) this.dom.opacity.value = String(this.visualOpacity);
    if (this.dom.opacityOut) this.dom.opacityOut.textContent = `${Math.round(this.visualOpacity * 100)}%`;
  }

  hideOpacity() {
    this.dom.opacityField?.setAttribute('hidden', '');
    this.hideFill();
  }

  showFill() {
    this.dom.fillField?.removeAttribute('hidden');
    this.dom.solidBtn?.removeAttribute('hidden');
    if (this.dom.fill) this.dom.fill.value = String(this.wallFill);
    if (this.dom.fillOut) this.dom.fillOut.textContent = `${Math.round(this.wallFill * 100)}%`;
    this.dom.solidBtn?.classList.toggle('is-on', this.isSolid());
  }

  hideFill() {
    this.dom.fillField?.setAttribute('hidden', '');
    this.dom.solidBtn?.setAttribute('hidden', '');
  }

  /** «Заливка»: минимальная плотность внутри детали (тонкие стенки, рёбра). */
  setWallFill(value) {
    this.wallFill = Math.min(1, Math.max(0, Number(value) || 0));
    if (this.dom.fillOut) this.dom.fillOut.textContent = `${Math.round(this.wallFill * 100)}%`;
    this.applyFillFloor();
    this.dom.solidBtn?.classList.toggle('is-on', this.isSolid());
    this.updateVolumeLegend();
  }

  /** Полная заливка: зазор 0 + плотность 100%. */
  toggleSolidFill() {
    if (this.isSolid()) {
      const previous = this.solidBefore || { contrast: 2, fill: 0.35 };
      this.solidBefore = null;
      this.setWallFill(previous.fill);
      this.setCloudContrast(previous.contrast);
      return;
    }

    this.solidBefore = { contrast: this.volumeContrast, fill: this.wallFill };
    this.setCloudContrast(4);
    this.setWallFill(1);
    if (this.dom.contrast) this.dom.contrast.value = '4';
    this.dom.solidBtn?.classList.add('is-on');
  }

  isSolid() {
    return this.volumeContrast >= 3.99 && this.wallFill >= 0.99;
  }

  applyFillFloor() {
    for (const entry of this.visuals) {
      if (entry.kind === 'cloud') {
        entry.material.uniforms.uFillFloor.value = this.fillFloor();
      }
    }
  }

  /** Общий уровень прозрачности: дым, частицы и режим «Стенки». */
  setVisualOpacity(value) {
    this.visualOpacity = Math.min(1, Math.max(0.05, Number(value) || 0.85));
    if (this.dom.opacityOut) this.dom.opacityOut.textContent = `${Math.round(this.visualOpacity * 100)}%`;
    this.applyVisualOpacity();
    this.updateVolumeLegend();
  }

  applyVisualOpacity() {
    for (const entry of this.visuals) {
      if (entry.kind === 'cloud') {
        entry.material.uniforms.uOpacity.value = this.visualOpacity;
      } else if (entry.kind === 'particles') {
        entry.material.opacity = this.visualOpacity;
        entry.material.needsUpdate = true;
      }
    }

    if (this.viewMode === 'walls') {
      this.thicknessMaterial.opacity = this.visualOpacity;
      this.thicknessMaterial.transparent = true;
    }
  }

  setCloudContrast(value) {
    this.volumeContrast = Math.min(4, Math.max(0.2, Number(value) || 1));
    if (this.dom.contrast) this.dom.contrast.value = String(this.volumeContrast);
    this.dom.solidBtn?.classList.toggle('is-on', this.isSolid());

    for (const entry of this.visuals) {
      if (entry.kind === 'cloud' && entry.volume) {
        const volume = entry.volume;
        entry.material.uniforms.uGap.value = this.wallGap(volume.maxDistanceUnits);
        entry.material.uniforms.uContrast.value = this.volumeContrast;
        entry.material.uniforms.uFillFloor.value = this.fillFloor();
        entry.material.uniforms.uFeather.value = Math.max(
          volume.cell * 1.6,
          volume.maxDistanceUnits * 0.04,
          0.05
        );
      } else if (entry.kind === 'particles') {
        entry.material.opacity = Math.min(1, 0.35 + this.volumeContrast * 0.35);
      }
    }

    this.refreshGapSummary();
    this.updateVolumeLegend();

    // точки пересобираем (порог зависит от контраста) без пересчёта SDF
    if (this.viewMode === 'points') {
      this.scheduleParticlesRebuild();
    }
  }

  /**
   * Зазор от стенки (мм), который задаёт контраст:
   * 0.2 — дым только в самом глубоком массиве, 4 — дым доходит до стенок.
   */
  wallGap(partMaxDistance) {
    const t = Math.min(1, Math.max(0, (this.volumeContrast - 0.2) / 3.8));
    return partMaxDistance * 0.55 * Math.pow(1 - t, 1.8);
  }

  refreshGapSummary() {
    if (!this.volumeSummary) return;
    const gaps = [];
    for (const entry of this.visuals) {
      if (!entry.volume) continue;
      const gap = entry.kind === 'cloud'
        ? this.wallGap(entry.volume.maxDistanceUnits)
        : Math.max(this.wallGap(entry.volume.maxDistanceUnits) * 0.6, entry.volume.cell * 0.5);
      gaps.push(gap);
    }
    if (gaps.length) {
      this.volumeSummary.gapMin = Math.min(...gaps);
      this.volumeSummary.gapMax = Math.max(...gaps);
    }
  }

  /**
   * Минимальная плотность внутри детали: при большом контрасте заливка
   * сплошная (включая тонкие стенки), при малом — виден только массив.
   */
  fillFloor() {
    // отдельный ползунок «Заливка»: 0 — только толстый массив, 100% — стенки тоже
    return Math.min(1, Math.max(0.02, this.wallFill));
  }

  updateVolumeLegend() {
    const summary = this.volumeSummary;
    if (!summary) return;
    const unit = UNITS_LABEL[this.units] || 'мм';
    const gapText = summary.gapMax > 0
      ? `зазор до стенки ≈ ${summary.gapMin.toFixed(1)}–${summary.gapMax.toFixed(1)} ${unit}`
      : 'доходит до стенок';
    const tail = `контраст ${this.volumeContrast.toFixed(1)} · прозрачность ${Math.round(this.visualOpacity * 100)}%`;

    if (summary.mode === 'cloud') {
      const fillText = `заливка ${Math.round(this.wallFill * 100)}%`;
      this.setLegend(`Дым: ${summary.parts} дет. · ${gapText} · ${fillText} · ${tail}`);
    } else {
      this.setLegend(`Частицы: ${summary.points} шт. · ${gapText} · ${tail}`);
    }
  }

  scheduleParticlesRebuild() {
    if (this.particlesTimer) clearTimeout(this.particlesTimer);
    this.particlesTimer = setTimeout(() => {
      if (this.viewMode === 'points') void this.applyVolumeView('points', { keepVolumes: true });
    }, 220);
  }

  /** Один раз строит карты расстояний для всех деталей (кэшируются). */
  async ensureVolumes() {
    if (this.volumes && this.volumes.length === this.items.length) {
      return this.volumes;
    }

    const volumes = [];
    for (let i = 0; i < this.items.length; i += 1) {
      this.setLegend(`Строю карту объёма: ${i + 1} из ${this.items.length}…`);
      let volume = null;
      try {
        volume = buildDensityVolume(this.items[i].mesh.geometry, { resolution: 112 });
      } catch (error) {
        console.warn('[mass] volume failed', error);
      }
      volumes.push(volume);

      // eslint-disable-next-line no-await-in-loop
      await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
      if (this.viewMode !== 'cloud' && this.viewMode !== 'points') return null;
    }

    this.volumes = volumes;
    return volumes;
  }

  /** Объёмный вид: дым или частицы (по одной и той же карте расстояний). */
  async applyVolumeView(mode, options = {}) {
    if (!this.items.length) return;
    if (this.busy) return;

    this.busy = true;
    try {
      const volumes = options.keepVolumes && this.volumes ? this.volumes : await this.ensureVolumes();
      if (!volumes) return;

      this.clearVolumeView();

      let built = 0;
      let maxDistance = 0;
      let points = 0;
      const gaps = [];

      for (let i = 0; i < this.items.length; i += 1) {
        const volume = volumes[i];
        if (!volume) continue;

        const hue = PART_HUES[i % PART_HUES.length] / 360;
        const color = new THREE.Color().setHSL(hue, 0.9, 0.62);
        const gap = this.wallGap(volume.maxDistanceUnits);
        const feather = Math.max(volume.cell * 1.6, volume.maxDistanceUnits * 0.04, 0.05);
        let entry = null;

        if (mode === 'cloud') {
          entry = createCloud(volume, color, {
            gap,
            feather,
            contrast: this.volumeContrast,
            fillFloor: this.fillFloor(),
            opacity: this.visualOpacity,
          });
        } else {
          // общий бюджет точек: чем больше деталей, тем меньше точек на деталь
          const perPartLimit = Math.min(40_000, Math.max(2_000, Math.round(120_000 / Math.max(1, this.items.length))));
          entry = createParticles(volume, color, {
            minDistance: Math.max(gap * 0.6, volume.cell * 0.5),
            opacity: this.visualOpacity,
            maxPoints: perPartLimit,
          });
        }

        if (!entry) continue;

        this.group.add(entry.mesh);
        this.visuals.push(entry);
        built += 1;
        maxDistance = Math.max(maxDistance, volume.maxDistanceUnits);
        gaps.push(entry.kind === 'cloud' ? gap : Math.max(gap * 0.6, volume.cell * 0.5));
        if (entry.kind === 'particles') points += entry.count;
      }

      if (this.viewMode !== mode) {
        this.clearVolumeView();
        return;
      }

      // полупрозрачная оболочка, чтобы читалась форма детали
      for (const item of this.items) {
        if (!item.mesh.userData.ghostOriginalMaterial) {
          item.mesh.userData.ghostOriginalMaterial = item.mesh.material;
        }
        item.mesh.material = this.ghostMaterial;
        item.mesh.renderOrder = 0;
      }

      const unit = UNITS_LABEL[this.units] || 'мм';
      this.volumeSummary = {
        mode,
        parts: built,
        maxDistance,
        points,
        gapMin: gaps.length ? Math.min(...gaps) : 0,
        gapMax: gaps.length ? Math.max(...gaps) : 0,
      };

      this.updateVolumeLegend();
      if (mode === 'cloud') this.showFill();
      this.renderTable();
    } catch (error) {
      console.error('[mass] volume view failed', error);
      this.setLegend('Не удалось построить объём: ' + (error && error.message ? error.message : error));
    } finally {
      this.busy = false;
    }
  }

  clearVolumeView() {
    if (this.particlesTimer) {
      clearTimeout(this.particlesTimer);
      this.particlesTimer = null;
    }

    for (const entry of this.visuals) {
      entry.mesh.removeFromParent();
      entry.mesh.geometry.dispose();
      entry.material.dispose();
      if (entry.texture) entry.texture.dispose();
    }
    this.visuals = [];
    this.volumeSummary = null;

    for (const item of this.items) {
      if (item.mesh.userData.ghostOriginalMaterial) {
        item.mesh.material = item.mesh.userData.ghostOriginalMaterial;
        delete item.mesh.userData.ghostOriginalMaterial;
      }
      item.mesh.renderOrder = 0;
    }
  }

  /** Упрощённый вид по толщине стенки (прозрачность + насыщенность). */
  async applyWalls() {
    if (!this.items.length || this.wallsBusy) return;
    this.wallsBusy = true;
    this.setLegend('Считаю толщину стенок…');

    try {
      const meshes = this.items.map((item) => item.mesh);
      const results = await computeThicknessAsync(meshes, (done, total) => {
        this.setLegend(`Толщина стенок: ${done} из ${total}…`);
      });

      if (this.viewMode !== 'walls') return;

      const summary = applyThicknessColors(meshes, results, this.thicknessMaterial);
      this.thicknessSummary = summary;
      this.applyVisualOpacity();

      const unit = UNITS_LABEL[this.units] || 'мм';
      this.setLegend(
        `Стенки: ${summary.min.toFixed(1)}…${summary.max.toFixed(1)} ${unit} · тонкое прозрачнее`
      );
      this.renderTable();
    } catch (error) {
      console.error('[mass] walls failed', error);
      this.setLegend('Не удалось посчитать толщину: ' + (error && error.message ? error.message : error));
    } finally {
      this.wallsBusy = false;
    }
  }

  clearWalls() {
    clearThicknessColors(this.items.map((item) => item.mesh));
    this.thicknessSummary = null;
  }

  setLegend(text) {
    if (this.dom.legendText) this.dom.legendText.textContent = text;
  }
  /* Маркер центра тяжести                                            */
  /* ---------------------------------------------------------------- */

  updateMarker() {
    this.removeMarker();
    if (!this.com || !this.group) return;

    const box = new THREE.Box3().setFromObject(this.group);
    if (box.isEmpty()) return;

    const size = box.getSize(new THREE.Vector3()).length();
    const radius = Math.max(size * 0.006, 1e-4);

    const marker = new THREE.Group();
    marker.name = 'center-of-mass';

    const sphere = new THREE.Mesh(
      new THREE.SphereGeometry(radius, 20, 16),
      new THREE.MeshBasicMaterial({ color: 0xff3b30 })
    );
    sphere.renderOrder = 6;
    marker.add(sphere);

    const arm = radius * 5;
    const lineMaterial = new THREE.LineBasicMaterial({ color: 0xff3b30, transparent: true, opacity: 0.75 });
    for (const [x, y, z] of [[arm, 0, 0], [0, arm, 0], [0, 0, arm]]) {
      const geometry = new THREE.BufferGeometry().setFromPoints([
        new THREE.Vector3(-x, -y, -z),
        new THREE.Vector3(x, y, z),
      ]);
      marker.add(new THREE.Line(geometry, lineMaterial));
    }

    marker.position.copy(this.com);
    this.marker = marker;
    this.scene.add(marker);
  }

  removeMarker() {
    if (!this.marker) return;
    this.marker.traverse((child) => {
      if (child.geometry) child.geometry.dispose();
      if (child.material) child.material.dispose();
    });
    this.marker.removeFromParent();
    this.marker = null;
  }

  /* ---------------------------------------------------------------- */
  /* Панель                                                           */
  /* ---------------------------------------------------------------- */

  togglePanel(force) {
    if (!this.dom.panel) return;
    const show = typeof force === 'boolean' ? force : this.dom.panel.hidden;
    this.dom.panel.hidden = !show;
    this.dom.button?.classList.toggle('is-on', show);

    if (show) {
      if (!this.items.length) this.renderEmpty();
      else {
        this.renderTable();
        this.renderTotals();
      }
    }
  }

  renderEmpty() {
    if (this.dom.table) this.dom.table.innerHTML = '<div class="mass-empty">Сначала откройте модель.</div>';
    if (this.dom.totals) this.dom.totals.innerHTML = '';
    if (this.dom.note) this.dom.note.hidden = true;
  }

  renderTable() {
    if (!this.dom.table) return;

    const fragment = document.createDocumentFragment();

    const header = document.createElement('div');
    header.className = 'mass-row mass-row-head';
    header.innerHTML = '<span>Деталь</span><span>Материал</span><span>ρ, г/см³</span><span>Объём</span><span>Масса</span>';
    fragment.appendChild(header);

    this.items.forEach((item) => {
      const row = document.createElement('div');
      row.className = 'mass-row';

      const name = document.createElement('span');
      name.className = 'mass-name';
      const dot = document.createElement('i');
      dot.className = 'mass-dot';
      dot.style.background = this.partColor(item);
      name.appendChild(dot);
      name.appendChild(document.createTextNode(item.name));
      name.title = `${item.name}\nV = ${item.volumeCm3?.toFixed(2) ?? '—'} см³`;
      row.appendChild(name);

      const select = document.createElement('select');
      select.className = 'mass-select';
      for (const material of MATERIALS) {
        const option = document.createElement('option');
        option.value = material.key;
        option.textContent = material.name;
        select.appendChild(option);
      }
      select.value = item.materialKey;
      select.addEventListener('change', () => {
        item.materialKey = select.value;
        const material = MATERIAL_BY_KEY.get(item.materialKey);
        if (material?.density) item.density = material.density;
        densityInput.value = String(item.density);
        this.update();
      });
      row.appendChild(select);

      const densityInput = document.createElement('input');
      densityInput.type = 'number';
      densityInput.min = '0.01';
      densityInput.step = '0.01';
      densityInput.className = 'mass-density';
      densityInput.value = String(item.density);
      densityInput.addEventListener('change', () => {
        const value = Number(densityInput.value);
        if (Number.isFinite(value) && value > 0) {
          item.density = value;
          item.materialKey = 'custom';
          select.value = 'custom';
          this.update();
        } else {
          densityInput.value = String(item.density);
        }
      });
      row.appendChild(densityInput);

      const volume = document.createElement('span');
      volume.className = 'mass-num';
      volume.textContent = formatVolume(item.volumeCm3 ?? 0);
      volume.title = `${(item.volumeCm3 ?? 0).toFixed(2)} см³`;
      row.appendChild(volume);

      const mass = document.createElement('span');
      mass.className = 'mass-num mass-weight';
      mass.textContent = formatMass(item.massG ?? 0);
      mass.title = `${(item.massG ?? 0).toFixed(2)} г`;
      row.appendChild(mass);

      fragment.appendChild(row);
    });

    this.dom.table.replaceChildren(fragment);
    this.updateNote();
  }

  partColor(item) {
    if (this.viewMode === 'cloud' || this.viewMode === 'walls') {
      return `hsl(${PART_HUES[item.id % PART_HUES.length]} 85% 58%)`;
    }

    const material = Array.isArray(item.mesh.material) ? item.mesh.material[0] : item.mesh.material;
    const color = material?.color;
    return color ? `#${color.getHexString()}` : '#8a95a8';
  }

  updateNote() {
    if (!this.dom.note) return;
    if (this.fileMaterials.length) {
      const names = this.fileMaterials
        .map((m) => `${m.name || 'без названия'}${m.density ? ` (${m.density.toFixed(2)} г/см³)` : ''}`)
        .join(', ');
      this.dom.note.textContent = `В файле найдены материалы: ${names}`;
      this.dom.note.hidden = false;
    } else {
      this.dom.note.hidden = true;
    }
  }

  renderTotals() {
    if (!this.dom.totals) return;
    if (!this.items.length) {
      this.dom.totals.innerHTML = '';
      return;
    }

    const unit = UNITS_LABEL[this.units] || 'мм';
    const massG = this.totalMassG;
    const massText = formatMass(massG);
    const volumeText = formatVolume(this.totalVolumeCm3);

    let html = `<div class="mass-total-line"><b>Масса:</b> ${massText}</div>`;
    html += `<div class="mass-total-line"><b>Объём:</b> ${volumeText}</div>`;

    if (this.com) {
      const round = (v) => (Math.abs(v) >= 100 ? v.toFixed(1) : v.toFixed(2));
      html += `<div class="mass-total-line"><b>Центр тяжести:</b> X ${round(this.com.x)}, Y ${round(this.com.y)}, Z ${round(this.com.z)} ${unit}</div>`;

      const box = new THREE.Box3().setFromObject(this.group);
      if (!box.isEmpty()) {
        const center = box.getCenter(new THREE.Vector3());
        const dx = this.com.x - center.x;
        const dy = this.com.y - center.y;
        const dz = this.com.z - center.z;
        html += `<div class="mass-sub">Смещение от центра габарита: ΔX ${round(dx)}, ΔY ${round(dy)}, ΔZ ${round(dz)} ${unit}</div>`;

        const toUnit = UNIT_TO_CM[this.units] * 10;
        const moment = (d) => (massG / 1000) * (d * toUnit);
        html += `<div class="mass-sub">Статический момент: X ${moment(dx).toFixed(2)}, Y ${moment(dy).toFixed(2)}, Z ${moment(dz).toFixed(2)} кг·мм</div>`;
      }
    }

    const balance = this.computeBalance();
    if (balance) {
      html += '<div class="mass-sub" style="margin-top:6px">Баланс по плоскостям (через центр габарита):</div>';
      for (const axis of AXES) {
        const value = balance[axis];
        if (!value) continue;
        const left = Math.round(value.leftShare * 100);
        const right = 100 - left;
        html +=
          '<div class="mass-balance">' +
          `<span class="mass-balance-axis">${AXIS_LABEL[axis]}</span>` +
          '<span class="mass-balance-bar">' +
          `<span class="mass-balance-fill" style="width:${left}%"></span>` +
          '</span>' +
          `<span class="mass-balance-value">${left}% / ${right}%</span>` +
          '</div>';
      }
    }

    const invalid = this.items.filter((i) => !i.valid).length;
    if (invalid > 0) {
      html += `<div class="mass-warn">У ${invalid} детал${invalid === 1 ? 'и' : 'ей'} не удалось посчитать объём (не замкнутая сетка) — масса занижена.</div>`;
    }

    this.dom.totals.innerHTML = html;
  }

  report() {
    return {
      units: this.units,
      parts: this.items.map((item) => ({
        name: item.name,
        material: MATERIAL_BY_KEY.get(item.materialKey)?.name || 'Свой материал',
        density: item.density,
        volumeCm3: item.volumeCm3 ?? 0,
        massG: item.massG ?? 0,
      })),
      totalMassG: this.totalMassG,
      totalVolumeCm3: this.totalVolumeCm3,
      centerOfMass: this.com ? this.com.toArray() : null,
      balance: this.computeBalance(),
      viewMode: this.viewMode,
      volume: this.volumeSummary,
      thickness: this.thicknessSummary,
      fileMaterials: this.fileMaterials,
    };
  }

  async copyReport() {
    const rows = [
      ['Деталь', 'Материал', 'Плотность, г/см3', 'Объём, см3', 'Масса, г'],
      ...this.items.map((item) => [
        item.name,
        MATERIAL_BY_KEY.get(item.materialKey)?.name || 'Свой материал',
        item.density.toFixed(2),
        (item.volumeCm3 ?? 0).toFixed(2),
        (item.massG ?? 0).toFixed(2),
      ]),
      ['ИТОГО', '', '', this.totalVolumeCm3.toFixed(2), this.totalMassG.toFixed(2)],
    ];

    if (this.com) {
      rows.push(['Центр тяжести', '', '', '', '']);
      rows.push(['X', this.com.x.toFixed(2), 'Y', this.com.y.toFixed(2), 'Z', this.com.z.toFixed(2)]);
    }

    const text = rows.map((row) => row.join('\t')).join('\n');

    try {
      await navigator.clipboard.writeText(text);
      if (this.dom.copy) {
        this.dom.copy.textContent = 'Скопировано';
        setTimeout(() => {
          if (this.dom.copy) this.dom.copy.textContent = 'Скопировать отчёт';
        }, 1500);
      }
    } catch {
      console.log(text);
    }
  }
}

/** 40.0 г · 1.234 кг · 68.3 т */
function formatMass(grams) {
  if (!Number.isFinite(grams)) return '—';
  if (grams >= 1_000_000) return `${(grams / 1_000_000).toFixed(2)} т`;
  if (grams >= 1000) return `${(grams / 1000).toFixed(2)} кг`;
  return `${grams.toFixed(1)} г`;
}

/** 5.10 см³ · 1.23 л · 12.5 м³ */
function formatVolume(cm3) {
  if (!Number.isFinite(cm3)) return '—';
  if (cm3 >= 1_000_000) return `${(cm3 / 1_000_000).toFixed(2)} м³`;
  if (cm3 >= 1000) return `${(cm3 / 1000).toFixed(2)} л`;
  return `${cm3.toFixed(2)} см³`;
}
