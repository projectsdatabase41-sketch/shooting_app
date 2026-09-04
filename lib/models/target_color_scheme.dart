import 'dart:ui' show Color;

/// 15 персонализируемых ключей цвета (часть A.1 логики-спека). Класс с
/// явным полем на каждый ключ — не `Map<String,Color>` — так опечатка в
/// ключе не пройдёт незамеченной мимо компилятора (см. A.2).
///
/// Личные цвета касаются только рабочей зоны стрелка (мишень + панели
/// вокруг неё), не системной темы приложения.
class TargetColorScheme {
  // Группа "Мишень"
  final Color targetPaper;
  final Color targetBullseye;
  final Color ringLines;
  final Color ringLabelsOnPaper;
  final Color ringLabelsOnBullseye;

  // Группа "Пробоины"
  final Color shotSelected;
  final Color shotCurrentSeries;
  final Color shotPastSeries;
  final Color shotNumberText; // используется только в режиме custom (см. A.4)

  // Группа "Правка" (индикаторы)
  final Color compassRing;
  final Color editResultBadge;
  final Color editAngleBadge;

  // Группа "Интерфейс"
  final Color bottomPanelBg;
  final Color bottomPanelText;

  // Группа "Прочее"
  final Color crosshair;

  /// auto/custom режим для shotNumberText (часть A.4).
  final bool shotNumberTextAuto;

  const TargetColorScheme({
    required this.targetPaper,
    required this.targetBullseye,
    required this.ringLines,
    required this.ringLabelsOnPaper,
    required this.ringLabelsOnBullseye,
    required this.shotSelected,
    required this.shotCurrentSeries,
    required this.shotPastSeries,
    required this.shotNumberText,
    required this.compassRing,
    required this.editResultBadge,
    required this.editAngleBadge,
    required this.bottomPanelBg,
    required this.bottomPanelText,
    required this.crosshair,
    this.shotNumberTextAuto = true,
  });

  static const Color _targetPaper = Color(0xFFB0BEC5);
  static const Color _targetBullseye = Color(0xFF1A1A1A);
  static const Color _ringLines = Color(0xFF37474F);
  static const Color _ringLabelsOnPaper = Color(0xFF263238);
  static const Color _ringLabelsOnBullseye = Color(0xFFECEFF1);
  static const Color _shotSelected = Color(0xFFFFD700);
  static const Color _shotCurrentSeries = Color(0xFF8B0000);
  static const Color _shotPastSeries = Color(0xFFBDBDBD);
  static const Color _shotNumberText = Color(0xFFFFFFFF);
  static const Color _compassRing = Color(0xFF00BCD4);
  static const Color _editResultBadge = Color(0xFFFFFFFF);
  static const Color _editAngleBadge = Color(0xFF212121);
  static const Color _bottomPanelBg = Color(0xFF263238);
  static const Color _bottomPanelText = Color(0xFFECEFF1);
  static const Color _crosshair = Color(0x99455A64); // #455A64 @ 60%

  /// Дефолтный пресет — "Классическая" (A.2.1: совпадает с default из A.1).
  static const TargetColorScheme classic = TargetColorScheme(
    targetPaper: _targetPaper,
    targetBullseye: _targetBullseye,
    ringLines: _ringLines,
    ringLabelsOnPaper: _ringLabelsOnPaper,
    ringLabelsOnBullseye: _ringLabelsOnBullseye,
    shotSelected: _shotSelected,
    shotCurrentSeries: _shotCurrentSeries,
    shotPastSeries: _shotPastSeries,
    shotNumberText: _shotNumberText,
    compassRing: _compassRing,
    editResultBadge: _editResultBadge,
    editAngleBadge: _editAngleBadge,
    bottomPanelBg: _bottomPanelBg,
    bottomPanelText: _bottomPanelText,
    crosshair: _crosshair,
  );

  static const TargetColorScheme defaultScheme = classic;

  /// Ключи в порядке таблицы A.1 — используется списком экрана
  /// персонализации, экспортом/импортом (A.2.2) и сравнением с пресетом
  /// (A.2.1: `activePreset` — точное совпадение всех 15 значений).
  static const List<String> allKeys = [
    'target_paper',
    'target_bullseye',
    'ring_lines',
    'ring_labels_on_paper',
    'ring_labels_on_bullseye',
    'shot_selected',
    'shot_current_series',
    'shot_past_series',
    'shot_number_text',
    'compass_ring',
    'edit_result_badge',
    'edit_angle_badge',
    'bottom_panel_bg',
    'bottom_panel_text',
    'crosshair',
  ];

  /// Ключи, физически поддерживающие альфа-канал в диалоге цвета (A.3.1) —
  /// для остальных контрол прозрачности скрыт.
  static const Set<String> alphaCapableKeys = {
    'crosshair',
    'edit_result_badge',
    'edit_angle_badge',
    'compass_ring',
  };

  /// Ключи, для которых показывается переключатель "Автоконтраст текста"
  /// (A.3.1) — только когда редактируется цвет кружка пробоины.
  static const Set<String> autoContrastRelevantKeys = {
    'shot_selected',
    'shot_current_series',
    'shot_past_series',
  };

