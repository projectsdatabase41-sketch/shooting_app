import 'series_spec.dart';

enum ExerciseGender { male, female, mixed }

/// Упражнение-шаблон. Создаётся пользователем — приложение стартует
/// полностью пустым, без предустановленного набора (раздел 10 ТЗ).
class Exercise {
  final String id;
  final String name;
  final String targetFaceCode;
  final int totalShots;
  final int seriesSize;
  final ExerciseGender gender;

  /// Когда упражнение удалили. `null` — обычное, живое упражнение.
  ///
  /// Удаление мягкое: строку нельзя убрать физически, на неё ссылаются
  /// тренировки, а терять их пользователь не просил — наоборот, просил
  /// прямо обратного. Помеченное упражнение исчезает из выбора при
  /// создании тренировки, но история и ассистент по-прежнему видят его
  /// название.
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// Описание серий. Пустой список — упражнение старого вида, где все
  /// серии одинаковы и заданы парой totalShots/seriesSize.
  final List<SeriesSpec> series;

  /// Подпись для истории и для ассистента.
  ///
  /// Кода у упражнения больше нет: он дублировал название, и в списках
  /// выходило «234 234» либо голое «234» без смысла.
  String get label => isDeleted ? '$name (удалено)' : name;

  /// Описание серии по её номеру (нумерация с единицы). За пределами
  /// списка — `null`: серия обычная, идёт в зачёт.
  SeriesSpec? specFor(int seriesNo) {
    final i = seriesNo - 1;
    if (i < 0 || i >= series.length) return null;
    return series[i];
  }

  /// Идёт ли серия в зачёт. Для упражнений без описания — да.
  bool countsSeries(int seriesNo) => specFor(seriesNo)?.counts ?? true;

  const Exercise({
    required this.id,
    required this.name,
    required this.targetFaceCode,
    required this.totalShots,
    required this.seriesSize,
    this.gender = ExerciseGender.mixed,
    this.deletedAt,
    this.series = const [],
  });

  Exercise copyWith({
    String? id,
    String? name,
    String? targetFaceCode,
    int? totalShots,
    int? seriesSize,
    ExerciseGender? gender,
    DateTime? deletedAt,
    List<SeriesSpec>? series,
  }) {
    return Exercise(
      id: id ?? this.id,
      name: name ?? this.name,
      targetFaceCode: targetFaceCode ?? this.targetFaceCode,
      totalShots: totalShots ?? this.totalShots,
      seriesSize: seriesSize ?? this.seriesSize,
      gender: gender ?? this.gender,
      deletedAt: deletedAt ?? this.deletedAt,
      series: series ?? this.series,
    );
  }

  factory Exercise.fromJson(Map<String, dynamic> json) => Exercise(
        id: json['id'] as String,
        name: json['name'] as String,
        targetFaceCode: json['target_face_code'] as String,
        totalShots: json['total_shots'] as int,
        seriesSize: json['series_size'] as int,
        gender: ExerciseGender.values.firstWhere(
          (g) => g.name == (json['gender'] as String? ?? 'mixed'),
          orElse: () => ExerciseGender.mixed,
        ),
        deletedAt: json['deleted_at'] == null
            ? null
            : DateTime.parse(json['deleted_at'] as String),
        series: seriesFromJson(json['series']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'target_face_code': targetFaceCode,
        'total_shots': totalShots,
        'series_size': seriesSize,
        'gender': gender.name,
        'deleted_at': deletedAt?.toIso8601String(),
        'series': [for (final s in series) s.toJson()],
      };
}
