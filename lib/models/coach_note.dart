import 'dart:convert';

/// Заметка в дневнике тренера (раздел 8 ТЗ) — тема + дата + текст, с
/// необязательным графиком/таблицей тем же форматом, что и в чате с
/// ассистентом (см. `AiChartView`), чтобы не заводить отдельный
/// markdown-рендерер ради одной этой заметки.
class CoachNote {
  final String id;
  final String topic;
  final String content;
  final Map<String, dynamic>? chart;
  final DateTime createdAt;

  const CoachNote({
    required this.id,
    required this.topic,
    required this.content,
    this.chart,
    required this.createdAt,
  });

  factory CoachNote.fromRow(Map<String, dynamic> row) => CoachNote(
        id: row['id'] as String,
        topic: row['topic'] as String,
        content: row['content'] as String,
        chart: row['chart_json'] == null ? null : jsonDecode(row['chart_json'] as String) as Map<String, dynamic>,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}
