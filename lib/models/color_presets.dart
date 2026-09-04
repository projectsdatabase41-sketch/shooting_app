import 'dart:convert';
import 'dart:ui' show Color;
import 'target_color_scheme.dart';

/// Именованный цветовой пресет (часть A.2.1 логики-спека).
class ColorPreset {
  final String name;
  final TargetColorScheme scheme;

  const ColorPreset(this.name, this.scheme);
}

/// 7 пресетов по макетам (A.2.1).
///
/// Контраст ПРОВЕРЕН расчётом по формуле WCAG, а не на глаз. Проверялись
/// пары, от которых зависит читаемость мишени: цифры габаритов на бланке
/// и на яблоке, линии колец на бланке, пробоины текущей серии и прошлых
/// серий — и на бланке, и на яблоке (пробоина может лечь и туда, и туда,
/// поэтому оба фона обязательны).
///
/// Что было исправлено по итогам проверки:
/// * «Оливковая» — тёмно-коричневые пробоины текущей серии на тёмном
///   яблоке давали коэффициент 1.46: выстрел в десятку было физически
///   не разглядеть. Стало 2.71.
/// * «Пастельная» — розовые пробоины на светло-сером бланке 1.66,
///   прошлые серии 1.26 (почти невидимы), линии колец 2.52.
/// * «Тёплая», «Холодная» — прошлые серии 1.42 и 1.79 на бланке.
/// * «Тёмная» — линии колец 1.79 и текущая серия 1.94 на тёмном бланке.
///
/// Потолок здесь геометрический: пробоина обязана читаться и на светлом
/// бланке, и на почти чёрном яблоке, а один цвет не может быть далёк от
/// обоих сразу — максимум для середины около 3.0. Поэтому пробоины ещё
/// и обводятся контрастным контуром (`TargetPainter._drawShotCircle`);
/// это же спасает и произвольные цвета, которые пользователь выберет
/// сам в персонализации, — там никакой пресет не поможет.
class ColorPresets {
  ColorPresets._();

  static const classic = ColorPreset('Классическая', TargetColorScheme.classic);

  static const dark = ColorPreset(
    'Тёмная',
    TargetColorScheme(
      targetPaper: Color(0xFF37474F),
      targetBullseye: Color(0xFF000000),
      ringLines: Color(0xFF86A0AC),
      ringLabelsOnPaper: Color(0xFFCFD8DC),
      ringLabelsOnBullseye: Color(0xFFCFD8DC),
      shotSelected: Color(0xFFFFC400),
      shotCurrentSeries: Color(0xFFFF5252),
      shotPastSeries: Color(0xFF78909C),
      shotNumberText: Color(0xFFFFFFFF),
      compassRing: Color(0xFF26C6DA),
      editResultBadge: Color(0xFFFFFFFF),
      editAngleBadge: Color(0xFFECEFF1),
      bottomPanelBg: Color(0xFF102027),
      bottomPanelText: Color(0xFFECEFF1),
      crosshair: Color(0x9990A4AE),
    ),
  );

  static const highContrast = ColorPreset(
    'Высокий контраст',
    TargetColorScheme(
      targetPaper: Color(0xFFFFFFFF),
      targetBullseye: Color(0xFF000000),
      ringLines: Color(0xFF000000),
      ringLabelsOnPaper: Color(0xFF000000),
      ringLabelsOnBullseye: Color(0xFFFFFFFF),
      shotSelected: Color(0xFFFFEB00),
      shotCurrentSeries: Color(0xFFFF0000),
      shotPastSeries: Color(0xFF9E9E9E),
      shotNumberText: Color(0xFF000000),
      compassRing: Color(0xFF00E5FF),
      editResultBadge: Color(0xFFFFFFFF),
      editAngleBadge: Color(0xFF000000),
      bottomPanelBg: Color(0xFF000000),
      bottomPanelText: Color(0xFFFFFFFF),
      crosshair: Color(0xCC000000),
    ),
  );

  static const warm = ColorPreset(
    'Тёплая',
    TargetColorScheme(
      targetPaper: Color(0xFFD7CCC8),
      targetBullseye: Color(0xFF3E2723),
      ringLines: Color(0xFF6D4C41),
      ringLabelsOnPaper: Color(0xFF4E342E),
      ringLabelsOnBullseye: Color(0xFFEFEBE9),
      shotSelected: Color(0xFFFFB300),
      shotCurrentSeries: Color(0xFFD34012),
      shotPastSeries: Color(0xFF8D7168),
      shotNumberText: Color(0xFFFFFFFF),
      compassRing: Color(0xFFFF8A65),
      editResultBadge: Color(0xFFFFF3E0),
      editAngleBadge: Color(0xFF3E2723),
      bottomPanelBg: Color(0xFF4E342E),
      bottomPanelText: Color(0xFFEFEBE9),
      crosshair: Color(0x996D4C41),
    ),
  );

