import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/services/ai_service.dart';
import 'package:shooting_app/services/ai_settings.dart';
import 'package:shooting_app/services/knowledge_service.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/supabase_auth_service.dart';

void main() {
  test('«что у меня в заметках?» — по словам пусто, ИИ получает последние заметки и знает о таблице', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final settings = AiSettings(db)
      ..tables = [const KnowledgeTableConfig(name: 'notes', label: 'Заметки', description: 'личные заметки')];
    // колонки уже определены (без похода к ИИ)
    for (final (t, cols) in [
      ('notes', ['id', 'topic', 'content', 'created_at']),
      ('shooting_rules', ['content']),
      ('books', ['content']),
    ]) {
      db.db.execute(
        'INSERT INTO ai_knowledge_columns (table_name, content_column, all_columns, discovered_at) VALUES (?, ?, ?, ?)',
        [t, 'content', jsonEncode(cols), DateTime.now().toIso8601String()],
      );
    }
    final requests = <Uri>[];
    final client = MockClient((req) async {
      requests.add(req.url);
      final isNotes = req.url.path.endsWith('/notes');
      final filtered = req.url.queryParameters.keys.any((k) => k == 'or' || k == 'content');
      if (isNotes && !filtered) {
        return http.Response(
          jsonEncode([
            {'id': 1, 'topic': 'Хват', 'content': 'Держать кисть мягче', 'created_at': '2026-09-20'},
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('[]', 200);
    });
    final auth = SupabaseAuthService(db)..setBase(url: 'https://x.supabase.co', anonKey: 'anon');
    final ks = KnowledgeService(settings, db: db, aiService: AiService(settings), personalAuth: auth, client: client);

    final chunks = await ks.search('что у меня в заметках?');
    expect(chunks.map((c) => c.text), ['Держать кисть мягче']);
    final latest = requests.firstWhere((u) => u.path.endsWith('/notes') && !u.queryParameters.containsKey('or'));
    expect(latest.queryParameters['order'], 'created_at.desc');

    final block = KnowledgeService.asPromptBlock(chunks, tables: settings.tables)!;
    expect(block, contains('Подключённые таблицы пользователя'));
    expect(block, contains('Заметки: личные заметки'));
    expect(block, contains('Держать кисть мягче'));

    // таблица подключена, но в этот раз ничего — ИИ всё равно о ней знает
    final empty = KnowledgeService.asPromptBlock(const [], tables: settings.tables)!;
    expect(empty, contains('Заметки'));
  });
}
