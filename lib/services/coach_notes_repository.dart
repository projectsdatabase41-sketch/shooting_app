import 'dart:convert';
import 'dart:typed_data';

import '../models/coach_note.dart';
import 'local_db_service.dart';

/// Дневник тренера — CRUD над `coach_notes`, тот же простой паттерн,
/// что и `CommentsRepository`.
class CoachNotesRepository {
  final LocalDbService db;
  CoachNotesRepository(this.db);

  List<CoachNote> list() {
    final rows =
        db.db.select('SELECT * FROM coach_notes ORDER BY created_at DESC');
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
    db.db.execute('DELETE FROM coach_note_files WHERE note_id = ?', [id]);
    db.db.execute('DELETE FROM coach_notes WHERE id = ?', [id]);
  }

  /// Файлы заметки (PDF, Word, TXT, изображения) — хранятся прямо в
  /// локальной базе. Список без самих байтов, байты — отдельно по требованию.
  List<CoachNoteFile> files(String noteId) {
    final rows = db.db.select(
        'SELECT id, name, mime, size FROM coach_note_files WHERE note_id = ? ORDER BY created_at',
        [noteId]);
    return [
      for (final r in rows)
        CoachNoteFile(
            id: r['id'] as String,
            name: r['name'] as String,
            mime: r['mime'] as String?,
            size: r['size'] as int),
    ];
  }

  void addFile(
      String noteId, String id, String name, String? mime, Uint8List bytes) {
    db.db.execute(
      'INSERT INTO coach_note_files (id, note_id, name, mime, size, data) VALUES (?, ?, ?, ?, ?, ?)',
      [id, noteId, name, mime, bytes.length, bytes],
    );
  }

  Uint8List? fileBytes(String id) {
    final rows =
        db.db.select('SELECT data FROM coach_note_files WHERE id = ?', [id]);
    return rows.isEmpty
        ? null
        : Uint8List.fromList(rows.first['data'] as List<int>);
  }

  void deleteFile(String id) =>
      db.db.execute('DELETE FROM coach_note_files WHERE id = ?', [id]);

  /// Правка темы/текста — заметка не заблокирована на редактирование
  /// (в отличие от завершённой тренировки спортсмена).
  void update(String id, {required String topic, required String content}) {
    db.db.execute(
      'UPDATE coach_notes SET topic = ?, content = ? WHERE id = ?',
      [topic, content, id],
    );
  }
}
