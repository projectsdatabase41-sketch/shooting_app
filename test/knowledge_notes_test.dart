import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/screens/knowledge_notes_screen.dart';

void main() {
  test('запрос списка: активные, свежие сверху, поиск по теме и описанию, фильтры', () {
    final q = KnowledgeNotesApi.listQuery(q: 'опора', source: 'airtable', tag: 'BS-Shooting', offset: 40);
    expect(q, contains('status=eq.active'));
    expect(q, contains('order=updated_at.desc'));
    expect(q, contains('limit=40'));
    expect(q, contains('offset=40'));
    expect(q, contains('or=(topic.ilike.'));
    expect(q, contains('source=eq.airtable'));
    expect(q, contains('tags=cs.'));
    // служебные символы PostgREST из поиска вырезаются
    expect(KnowledgeNotesApi.listQuery(q: 'а,б(в)*'), isNot(contains(',б')));
  });

  test('запись разбирается из строки таблицы notes', () {
    final n = KnowledgeNote.fromJson({
      'id': 'x',
      'topic': 'Тема',
      'summary': null,
      'tags': ['a', 'b'],
      'source': 'qwen',
      'updated_at': '2026-09-02T18:22:45.820251+00:00',
    });
    expect(n.topic, 'Тема');
    expect(n.tags, ['a', 'b']);
    expect(n.updatedAt, isNotNull);
  });
}
