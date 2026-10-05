/// Одна сводка куска разговора с ассистентом — не сырая переписка, а
/// компактный пересказ: когда это было, о каких тренировках шла речь
/// (может быть ни о каких), и в чём была суть (`AiMemoryService`,
/// пункт 10 списка правок).
class AiMemorySummary {
  final String? id;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String summary;
  final List<String> trainingPackageIds;

  /// Полный текст обмена (вопрос и ответ целиком) — «развёрнутая» память,
  /// нужна, когда надо вспомнить подробности, которых уже нет в чате.
  /// `null` — в краткой выборке или если колонки в базе ещё нет.
  final String? detail;

  const AiMemorySummary({
    this.id,
    required this.periodStart,
    required this.periodEnd,
    required this.summary,
    this.trainingPackageIds = const [],
    this.detail,
  });

  factory AiMemorySummary.fromJson(Map<String, dynamic> json) =>
      AiMemorySummary(
        id: json['id'] as String?,
        periodStart: DateTime.parse(json['period_start'] as String),
        periodEnd: DateTime.parse(json['period_end'] as String),
        summary: json['summary'] as String? ?? '',
        trainingPackageIds: (json['training_package_ids'] as List?)
                ?.map((e) => '$e')
                .toList() ??
            const [],
        detail: json['detail'] as String?,
      );

  Map<String, dynamic> toJson({bool withDetail = true}) => {
        'period_start': periodStart.toIso8601String(),
        'period_end': periodEnd.toIso8601String(),
        'summary': summary,
        'training_package_ids': trainingPackageIds,
        if (withDetail && detail != null) 'detail': detail,
      };
}