  Color operator [](String key) {
    switch (key) {
      case 'target_paper':
        return targetPaper;
      case 'target_bullseye':
        return targetBullseye;
      case 'ring_lines':
        return ringLines;
      case 'ring_labels_on_paper':
        return ringLabelsOnPaper;
      case 'ring_labels_on_bullseye':
        return ringLabelsOnBullseye;
      case 'shot_selected':
        return shotSelected;
      case 'shot_current_series':
        return shotCurrentSeries;
      case 'shot_past_series':
        return shotPastSeries;
      case 'shot_number_text':
        return shotNumberText;
      case 'compass_ring':
        return compassRing;
      case 'edit_result_badge':
        return editResultBadge;
      case 'edit_angle_badge':
        return editAngleBadge;
      case 'bottom_panel_bg':
        return bottomPanelBg;
      case 'bottom_panel_text':
        return bottomPanelText;
      case 'crosshair':
        return crosshair;
      default:
        throw ArgumentError('Неизвестный ключ цвета: $key');
    }
  }

  Color defaultFor(String key) => classic[key];

  bool isDefault(String key) => this[key].toARGB32() == defaultFor(key).toARGB32();

  TargetColorScheme copyWithKey(String key, Color value) {
    return copyWith(
      targetPaper: key == 'target_paper' ? value : null,
      targetBullseye: key == 'target_bullseye' ? value : null,
      ringLines: key == 'ring_lines' ? value : null,
      ringLabelsOnPaper: key == 'ring_labels_on_paper' ? value : null,
      ringLabelsOnBullseye: key == 'ring_labels_on_bullseye' ? value : null,
      shotSelected: key == 'shot_selected' ? value : null,
      shotCurrentSeries: key == 'shot_current_series' ? value : null,
      shotPastSeries: key == 'shot_past_series' ? value : null,
      shotNumberText: key == 'shot_number_text' ? value : null,
      compassRing: key == 'compass_ring' ? value : null,
      editResultBadge: key == 'edit_result_badge' ? value : null,
      editAngleBadge: key == 'edit_angle_badge' ? value : null,
      bottomPanelBg: key == 'bottom_panel_bg' ? value : null,
      bottomPanelText: key == 'bottom_panel_text' ? value : null,
      crosshair: key == 'crosshair' ? value : null,
    );
  }

  TargetColorScheme copyWith({
    Color? targetPaper,
    Color? targetBullseye,
    Color? ringLines,
    Color? ringLabelsOnPaper,
    Color? ringLabelsOnBullseye,
    Color? shotSelected,
    Color? shotCurrentSeries,
    Color? shotPastSeries,
    Color? shotNumberText,
    Color? compassRing,
    Color? editResultBadge,
    Color? editAngleBadge,
    Color? bottomPanelBg,
    Color? bottomPanelText,
    Color? crosshair,
    bool? shotNumberTextAuto,
  }) {
    return TargetColorScheme(
      targetPaper: targetPaper ?? this.targetPaper,
      targetBullseye: targetBullseye ?? this.targetBullseye,
      ringLines: ringLines ?? this.ringLines,
      ringLabelsOnPaper: ringLabelsOnPaper ?? this.ringLabelsOnPaper,
      ringLabelsOnBullseye:
          ringLabelsOnBullseye ?? this.ringLabelsOnBullseye,
      shotSelected: shotSelected ?? this.shotSelected,
      shotCurrentSeries: shotCurrentSeries ?? this.shotCurrentSeries,
      shotPastSeries: shotPastSeries ?? this.shotPastSeries,
      shotNumberText: shotNumberText ?? this.shotNumberText,
      compassRing: compassRing ?? this.compassRing,
      editResultBadge: editResultBadge ?? this.editResultBadge,
      editAngleBadge: editAngleBadge ?? this.editAngleBadge,
      bottomPanelBg: bottomPanelBg ?? this.bottomPanelBg,
      bottomPanelText: bottomPanelText ?? this.bottomPanelText,
      crosshair: crosshair ?? this.crosshair,
      shotNumberTextAuto: shotNumberTextAuto ?? this.shotNumberTextAuto,
    );
  }

  /// Точное совпадение всех 15 значений — для вычисления activePreset
  /// (A.2.1), не хранится отдельным полем.
  bool sameColorsAs(TargetColorScheme other) {
    for (final key in allKeys) {
      if (this[key].toARGB32() != other[key].toARGB32()) return false;
    }
    return true;
  }

  static String colorToHex(Color c, {bool withAlpha = true}) {
    final argb = c.toARGB32().toRadixString(16).padLeft(8, '0');
    if (withAlpha) return '#${argb.toUpperCase()}';
    return '#${argb.substring(2).toUpperCase()}';
  }

  static Color hexToColor(String hex) {
    var h = hex.trim().replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) {
      throw FormatException('Некорректный HEX-цвет: $hex');
    }
    final value = int.parse(h, radix: 16);
    return Color(value);
  }

  static bool isValidHex(String hex) {
    try {
      hexToColor(hex);
      return true;
    } catch (_) {
      return false;
    }
  }
}
