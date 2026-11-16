import * as THREE from 'three';

/* Панель расчёта массы, объёма и центра тяжести сборки.
 *
 * Считаем по треугольникам: объём тела — сумма знаковых объёмов тетраэдров
 * (начало координат, три вершины треугольника), центр тяжести — их взвешенное
 * среднее. Такой расчёт не требует полноценного B-Rep и работает на любом
 * GLB/STEP, который уже разобран вьюером.
 *
 * Плотности в г/см³; STEP приходит в миллиметрах, поэтому мм³ → см³ делим на
 * 1000. Имена деталей берём из модели (у сборок бывают «Деталь 1», «Деталь 2»).
 */

export const MATERIALS = [
  { id: 'steel', label: 'Сталь', density: 7.85 },
  { id: 'stainless', label: 'Нержавейка', density: 7.9 },
  { id: 'aluminium', label: 'Алюминий', density: 2.7 },
  { id: 'titanium', label: 'Титан', density: 4.51 },
  { id: 'brass', label: 'Латунь', density: 8.5 },
  { id: 'copper', label: 'Медь', density: 8.96 },
  { id: 'abs', label: 'ABS-пластик', density: 1.04 },
  { id: 'wood', label: 'Дерево', density: 0.7 },
  { id: 'carbon', label: 'Карбон', density: 1.6 },
];

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

function materialList(mesh) {
  return Array.isArray(mesh.material) ? mesh.material : [mesh.material];
}

/** Объём (мм³) и центр тяжести (мм, в мировых координатах) одного меша. */
function meshVolumeCentroid(mesh) {
  const geometry = mesh.geometry;
  const position = geometry && geometry.attributes && geometry.attributes.position;
  if (!position) return { volume: 0, center: null };
  const index = geometry.index;
  mesh.updateWorldMatrix(true, false);
  const m = mesh.matrixWorld;

  const a = new THREE.Vector3();
  const b = new THREE.Vector3();
  const c = new THREE.Vector3();
  const cross = new THREE.Vector3();
  let v6 = 0;
  let sx = 0;
  let sy = 0;
  let sz = 0;

  const total = index ? index.count : position.count;
  for (let i = 0; i + 2 < total; i += 3) {
    const i0 = index ? index.getX(i) : i;
    const i1 = index ? index.getX(i + 1) : i + 1;
    const i2 = index ? index.getX(i + 2) : i + 2;
    a.fromBufferAttribute(position, i0).applyMatrix4(m);
    b.fromBufferAttribute(position, i1).applyMatrix4(m);
    c.fromBufferAttribute(position, i2).applyMatrix4(m);
    // Объём тетраэдра (0, a, b, c): определитель / 6.
    const v = a.dot(cross.copy(b).cross(c)) / 6;
    v6 += v;
    // Центр тетраэдра — (0 + a + b + c) / 4.
    sx += v * (a.x + b.x + c.x) / 4;
    sy += v * (a.y + b.y + c.y) / 4;
    sz += v * (a.z + b.z + c.z) / 4;
  }

  if (Math.abs(v6) < 1e-9) return { volume: 0, center: null };
  return {
    volume: Math.abs(v6),
    center: new THREE.Vector3(sx / v6, sy / v6, sz / v6),
  };
}

function fmtMass(grams) {
  if (!isFinite(grams)) return '—';
  if (grams >= 1000) return `${(grams / 1000).toFixed(2)} кг`;
  if (grams >= 10) return `${grams.toFixed(0)} г`;
  return `${grams.toFixed(1)} г`;
}

/**
 * Создаёт панель и вешает подсветку/скрытие деталей.
 * @param {THREE.Group} modelRoot корень сцены, куда добавлена сборка
 * @param {{dispose?: Function}} [previous] панель прошлой модели
 */