  static const cold = ColorPreset(
    'Холодная',
    TargetColorScheme(
      targetPaper: Color(0xFFCFD8DC),
      targetBullseye: Color(0xFF102A43),
      ringLines: Color(0xFF334E68),
      ringLabelsOnPaper: Color(0xFF102A43),
      ringLabelsOnBullseye: Color(0xFFF0F4F8),
      shotSelected: Color(0xFFFFD54F),
      shotCurrentSeries: Color(0xFFD0397B),
      shotPastSeries: Color(0xFF67818E),
      shotNumberText: Color(0xFFFFFFFF),
      compassRing: Color(0xFF00ACC1),
      editResultBadge: Color(0xFFFFFFFF),
      editAngleBadge: Color(0xFF102A43),
      bottomPanelBg: Color(0xFF1E3A5F),
      bottomPanelText: Color(0xFFF0F4F8),
      crosshair: Color(0x99334E68),
    ),
  );

  static const olive = ColorPreset(
    'Оливковая',
    TargetColorScheme(
      targetPaper: Color(0xFFC5CAA0),
      targetBullseye: Color(0xFF33361B),
      ringLines: Color(0xFF565A31),
      ringLabelsOnPaper: Color(0xFF33361B),
      ringLabelsOnBullseye: Color(0xFFF1F3E4),
      shotSelected: Color(0xFFF2C744),
      shotCurrentSeries: Color(0xFFC45208),
      shotPastSeries: Color(0xFF70754D),
      shotNumberText: Color(0xFFFFFFFF),
      compassRing: Color(0xFF8D9A45),
      editResultBadge: Color(0xFFF1F3E4),
      editAngleBadge: Color(0xFF33361B),
      bottomPanelBg: Color(0xFF3E4023),
      bottomPanelText: Color(0xFFF1F3E4),
      crosshair: Color(0x99565A31),
    ),
  );

  static const pastel = ColorPreset(
    'Пастельная',
    TargetColorScheme(
      targetPaper: Color(0xFFE1E6EA),
      targetBullseye: Color(0xFF4A4A58),
      ringLines: Color(0xFF6D788D),
      ringLabelsOnPaper: Color(0xFF4A4A58),
      ringLabelsOnBullseye: Color(0xFFF7F7FA),
      shotSelected: Color(0xFFFFE0A3),
      shotCurrentSeries: Color(0xFFD9536F),
      shotPastSeries: Color(0xFF8089A8),
      shotNumberText: Color(0xFF4A4A58),
      compassRing: Color(0xFFA3D9E0),
      editResultBadge: Color(0xFFFFFFFF),
      editAngleBadge: Color(0xFF4A4A58),
      bottomPanelBg: Color(0xFFD3D8E0),
      bottomPanelText: Color(0xFF4A4A58),
      crosshair: Color(0x998891A3),
    ),
  );

  static const List<ColorPreset> all = [
    classic,
    dark,
    highContrast,
    warm,
    cold,
    olive,
    pastel,
  ];

  /// Вычисляет активную карточку — точное совпадение всех 15 значений с
  /// текущей схемой, или `null` если пользователь менял что-то точечно.
  static ColorPreset? activeFor(TargetColorScheme current) {
    for (final p in all) {
      if (p.scheme.sameColorsAs(current)) return p;
    }
    return null;
  }
}

/// Экспорт/импорт цветовой схемы (A.2.2) — JSON только по 15 ключам A.1.
class ColorSchemeIo {
  ColorSchemeIo._();

  static String exportToJson(TargetColorScheme scheme) {
    final map = <String, String>{
      for (final key in TargetColorScheme.allKeys)
        key: TargetColorScheme.colorToHex(scheme[key]),
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  /// Импорт all-or-nothing: невалидный JSON или битый HEX — исключение,
  /// схема не меняется. Неизвестные ключи молча игнорируются. Ключи,
  /// отсутствующие в файле, остаются как есть (не сбрасываются).
  static TargetColorScheme importFromJson(
    String json,
    TargetColorScheme base,
  ) {
    final Map<String, dynamic> map = jsonDecode(json) as Map<String, dynamic>;
    var result = base;
    for (final entry in map.entries) {
      if (!TargetColorScheme.allKeys.contains(entry.key)) continue;
      final hex = entry.value;
      if (hex is! String || !TargetColorScheme.isValidHex(hex)) {
        throw FormatException('Битое значение HEX для ключа ${entry.key}: $hex');
      }
      result = result.copyWithKey(entry.key, TargetColorScheme.hexToColor(hex));
    }
    return result;
  }
}
