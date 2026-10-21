import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import '../services/local_db_service.dart';

/// Оттенок фоновых картинок под цвета приложения.
///
/// Картинки нарисованы в сине-голубой гамме. Вместо отдельных картинок под каждый пресет оттенок и
/// насыщенность меняются на лету (поворот оттенка + насыщенность через цветовой фильтр):
///  • `auto` — по акцентному цвету выбранного пресета (кнопки, а если они серые — текст кнопок);
///    пока свои цвета не заданы, картинки остаются исходными;
///  • `manual` — по ползункам «Оттенок» и «Насыщенность» в настройках;
///  • `off` — исходные картинки.
/// Золотые фоны «Чемпионов» и «Финалов» не перекрашиваются (золото — часть смысла).
class BackdropTint {
  BackdropTint._();

  /// Оттенок исходных картинок (синий), градусы.
  static const double baseHue = 212;

  /// Фоны, которые не перекрашиваются.
  static const Set<String> exempt = {'champions', 'finals'};

  static const _kMode = 'backdrop_tint_mode';
  static const _kHue = 'backdrop_tint_hue';
  static const _kSat = 'backdrop_tint_sat';

  static String mode = 'auto'; // auto | manual | off
  static double hue = baseHue; // для manual
  static double sat = 1.0; // для manual, 0..1.5

  // Слои обоев (см. wallpaper.dart).
  static double frontOpacity = 1.0; // прозрачность переднего листа с вырезами
  static double vignette = 0.35; // затемнение к краям
  static double blur = 0; // размытие заднего листа, px
  static const _kFront = 'wallpaper_front_opacity';
  static const _kVignette = 'wallpaper_vignette';
  static const _kBlur = 'wallpaper_blur';

  /// «Стирание» переднего листа мягкой фигурой или с одной из сторон: сквозь стёртое место виден задний лист.
  /// Форма: none | left | right | top | bottom | circle | star | square | band | triangle.
  static const eraseShapes = ['none', 'left', 'right', 'top', 'bottom', 'circle', 'star', 'square', 'band', 'triangle'];
  static String eraseShape = 'none';
  static double eraseSoft = 0.6; // 0 — чёткий край … 1 — очень размытый
  static double eraseStrength = 0.7; // 0..1, насколько стирается
  static double eraseSize = 0.8; // 0.2..1.6, размер относительно экрана
  static const _kEShape = 'wallpaper_erase_shape';
  static const _kESoft = 'wallpaper_erase_soft';
  static const _kEStrength = 'wallpaper_erase_strength';
  static const _kESize = 'wallpaper_erase_size';

  /// Растёт при любом изменении параметров оформления — обои перерисовываются.
  static final revision = ValueNotifier<int>(0);

  /// Оттенок и насыщенность, из которых строятся обои (с учётом режима).
  static double effectiveHue() {
    final t = current();
    return t == null ? baseHue : (baseHue + t.shift) % 360;
  }

  static double effectiveSat() => current()?.sat ?? 1.0;

  /// Текущий фильтр; `null` — картинки без изменений. На него подписаны фоны.
  static final filter = ValueNotifier<ColorFilter?>(null);

  static Color? _button;
  static Color? _buttonText;

  static void load(LocalDbService db) {
    String? get(String k) {
      final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [k]);
      return r.isEmpty ? null : '${r.first['hex']}';
    }

