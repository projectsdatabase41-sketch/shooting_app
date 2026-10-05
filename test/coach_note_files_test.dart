import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/coach_note.dart';
import 'package:shooting_app/services/coach_notes_repository.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  test('файлы заметки: добавить, прочитать, удалить вместе с заметкой', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final repo = CoachNotesRepository(db);
    repo.add(CoachNote(id: 'n1', topic: 'т', content: 'с', createdAt: DateTime(2026, 1, 1)));
    repo.addFile('n1', 'f1', 'план.pdf', null, Uint8List.fromList([1, 2, 3]));

    final files = repo.files('n1');
    expect(files.single.name, 'план.pdf');
    expect(files.single.isPdf, isTrue);
    expect(files.single.size, 3);
    expect(repo.fileBytes('f1'), [1, 2, 3]);

    repo.delete('n1');
    expect(repo.files('n1'), isEmpty);
  });
}
