import 'dart:convert';

/// Одна серия в описании упражнения.
///
/// Упражнение перестало быть парой «сколько всего выстрелов» и «по
/// скольку в серии»: реальное задание выглядит иначе — пристрелка,
/// потом лёжа, потом стоя, и у каждой части свои правила. Отсюда три
/// вещи, которых раньше не было.
///
/// **Название.** Свободный текст с готовыми вариантами на выбор. Нужно
/// не для красоты: ассистент по нему понимает, ЧТО стрелок делал в этот
/// момент, и может сравнить «лёжа против стоя» — по номеру серии такое
/// не сопоставить.
///
/// **Зачёт.** Пристрелка пишется и видна на мишени, но в сумму и
/// статистику не идёт. Решение пользователя: выстрел учитывается
/// всегда, просто помечается системой.
///
/// **Граница серии.** Либо по числу выстрелов, либо по времени
/// (пристрелка 15 минут). Когда время вышло, приложение предупреждает,
/// но стрелять не запрещает и «опоздание» не помечает — выстрел мог
/// уйти за последнюю секунду, и клеймо было бы враньём.
class SeriesSpec {
  final String name;

  /// Сколько выстрелов в серии. `null` — серия ограничена временем.
  final int? shotCount;

  /// Сколько времени отведено. `null` — серия ограничена выстрелами.
  final Duration? timeLimit;

  /// Идёт ли в зачёт: в сумму, средние и статистику.
  final bool counts;

  const SeriesSpec({
    required this.name,
    this.shotCount,
    this.timeLimit,
    this.counts = true,
  });

  /// Готовые названия — их предлагают списком, но писать можно любое.
  static const List<String> suggestedNames = [
    'Пристрелка',
    'Лёжа',
    'С колена',
    'Стоя',
    'Зачётная',
    'Финал',
  ];

  /// Серия ограничена временем, а не числом выстрелов.
  bool get isTimed => shotCount == null && timeLimit != null;

  /// Подпись для списков: «Лёжа · 10 выстрелов» / «Пристрелка · 15 мин».
  String get label {
    final limit = shotCount != null
        ? '$shotCount ${_shotsWord(shotCount!)}'
        : timeLimit != null
            ? '${timeLimit!.inMinutes} мин'
            : 'без границы';
    return counts ? '$name · $limit' : '$name · $limit · без зачёта';
  }

  static String _shotsWord(int n) {
    final n100 = n % 100;
    if (n100 >= 11 && n100 <= 14) return 'выстрелов';
    return switch (n % 10) {
      1 => 'выстрел',
      2 || 3 || 4 => 'выстрела',
      _ => 'выстрелов',
    };
  }

  SeriesSpec copyWith({
    String? name,
    int? shotCount,
    Duration? timeLimit,
    bool? counts,
    bool clearShotCount = false,
    bool clearTimeLimit = false,
  }) {
    return SeriesSpec(
      name: name ?? this.name,
      // Явные флаги очистки, потому что `null` в copyWith означает «не
      // менять»: без них нельзя было бы переключить серию с выстрелов
      // на время.
      shotCount: clearShotCount ? null : (shotCount ?? this.shotCount),
      timeLimit: clearTimeLimit ? null : (timeLimit ?? this.timeLimit),
      counts: counts ?? this.counts,
    );
  }

  factory SeriesSpec.fromJson(Map<String, dynamic> json) => SeriesSpec(
        name: '${json['name'] ?? 'Серия'}',
        shotCount: (json['shot_count'] as num?)?.toInt(),
        timeLimit: json['time_limit_s'] == null
            ? null
            : Duration(seconds: (json['time_limit_s'] as num).toInt()),
        counts: json['counts'] != false && json['counts'] != 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'shot_count': shotCount,
        'time_limit_s': timeLimit?.inSeconds,
        'counts': counts,
      };

  @override
  bool operator ==(Object other) =>
      other is SeriesSpec &&
      other.name == name &&
      other.shotCount == shotCount &&
      other.timeLimit == timeLimit &&
      other.counts == counts;

  @override
  int get hashCode => Object.hash(name, shotCount, timeLimit, counts);
}

/// Разбор списка серий: из JSON-строки базы или из уже готового списка.
///
/// Битую строку считаем отсутствием серий — упражнение тогда работает
/// по старому правилу «столько-то выстрелов по столько-то в серии».
/// Ронять из-за неё открытие тренировки нельзя.
List<SeriesSpec> seriesFromJson(Object? value) {
  if (value == null) return const [];
  Object? decoded = value;
  if (value is String) {
    if (value.trim().isEmpty) return const [];
    try {
      decoded = jsonDecode(value);
    } catch (_) {
      return const [];
    }
  }
  if (decoded is! List) return const [];
  final out = <SeriesSpec>[];
  for (final e in decoded) {
    if (e is Map) out.add(SeriesSpec.fromJson(e.map((k, v) => MapEntry('$k', v))));
  }
  return out;
}

String seriesToJson(List<SeriesSpec> series) =>
    jsonEncode([for (final s in series) s.toJson()]);