    final m = get(_kMode);
    if (m == 'auto' || m == 'manual' || m == 'off') mode = m!;
    hue = (double.tryParse(get(_kHue) ?? '') ?? baseHue).clamp(0.0, 360.0).toDouble();
    sat = (double.tryParse(get(_kSat) ?? '') ?? 1.0).clamp(0.0, 1.5).toDouble();
    frontOpacity = (double.tryParse(get(_kFront) ?? '') ?? 1.0).clamp(0.3, 1.0).toDouble();
    vignette = (double.tryParse(get(_kVignette) ?? '') ?? 0.35).clamp(0.0, 1.0).toDouble();
    blur = (double.tryParse(get(_kBlur) ?? '') ?? 0).clamp(0.0, 30.0).toDouble();
    final es = get(_kEShape);
    eraseShape = eraseShapes.contains(es) ? es! : 'none';
    eraseSoft = (double.tryParse(get(_kESoft) ?? '') ?? 0.6).clamp(0.0, 1.0).toDouble();
    eraseStrength = (double.tryParse(get(_kEStrength) ?? '') ?? 0.7).clamp(0.0, 1.0).toDouble();
    eraseSize = (double.tryParse(get(_kESize) ?? '') ?? 0.8).clamp(0.2, 1.6).toDouble();
    recompute();
  }

  static void save(LocalDbService db,
      {String? newMode,
      double? newHue,
      double? newSat,
      double? newFront,
      double? newVignette,
      double? newBlur,
      String? newEraseShape,
      double? newEraseSoft,
      double? newEraseStrength,
      double? newEraseSize}) {
    void put(String k, String v) => db.db.execute(
        'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [k, v]);
    if (newMode != null) {
      mode = newMode;
      put(_kMode, newMode);
    }
    if (newHue != null) {
      hue = newHue.clamp(0.0, 360.0).toDouble();
      put(_kHue, hue.toStringAsFixed(0));
    }
    if (newSat != null) {
      sat = newSat.clamp(0.0, 1.5).toDouble();
      put(_kSat, sat.toStringAsFixed(2));
    }
    if (newFront != null) {
      frontOpacity = newFront.clamp(0.3, 1.0).toDouble();
      put(_kFront, frontOpacity.toStringAsFixed(2));
    }
    if (newVignette != null) {
      vignette = newVignette.clamp(0.0, 1.0).toDouble();
      put(_kVignette, vignette.toStringAsFixed(2));
    }
    if (newBlur != null) {
      blur = newBlur.clamp(0.0, 30.0).toDouble();
      put(_kBlur, blur.toStringAsFixed(1));
    }
    if (newEraseShape != null && eraseShapes.contains(newEraseShape)) {
      eraseShape = newEraseShape;
      put(_kEShape, newEraseShape);
    }
    if (newEraseSoft != null) {
      eraseSoft = newEraseSoft.clamp(0.0, 1.0).toDouble();
      put(_kESoft, eraseSoft.toStringAsFixed(2));
    }
    if (newEraseStrength != null) {
      eraseStrength = newEraseStrength.clamp(0.0, 1.0).toDouble();
      put(_kEStrength, eraseStrength.toStringAsFixed(2));
    }
    if (newEraseSize != null) {
      eraseSize = newEraseSize.clamp(0.2, 1.6).toDouble();
      put(_kESize, eraseSize.toStringAsFixed(2));
    }
    recompute();
  }

  /// Акцентные цвета выбранного набора приложения (для режима `auto`); `null` — свои цвета не заданы.
  static void setAccent(Color? button, Color? buttonText) {
    _button = button;
    _buttonText = buttonText;
    recompute();
  }

  static void recompute() {
    final f = _build();
    // ColorFilter сравнивается по значению; лишние уведомления не нужны
    if (f != filter.value) filter.value = f;
    revision.value++;
  }

  static double _norm180(double d) {
    var x = d % 360;
    if (x > 180) x -= 360;
    if (x < -180) x += 360;
    return x;
  }

  static ColorFilter? _build() {
    final t = current();
    return t == null ? null : ColorFilter.matrix(matrix(t.shift, t.sat));
  }

  /// Действующий сдвиг оттенка и насыщенность для ВСЕГО оформления (картинки фона, цвета
  /// интерфейса); `null` — без изменений.
  static ({double shift, double sat})? current() {
    if (mode == 'off') return null;
    if (mode == 'manual') {
      final shift = _norm180(hue - baseHue);
      if (shift.abs() < 0.5 && (sat - 1).abs() < 0.01) return null;
      return (shift: shift, sat: sat);
    }
    // auto
    if (_button == null && _buttonText == null) return null; // пресет не выбран — исходное оформление
    Color? accent;
    for (final c in [_button, _buttonText]) {
      if (c != null && HSLColor.fromColor(c).saturation >= 0.25) {
        accent = c;
        break;
      }
    }
    if (accent == null) return (shift: 0, sat: 0.45); // нейтральный пресет: приглушаем
    final hsl = HSLColor.fromColor(accent);
    return (shift: _norm180(hsl.hue - baseHue), sat: (hsl.saturation * 1.5).clamp(0.45, 1.15).toDouble());
  }

  /// Цвет, прогнанный через тот же сдвиг оттенка и насыщенность, что и картинки фона.
  static Color tint(Color c, ({double shift, double sat}) t) {
    final m = matrix(t.shift, t.sat);
    final r = c.r, g = c.g, b = c.b;
    double ch(double v) => v.clamp(0.0, 1.0).toDouble();
    return Color.from(
      alpha: c.a,
      red: ch(m[0] * r + m[1] * g + m[2] * b),
      green: ch(m[5] * r + m[6] * g + m[7] * b),
      blue: ch(m[10] * r + m[11] * g + m[12] * b),
    );
  }

  /// Цветовая схема интерфейса с общим оттенком: сине-серое семейство (основной цвет, поверхности,
  /// контуры) смещается вместе с фоном; янтарный акцент, зелёный и красный (ошибка) не трогаем.
  static ColorScheme tintScheme(ColorScheme cs) {
    final t = current();
    if (t == null) return cs;
    Color k(Color c) => tint(c, t);
    return cs.copyWith(
      primary: k(cs.primary),
      onPrimary: k(cs.onPrimary),
      primaryContainer: k(cs.primaryContainer),
      onPrimaryContainer: k(cs.onPrimaryContainer),
      surface: k(cs.surface),
      onSurface: k(cs.onSurface),
      surfaceContainerLowest: k(cs.surfaceContainerLowest),
      surfaceContainerLow: k(cs.surfaceContainerLow),
      surfaceContainer: k(cs.surfaceContainer),
      surfaceContainerHigh: k(cs.surfaceContainerHigh),
      surfaceContainerHighest: k(cs.surfaceContainerHighest),
      onSurfaceVariant: k(cs.onSurfaceVariant),
      outline: k(cs.outline),
      outlineVariant: k(cs.outlineVariant),
    );
  }

  /// Ручной режим: основные цвета интерфейса (фон, кнопки, текст на кнопках) собираются из одного
  /// оттенка — вместе с картинками получается цельный вид. В авто-режиме `null` (работают цвета пресета).
  static ({Color background, Color button, Color buttonText})? derivedColors(Brightness b) {
    if (mode != 'manual') return null;
    final s = sat.clamp(0.0, 1.5).toDouble();
    double q(double v) => (v * s).clamp(0.0, 1.0).toDouble();
    Color hsl(double sat0, double l) => HSLColor.fromAHSL(1, hue % 360, q(sat0), l).toColor();
    return b == Brightness.dark
        ? (background: hsl(0.22, 0.06), button: hsl(0.42, 0.30), buttonText: hsl(0.50, 0.90))
        : (background: hsl(0.30, 0.965), button: hsl(0.48, 0.34), buttonText: Colors.white);
  }

  /// Матрица 4×5: насыщенность [s], затем поворот оттенка на [hueDeg] градусов (сохраняет яркость).
  static List<double> matrix(double hueDeg, double s) {
    final r = hueDeg * math.pi / 180;
    final c = math.cos(r), n = math.sin(r);
    // поворот оттенка
    final h = <double>[
      0.213 + c * 0.787 - n * 0.213, 0.715 - c * 0.715 - n * 0.715, 0.072 - c * 0.072 + n * 0.928,
      0.213 - c * 0.213 + n * 0.143, 0.715 + c * 0.285 + n * 0.140, 0.072 - c * 0.072 - n * 0.283,
      0.213 - c * 0.213 - n * 0.787, 0.715 - c * 0.715 + n * 0.715, 0.072 + c * 0.928 + n * 0.072,
    ];
    // насыщенность
    final sr = 0.213, sg = 0.715, sb = 0.072;
    final sm = <double>[
      sr * (1 - s) + s, sg * (1 - s), sb * (1 - s),
      sr * (1 - s), sg * (1 - s) + s, sb * (1 - s),
      sr * (1 - s), sg * (1 - s), sb * (1 - s) + s,
    ];
    // итог = h · sm (3×3)
    final m3 = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        for (var k = 0; k < 3; k++) {
          m3[i * 3 + j] += h[i * 3 + k] * sm[k * 3 + j];
        }
      }
    }
    return [
      m3[0], m3[1], m3[2], 0, 0,
      m3[3], m3[4], m3[5], 0, 0,
      m3[6], m3[7], m3[8], 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Применить фильтр к картинке фона [kind] (золотые фоны не трогаем).
  static Widget apply(String kind, Widget image) {
    if (exempt.contains(kind)) return image;
    return ValueListenableBuilder<ColorFilter?>(
      valueListenable: filter,
      builder: (_, f, child) => f == null ? child! : ColorFiltered(colorFilter: f, child: child),
      child: image,
    );
  }

  /// Яркость, с которой сейчас рисуется интерфейс (для выбора набора цветов тёмной/светлой темы).
  static Brightness systemBrightness() => PlatformDispatcher.instance.platformBrightness;
}
