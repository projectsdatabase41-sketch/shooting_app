import 'dart:convert';

import '../models/coach_note.dart';
import 'local_db_service.dart';

/// Дневник тренера — CRUD над `coach_notes`, тот же простой паттерн,
/// что и `CommentsRepository`.
class CoachNotesRepository {
  final LocalDbService db;
  CoachNotesRepository(this.db);

  List<CoachNote> list() {
    final rows = db.db.select('SELECT * FROM coach_notes ORDER BY created_at DESC');
    return rows.map(CoachNote.fromRow).toList();
  }

  void add(CoachNote note) {
    db.db.execute(
      'INSERT INTO coach_notes (id, topic, content, chart_json, created_at) VALUES (?, ?, ?, ?, ?)',
      [
        note.id,
        note.topic,
        note.content,
        note.chart == null ? null : jsonEncode(note.chart),
        note.createdAt.toIso8601String(),
      ],
    );
  }

  void delete(String id) {
    db.db.execute('DELETE FROM coach_notes WHERE id = ?', [id]);
  }
}
