import '../models/comment.dart';
import 'local_db_service.dart';

/// Единая точка доступа к комментариям на всех трёх уровнях (часть C.3
/// логики-спека) — один провайдер вместо трёх разных источников данных.
class CommentsRepository {
  final LocalDbService db;

  CommentsRepository(this.db);

  List<Comment> forShot(String sessionId, String shotId) {
    final rows = db.db.select(
      'SELECT * FROM comments WHERE session_id = ? AND level = ? AND shot_id = ? ORDER BY created_at',
      [sessionId, 'shot', shotId],
    );
    return rows.map(_fromRow).toList();
  }

  List<Comment> forSeries(String sessionId, int seriesNo) {
    final rows = db.db.select(
      'SELECT * FROM comments WHERE session_id = ? AND level = ? AND series_no = ? ORDER BY created_at',
      [sessionId, 'series', seriesNo],
    );
    return rows.map(_fromRow).toList();
  }

  List<Comment> forSession(String sessionId) {
    final rows = db.db.select(
      'SELECT * FROM comments WHERE session_id = ? AND level = ? ORDER BY created_at',
      [sessionId, 'session'],
    );
    return rows.map(_fromRow).toList();
  }

  Comment add(Comment comment) {
    db.db.execute(
      'INSERT INTO comments (id, session_id, level, shot_id, series_no, author_role, text, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        comment.id,
        comment.sessionId,
        comment.level.name,
        comment.shotId,
        comment.seriesNo,
        comment.authorRole.name,
        comment.text,
        comment.createdAt.toIso8601String(),
      ],
    );
    return comment;
  }

  Comment _fromRow(Map<String, dynamic> row) => Comment(
        id: row['id'] as String,
        sessionId: row['session_id'] as String,
        level: CommentLevel.values.firstWhere((l) => l.name == row['level']),
        shotId: row['shot_id'] as String?,
        seriesNo: row['series_no'] as int?,
        authorRole:
            AuthorRole.values.firstWhere((r) => r.name == row['author_role']),
        text: row['text'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );
}
