enum CommentLevel { shot, series, session }

enum AuthorRole { athlete, coach }

/// Запись в ленте комментариев (часть C.3 logic-personalization-spec.md).
/// Лента, а не перезаписываемое поле: каждая запись — неизменяемая строка
/// с автором и временем.
class Comment {
  final String id;
  final String sessionId;
  final CommentLevel level;
  final String? shotId; // заполнено только при level == shot
  final int? seriesNo; // заполнено только при level == series
  final AuthorRole authorRole;
  final String text;
  final DateTime createdAt;

  const Comment({
    required this.id,
    required this.sessionId,
    required this.level,
    this.shotId,
    this.seriesNo,
    required this.authorRole,
    required this.text,
    required this.createdAt,
  }) : assert(
          (level == CommentLevel.shot && shotId != null && seriesNo == null) ||
              (level == CommentLevel.series &&
                  seriesNo != null &&
                  shotId == null) ||
              (level == CommentLevel.session &&
                  shotId == null &&
                  seriesNo == null),
          'ровно одно из (shotId, seriesNo) заполнено в зависимости от level',
        );

  Comment copyWith({
    String? id,
    String? sessionId,
    CommentLevel? level,
    String? shotId,
    int? seriesNo,
    AuthorRole? authorRole,
    String? text,
    DateTime? createdAt,
  }) {
    return Comment(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      level: level ?? this.level,
      shotId: shotId ?? this.shotId,
      seriesNo: seriesNo ?? this.seriesNo,
      authorRole: authorRole ?? this.authorRole,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory Comment.fromJson(Map<String, dynamic> json) => Comment(
        id: json['id'] as String,
        sessionId: json['session_id'] as String,
        level: CommentLevel.values.firstWhere((l) => l.name == json['level']),
        shotId: json['shot_id'] as String?,
        seriesNo: json['series_no'] as int?,
        authorRole:
            AuthorRole.values.firstWhere((r) => r.name == json['author_role']),
        text: json['text'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'session_id': sessionId,
        'level': level.name,
        'shot_id': shotId,
        'series_no': seriesNo,
        'author_role': authorRole.name,
        'text': text,
        'created_at': createdAt.toIso8601String(),
      };

  /// Подпись строки в ленте — "Спортсмен:" / "Тренер:" (раздел 7 ТЗ).
  String get authorLabel =>
      authorRole == AuthorRole.athlete ? 'Спортсмен' : 'Тренер';
}
