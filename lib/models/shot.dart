import 'dart:convert';
import 'dart:math' as math;

/// SQLite отдаёт булевы поля как 0/1 (int), а `Shot.toJson()`/тесты — как
/// настоящий Dart bool. Понимаем оба представления.
bool _boolFromJson(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is int) return v == 1;
  return false;
}


/// Из базы `extra` приходит строкой JSON, из тестов и импорта — уже
/// разобранной картой. Битую строку молча считаем отсутствием данных:
/// это справочные показатели, из-за них терять выстрел нельзя.
Map<String, dynamic>? _extraFromJson(Object? v) {
  if (v == null) return null;
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, e) => MapEntry('$k', e));
  if (v is String) {
    if (v.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(v);
      if (decoded is Map) return decoded.map((k, e) => MapEntry('$k', e));
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// Выстрел. Координаты X/Y — в миллиметрах относительно центра мишени.
///
/// Комментарии к выстрелу больше НЕ хранятся здесь как JSON-поле —
/// см. часть C.3 logic-personalization-spec.md: единая таблица `comments`,
/// доступ через `CommentsRepository.forShot(id)`.
class Shot {
  final String id;
  final int shotNumber;
  final int seriesNo;
  final double xMm;
  final double yMm;
  final double score; // денормализовано, пересчитывается scoreFor()
  final DateTime time;
  final bool isFavorite;
  final bool isManuallyEdited;

  /// Идёт ли выстрел в зачёт.
  ///
  /// Пристрелка записывается и рисуется на мишени наравне со всеми, но
  /// в сумму, средние и статистику не входит. Флаг живёт на ВЫСТРЕЛЕ, а
  /// не только в описании упражнения: шаблон могут потом переписать, а
  /// уже отстрелянная тренировка должна остаться такой, какой была.
  final bool counts;

  /// Показатели, для которых в модели нет своих полей.
  ///
  /// Появилось из-за импорта из SCATT: там по каждому выстрелу есть
  /// время прицеливания, удержание внутри 10.5 (в процентах и
  /// относительно средней точки прицеливания) и скорость за 1 с и за
  /// 0.25 с. Заводить под них пять колонок значит намертво привязать
  /// схему к одному прибору — завтра появится другой, с другим набором.
  ///
  /// Хранится как есть, ключи произвольные. Приложение эти значения не
  /// интерпретирует, но отдаёт ассистенту: связать результат с
  /// удержанием и темпом он может только имея их перед глазами.
  final Map<String, dynamic>? extra;

  const Shot({
    required this.id,
    required this.shotNumber,
    required this.seriesNo,
    required this.xMm,
    required this.yMm,
    required this.score,
    required this.time,
    this.isFavorite = false,
    this.isManuallyEdited = false,
    this.counts = true,
    this.extra,
  });

  /// Расстояние от центра мишени до центра пробоины, мм.
  double get radiusMm => math.sqrt(xMm * xMm + yMm * yMm);

  /// Угол в градусах от вертикали (12 часов), по часовой стрелке, 0..360.
  /// yMm > 0 — "вверх" (та же конвенция, что и в TargetPainter, где
  /// экранная Y инвертируется относительно мм-координат).
  double get angleDeg {
    // atan2(x, y): 0° при (x=0, y>0) — "вверх" — это 12 часов; 90° при
    // (x>0, y=0) — "вправо" — это 3 часа (по часовой стрелке).
    final deg = math.atan2(xMm, yMm) * 180 / math.pi;
    return deg < 0 ? deg + 360 : deg;
  }

  Shot copyWith({
    String? id,
    int? shotNumber,
    int? seriesNo,
    double? xMm,
    double? yMm,
    double? score,
    DateTime? time,
    bool? isFavorite,
    bool? isManuallyEdited,
    bool? counts,
    Map<String, dynamic>? extra,
  }) {
    return Shot(
      id: id ?? this.id,
      shotNumber: shotNumber ?? this.shotNumber,
      seriesNo: seriesNo ?? this.seriesNo,
      xMm: xMm ?? this.xMm,
      yMm: yMm ?? this.yMm,
      score: score ?? this.score,
      time: time ?? this.time,
      isFavorite: isFavorite ?? this.isFavorite,
      isManuallyEdited: isManuallyEdited ?? this.isManuallyEdited,
      counts: counts ?? this.counts,
      extra: extra ?? this.extra,
    );
  }

  factory Shot.fromJson(Map<String, dynamic> json) => Shot(
        id: json['id'] as String,
        shotNumber: json['shot_number'] as int,
        seriesNo: json['series_no'] as int,
        xMm: (json['x_mm'] as num).toDouble(),
        yMm: (json['y_mm'] as num).toDouble(),
        score: (json['score'] as num).toDouble(),
        time: DateTime.parse(json['time'] as String),
        isFavorite: _boolFromJson(json['is_favorite']),
        isManuallyEdited: _boolFromJson(json['is_manually_edited']),
        // По умолчанию ДА: у выстрелов, записанных до появления
        // пристрелки, поля нет, и они все зачётные.
        counts: json['counts'] == null || _boolFromJson(json['counts']),
        extra: _extraFromJson(json['extra']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'shot_number': shotNumber,
        'series_no': seriesNo,
        'x_mm': xMm,
        'y_mm': yMm,
        'score': score,
        'time': time.toIso8601String(),
        'is_favorite': isFavorite,
        'is_manually_edited': isManuallyEdited,
        'counts': counts,
        'extra': extra,
      };
}
