import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'package:image/image.dart' as img;

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

  // Обои: чёрно-белая картинка + цветная маска (см. wallpaper.dart).
  static double mask = 0.4; // непрозрачность маски 0..1 (прозрачность = 1 - mask)
  static double wBright = 0; // яркость обоев -0.5..0.5 (обе темы)
  static double wContrast = 1; // контраст обоев 0.5..1.5
  static double blur = 9; // размытие обоев: 0..30 (доля подмешанной размытой копии)
  static const _kMask = 'wallpaper_mask';
  static const _kWBright = 'wallpaper_bright';
  static const _kWContrast = 'wallpaper_contrast';
  static const _kBlur = 'wallpaper_blur';

  /// Цвет маски для обоев [kind] или null (режим «Исходный» - картинка без цвета).
  /// Золотые обои («Чемпионы», «Финалы») всегда золотые.
  static Color? maskColor(String kind) {
    if (mode == 'off') return null;
    final gold = exempt.contains(kind);
    final h = gold ? 42.0 : effectiveHue();
    final s = gold ? 0.9 : (effectiveSat() * 0.7).clamp(0.0, 1.0).toDouble();
    return HSLColor.fromAHSL(mask.clamp(0.0, 1.0).toDouble(), h % 360, s, 0.5).toColor();
  }

  /// Матрица яркости и контраста для готовых обоев.
  static List<double> wallpaperMatrix() {
    final c = wContrast;
    final off = ((1 - c) * 0.5 + wBright) * 255;
    return [c, 0, 0, 0, off, 0, c, 0, 0, off, 0, 0, c, 0, off, 0, 0, 0, 1, 0];
  }

  /// Прозрачность маски 0..1 (для ползунка и ИИ).
  static double get transparency => 1 - mask;

  // Свои обои (фото пользователя): яркость, контраст, оттенок, виньетка.
  static bool customOn = false;
  static String? customB64;
  static double cBright = 0; // -0.5..0.5
  static double cContrast = 1; // 0.5..1.8
  static double cHue = 0; // -180..180
  static double cVignette = 0.3; // 0..1
  static ui.Image? customImage;
  static const _kCOn = 'wallpaper_custom_on';
  static const _kCImg = 'wallpaper_custom_img';
  static const _kCBright = 'wallpaper_custom_bright';
  static const _kCContrast = 'wallpaper_custom_contrast';
  static const _kCHue = 'wallpaper_custom_hue';
  static const _kCVig = 'wallpaper_custom_vignette';

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
    mask = (double.tryParse(get(_kMask) ?? '') ?? 0.4).clamp(0.0, 1.0).toDouble();
    wBright = (double.tryParse(get(_kWBright) ?? '') ?? 0).clamp(-0.5, 0.5).toDouble();
    wContrast = (double.tryParse(get(_kWContrast) ?? '') ?? 1).clamp(0.5, 1.5).toDouble();
    blur = (double.tryParse(get(_kBlur) ?? '') ?? 9).clamp(0.0, 30.0).toDouble();
    customOn = get(_kCOn) == '1';
    customB64 = get(_kCImg);
    cBright = (double.tryParse(get(_kCBright) ?? '') ?? 0).clamp(-0.5, 0.5).toDouble();
    cContrast = (double.tryParse(get(_kCContrast) ?? '') ?? 1).clamp(0.5, 1.8).toDouble();
    cHue = (double.tryParse(get(_kCHue) ?? '') ?? 0).clamp(-180.0, 180.0).toDouble();
    cVignette = (double.tryParse(get(_kCVig) ?? '') ?? 0.3).clamp(0.0, 1.0).toDouble();
    if (customOn && customB64 != null && customB64!.isNotEmpty) _decodeCustom();
    recompute();
  }

  static void save(LocalDbService db,
      {String? newMode,
      double? newHue,
      double? newSat,
      double? newMask,
      double? newWBright,
      double? newWContrast,
      double? newBlur,
      bool? newCustomOn,
      double? newCBright,
      double? newCContrast,
      double? newCHue,
      double? newCVignette}) {
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
    if (newMask != null) {
      mask = newMask.clamp(0.0, 1.0).toDouble();
      put(_kMask, mask.toStringAsFixed(2));
    }
    if (newWBright != null) {
      wBright = newWBright.clamp(-0.5, 0.5).toDouble();
      put(_kWBright, wBright.toStringAsFixed(2));
    }
    if (newWContrast != null) {
      wContrast = newWContrast.clamp(0.5, 1.5).toDouble();
      put(_kWContrast, wContrast.toStringAsFixed(2));
    }
    if (newBlur != null) {
      blur = newBlur.clamp(0.0, 30.0).toDouble();
      put(_kBlur, blur.toStringAsFixed(1));
    }
    if (newCustomOn != null) {
      customOn = newCustomOn;
      put(_kCOn, newCustomOn ? '1' : '0');
      if (newCustomOn && customImage == null && customB64 != null) _decodeCustom();
    }
    if (newCBright != null) {
      cBright = newCBright.clamp(-0.5, 0.5).toDouble();
      put(_kCBright, cBright.toStringAsFixed(2));
    }
    if (newCContrast != null) {
      cContrast = newCContrast.clamp(0.5, 1.8).toDouble();
      put(_kCContrast, cContrast.toStringAsFixed(2));
    }
    if (newCHue != null) {
      cHue = newCHue.clamp(-180.0, 180.0).toDouble();
      put(_kCHue, cHue.toStringAsFixed(0));
    }
    if (newCVignette != null) {
      cVignette = newCVignette.clamp(0.0, 1.0).toDouble();
      put(_kCVig, cVignette.toStringAsFixed(2));
    }
    recompute();
  }

  /// Текущие настройки оформления для ИИ: доли 0..1 (оттенок — градусы, насыщенность 0..1.5).
  static Map<String, dynamic> snapshot() => {
        'mode': mode,
        'hue': hue.round(),
        'sat': double.parse(sat.toStringAsFixed(2)),
        'blur': double.parse((blur / 30).toStringAsFixed(2)),
        'transparency': double.parse(transparency.toStringAsFixed(2)),
        'custom_wallpaper': customOn,
      };

  /// Что ИИ может менять (ключ -> диапазон). Остальное в блоке считается негодным.
  static const aiKeys = {'blur': (0.0, 1.0), 'transparency': (0.0, 1.0), 'hue': (0.0, 360.0), 'sat': (0.0, 1.5)};

  /// Проверка спецификации от ИИ: известные ключи, числа в диапазонах, режим из списка, хоть одно поле.
  static bool validAppearance(Map<String, dynamic> spec) {
    var any = false;
    for (final e in spec.entries) {
      if (e.key == 'mode') {
        if (!const {'auto', 'manual', 'off'}.contains(e.value)) return false;
      } else {
        final r = aiKeys[e.key];
        final v = e.value;
        if (r == null || v is! num || v < r.$1 || v > r.$2) return false;
      }
      any = true;
    }
    return any;
  }

  /// Применяет спецификацию; возвращает снимок «до» для отмены.
  static Map<String, dynamic> applyAppearance(LocalDbService db, Map<String, dynamic> spec) {
    final before = snapshot();
    double? d(String k) => (spec[k] as num?)?.toDouble();
    save(db,
        newMode: spec['mode'] as String?,
        newHue: d('hue'),
        newSat: d('sat'),
        newBlur: d('blur') == null ? null : d('blur')! * 30,
        newMask: d('transparency') == null ? null : 1 - d('transparency')!);
    return before;
  }

  /// Откат к снимку из [applyAppearance].
  static void restoreAppearance(LocalDbService db, Map<String, dynamic> snap) {
    save(db,
        newMode: snap['mode'] as String,
        newHue: (snap['hue'] as num).toDouble(),
        newSat: (snap['sat'] as num).toDouble(),
        newBlur: (snap['blur'] as num).toDouble() * 30,
        newMask: 1 - (snap['transparency'] as num).toDouble());
  }

  /// Свои обои: файл уменьшается (длинная сторона до 1440 px), хранится в базе как JPEG; `false` — не картинка.
  static Future<bool> setCustomImage(LocalDbService db, Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return false;
    final longest = math.max(decoded.width, decoded.height);
    final resized = longest > 1440 ? img.copyResize(decoded, width: decoded.width >= decoded.height ? 1440 : null, height: decoded.height > decoded.width ? 1440 : null) : decoded;
    final b64 = base64Encode(img.encodeJpg(resized, quality: 82));
    customB64 = b64;
    db.db.execute('INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [_kCImg, b64]);
    customImage = null;
    await _decodeCustom();
    save(db, newCustomOn: true);
    return true;
  }

  static void clearCustomImage(LocalDbService db) {
    customB64 = null;
    customImage = null;
    db.db.execute("DELETE FROM color_prefs WHERE key = ?", [_kCImg]);
    save(db, newCustomOn: false);
  }

  static Future<void> _decodeCustom() async {
    final b64 = customB64;
    if (b64 == null || b64.isEmpty) return;
    try {
      final codec = await ui.instantiateImageCodec(base64Decode(b64));
      customImage = (await codec.getNextFrame()).image;
      revision.value++;
    } catch (_) {
      customImage = null;
    }
  }

  /// Матрица цветового фильтра для своих обоев: оттенок, контраст, яркость.
  static List<double> customMatrix() {
    final h = matrix(cHue, 1);
    final c = cContrast;
    final off = ((1 - c) * 0.5 + cBright) * 255;
    return [
      h[0] * c, h[1] * c, h[2] * c, 0, off,
      h[5] * c, h[6] * c, h[7] * c, 0, off,
      h[10] * c, h[11] * c, h[12] * c, 0, off,
      0, 0, 0, 1, 0,
    ];
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