export function attachMassPanel(modelRoot, previous) {
  if (previous && previous.dispose) previous.dispose();

  const panel = document.getElementById('mass');
  if (!panel) return { dispose() {} };

  // Собираем детали: меши внутри модели. Группа может быть вложенной.
  const parts = [];
  modelRoot.traverse((obj) => {
    if (obj.isMesh && obj.geometry) {
      const { volume, center } = meshVolumeCentroid(obj);
      parts.push({
        mesh: obj,
        name: obj.name && obj.name !== 'part' ? obj.name : `Деталь ${parts.length + 1}`,
        volume, // мм³
        center, // мировая точка или null
        density: MATERIALS[0].density,
        materialId: MATERIALS[0].id,
        hidden: false,
      });
    }
  });

  if (!parts.length) {
    panel.hidden = true;
    return { dispose() {} };
  }

  // Маркер центра тяжести выбранной детали.
  const marker = new THREE.Mesh(
    new THREE.SphereGeometry(1, 16, 12),
    new THREE.MeshBasicMaterial({ color: 0xff5c33, depthTest: false, transparent: true }),
  );
  marker.renderOrder = 999;
  marker.visible = false;
  modelRoot.add(marker);

  const box = new THREE.Box3().setFromObject(modelRoot);
  const size = new THREE.Vector3();
  box.getSize(size);
  const markerRadius = Math.max(size.length() * 0.004, 0.4);

  // Сохраняем исходные параметры материалов, чтобы вернуть их после подсветки.
  const restore = new Map();
  for (const part of parts) {
    restore.set(part.mesh, materialList(part.mesh).map((mat) => ({
      transparent: mat.transparent,
      opacity: mat.opacity,
      depthWrite: mat.depthWrite,
      emissive: mat.emissive ? mat.emissive.clone() : null,
      color: mat.color ? mat.color.clone() : null,
    })));
  }

  function applyAppearance() {
    const hovered = state.hovered;
    for (const part of parts) {
      const mesh = part.mesh;
      mesh.visible = !part.hidden;
      const saved = restore.get(mesh) || [];
      materialList(mesh).forEach((mat, i) => {
        const s = saved[i];
        if (!s) return;
        if (hovered && part !== hovered && !part.hidden) {
          mat.transparent = true;
          mat.opacity = clamp(s.opacity * 0.16, 0.05, 0.2);
          mat.depthWrite = false;
          if (mat.emissive) mat.emissive.setRGB(0, 0, 0);
        } else {
          mat.transparent = s.transparent;
          mat.opacity = s.opacity;
          mat.depthWrite = s.depthWrite;
          if (mat.emissive && s.emissive) {
            if (hovered && part === hovered) {
              // Подсветка выбранной детали: её грани светятся акцентом.
              mat.emissive.copy(mat.color || s.color || mat.emissive).multiplyScalar(0.35);
            } else {
              mat.emissive.copy(s.emissive);
            }
          }
        }
        mat.needsUpdate = true;
      });
    }
    if (hovered && hovered.center && !hovered.hidden) {
      marker.position.copy(hovered.center);
      marker.scale.setScalar(markerRadius);
      marker.visible = true;
    } else {
      marker.visible = false;
    }
  }

  const state = { hovered: null };

  function totals() {
    let mass = 0;
    let volume = 0;
    let mx = 0;
    let my = 0;
    let mz = 0;
    for (const part of parts) {
      if (part.hidden) continue;
      const cm3 = part.volume / 1000;
      const grams = cm3 * part.density;
      mass += grams;
      volume += cm3;
      if (part.center) {
        mx += part.center.x * grams;
        my += part.center.y * grams;
        mz += part.center.z * grams;
      }
    }
    return {
      mass,
      volume,
      center: mass > 0 ? new THREE.Vector3(mx / mass, my / mass, mz / mass) : null,
    };
  }

  let rows = [];
  function render() {
    const sum = totals();
    panel.innerHTML = '';

    const head = document.createElement('div');
    head.className = 'mass-head';
    head.innerHTML = `<span>Детали: ${parts.length}</span>
      <span class="mass-sum">${fmtMass(sum.mass)} · ${sum.volume.toFixed(1)} см³</span>`;
    panel.appendChild(head);

    const list = document.createElement('div');
    list.className = 'mass-list';

    parts.forEach((part, index) => {
      const cm3 = part.volume / 1000;
      const grams = cm3 * part.density;
      const row = document.createElement('div');
      row.className = 'mass-row' + (part.hidden ? ' is-hidden' : '');
      row.innerHTML = `
        <label class="mass-eye" title="Скрыть деталь из вида и расчётов">
          <input type="checkbox" ${part.hidden ? 'checked' : ''}>
        </label>
        <div class="mass-main">
          <div class="mass-name" title="${part.name}">${part.name}</div>
          <div class="mass-meta">${cm3.toFixed(2)} см³ · ${fmtMass(grams)}</div>
        </div>
        <select class="mass-mat" title="Материал детали">
          ${MATERIALS.map((m) => `<option value="${m.id}" ${m.id === part.materialId ? 'selected' : ''}>${m.label}</option>`).join('')}
        </select>`;
      const eye = row.querySelector('input');
      const select = row.querySelector('select');
      eye.addEventListener('change', () => {
        part.hidden = eye.checked;
        applyAppearance();
        render();
      });
      select.addEventListener('change', () => {
        const found = MATERIALS.find((m) => m.id === select.value) || MATERIALS[0];
        part.materialId = found.id;
        part.density = found.density;
        render();
      });
      row.addEventListener('mouseenter', () => {
        state.hovered = part;
        applyAppearance();
      });
      row.addEventListener('mouseleave', () => {
        state.hovered = null;
        applyAppearance();
      });
      // На телефоне наведения нет — тап по строке тоже подсвечивает деталь.
      row.addEventListener('click', (e) => {
        if (e.target === eye || e.target === select) return;
        state.hovered = state.hovered === part ? null : part;
        applyAppearance();
      });
      list.appendChild(row);
      rows.push(row);
    });

    panel.appendChild(list);
    panel.hidden = false;

    if (sum.center) marker.position.copy(sum.center);
  }

  render();

  return {
    dispose() {
      for (const part of parts) {
        const saved = restore.get(part.mesh) || [];
        part.mesh.visible = true;
        materialList(part.mesh).forEach((mat, i) => {
          const s = saved[i];
          if (!s) return;
          mat.transparent = s.transparent;
          mat.opacity = s.opacity;
          mat.depthWrite = s.depthWrite;
          if (mat.emissive && s.emissive) mat.emissive.copy(s.emissive);
          mat.needsUpdate = true;
        });
      }
      marker.remove();
      if (marker.geometry) marker.geometry.dispose();
      if (marker.material) marker.material.dispose();
      panel.hidden = true;
      panel.innerHTML = '';
      rows = [];
    },
  };
}
