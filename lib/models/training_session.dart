import 'dart:convert';

import 'shot.dart';

/// Разбор поля `extra`: из базы приходит строкой JSON, из импорта —
/// готовой картой. Битую строку считаем отсутствием данных — терять
/// из-за справочного поля целую тренировку недопустимо.
Map<String, dynamic>? extraFromJson(Object? v) {
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

enum SessionStatus { notStarted, running, paused, finished }

/// Интервал паузы (часть B.1/B.2 logic-personalization-spec.md).
class PauseInterval {
  final DateTime pausedAt;
  final DateTime? resumedAt;

  const PauseInterval({required this.pausedAt, this.resumedAt});

  PauseInterval copyWith({DateTime? pausedAt, DateTime? resumedAt}) {
    return PauseInterval(
      pausedAt: pausedAt ?? this.pausedAt,
      resumedAt: resumedAt ?? this.resumedAt,
    );
  }

  factory PauseInterval.fromJson(Map<String, dynamic> json) => PauseInterval(
        pausedAt: DateTime.parse(json['paused_at'] as String),
        resumedAt: json['resumed_at'] == null
            ? null
            : DateTime.parse(json['resumed_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'paused_at': pausedAt.toIso8601String(),
        'resumed_at': resumedAt?.toIso8601String(),
      };
}

/// Тренировка — не список выстрелов, а процесс с явным состоянием
/// (раздел 6 ТЗ, часть B logic-personalization-spec.md).
class TrainingSession {
  final String id;
  final String exerciseId;
  final String targetFaceCode;
  final SessionStatus status;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final List<PauseInterval> pauseIntervals;
  final List<Shot> shots; // активные, видимые
  final List<Shot> trash; // удалённые в текущей тренировке (B.5)
  final bool syncedToCloud;

  /// Показатели тренировки, для которых нет своих колонок.
  ///
  /// Из отчёта SCATT сюда уезжают средняя скорость и раздельно по
  /// горизонтали и вертикали, стабильность и точность прицеливания,
  /// чистое время прицеливания, стабильность темпа, баллистический
  /// коэффициент и контрольный интервал. Плюс пометка, откуда взялись
  /// данные, — чтобы потом было видно, что тренировка не набита
  /// руками, а импортирована.
  final Map<String, dynamic>? extra;

  const TrainingSession({
    required this.id,
    required this.exerciseId,
    required this.targetFaceCode,
    this.status = SessionStatus.notStarted,
    this.startedAt,
    this.finishedAt,
    this.pauseIntervals = const [],
    this.shots = const [],
    this.trash = const [],
    this.syncedToCloud = false,
    this.extra,
  });

  TrainingSession copyWith({
    String? id,
    String? exerciseId,
    String? targetFaceCode,
    SessionStatus? status,
    DateTime? startedAt,
    DateTime? finishedAt,
    List<PauseInterval>? pauseIntervals,
    List<Shot>? shots,
    List<Shot>? trash,
    bool? syncedToCloud,
    Map<String, dynamic>? extra,
  }) {
    return TrainingSession(
      id: id ?? this.id,
      exerciseId: exerciseId ?? this.exerciseId,
      targetFaceCode: targetFaceCode ?? this.targetFaceCode,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      pauseIntervals: pauseIntervals ?? this.pauseIntervals,
      shots: shots ?? this.shots,
      trash: trash ?? this.trash,
      syncedToCloud: syncedToCloud ?? this.syncedToCloud,
      extra: extra ?? this.extra,
    );
  }

  factory TrainingSession.fromJson(Map<String, dynamic> json) {
    return TrainingSession(
      id: json['id'] as String,
      exerciseId: json['exercise_id'] as String,
      targetFaceCode: json['target_face_code'] as String,
      status: SessionStatus.values.firstWhere(
        (s) => s.name == (json['status'] as String? ?? 'notStarted'),
        orElse: () => SessionStatus.notStarted,
      ),
      startedAt: json['started_at'] == null
          ? null
          : DateTime.parse(json['started_at'] as String),
      finishedAt: json['finished_at'] == null
          ? null
          : DateTime.parse(json['finished_at'] as String),
      pauseIntervals: (json['pause_intervals'] as List<dynamic>? ?? [])
          .map((e) => PauseInterval.fromJson(e as Map<String, dynamic>))
          .toList(),
      shots: (json['shots'] as List<dynamic>? ?? [])
          .map((e) => Shot.fromJson(e as Map<String, dynamic>))
          .toList(),
      trash: (json['trash'] as List<dynamic>? ?? [])
          .map((e) => Shot.fromJson(e as Map<String, dynamic>))
          .toList(),
      syncedToCloud: json['synced_to_cloud'] == true ||
          json['synced_to_cloud'] == 1,
      extra: extraFromJson(json['extra']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'exercise_id': exerciseId,
        'target_face_code': targetFaceCode,
        'status': status.name,
        'started_at': startedAt?.toIso8601String(),
        'finished_at': finishedAt?.toIso8601String(),
        'pause_intervals': pauseIntervals.map((e) => e.toJson()).toList(),
        'shots': shots.map((e) => e.toJson()).toList(),
        'trash': trash.map((e) => e.toJson()).toList(),
        'synced_to_cloud': syncedToCloud,
        'extra': extra,
      };

  /// Выстрелы, идущие в зачёт. Пристрелка сюда не попадает.
  List<Shot> get countingShots => [for (final s in shots) if (s.counts) s];

  /// Сумма ЗАЧЁТНЫХ выстрелов.
  ///
  /// Пристрелка в сумму не входит — решение пользователя. Она остаётся
  /// в `shots`, видна на мишени и доступна ассистенту, но результатом
  /// тренировки не является.
  double get totalScore {
    var sum = 0.0;
    for (final s in shots) {
      if (s.counts) sum += s.score;
    }
    return sum;
  }
}
