import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/local_ai/local_ai.dart';
import 'package:shooting_app/local_ai/local_ai_memory.dart';
import 'package:shooting_app/services/ai_service.dart';
import 'package:shooting_app/services/ai_settings.dart';
import 'package:shooting_app/services/local_db_service.dart';

Future<AiSettings> _settings({String mode = 'tasks', bool dev = true}) async {
  final db = LocalDbService();
  await db.open(overridePath: ':memory:');
  final s = AiSettings(db)
    ..localMode = mode
    ..localModelId = 'qwen2.5-1.5b'
    ..apiKey = 'test-key';
  db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('dev_mode_enabled', ?)", [dev ? '1' : '0']);
  return s;
}

/// Облако: считает вызовы, отвечает [reply].
(AiService, List<int>) _service(AiSettings s, String reply) {
  final calls = <int>[0];
  final client = MockClient((req) async {
    calls[0]++;
    return http.Response(
      jsonEncode({
        'choices': [
          {'message': {'content': reply}},
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return (AiService(s, client: client), calls);
}

void main() {
  var localCalls = 0;
  String localReply = '{"ok": true}';
  setUp(() {
    localCalls = 0;
    LocalAi.debugGenerate = (r) async {
      localCalls++;
      return localReply;
    };
  });
  tearDown(() => LocalAi.debugGenerate = null);

  Future<AiReply> ask(AiService ai, {String? task, bool json = false, String q = 'создай заметку про хват'}) =>
      ai.ask(systemPrompt: 'sys', contextBlock: '', history: [(role: 'user', text: q)], task: task, json: json);

  test('лёгкая задача отвечается локально, облако не трогаем; повтор — из кэша', () async {
    final s = await _settings();
    final (ai, cloud) = _service(s, 'облако');
    final r = await ask(ai, task: 'note_create', json: true);
    expect(r.text, '{"ok": true}');
    expect(r.model, startsWith('локальная'));
    expect(cloud[0], 0);
    await ask(ai, task: 'note_create', json: true);
    expect(localCalls, 1); // второй раз — из памяти
  });

  test('локальный ответ не прошёл проверку (не JSON) → облако, и облачный ответ становится примером', () async {
    final s = await _settings();
    localReply = 'не json';
    final (ai, cloud) = _service(s, '{"from": "cloud"}');
    final r = await ask(ai, task: 'note_create', json: true);
    expect(r.text, '{"from": "cloud"}');
    expect(cloud[0], 1);
    final ex = LocalAiMemory(s.db).examples('note_create', 'заметку хват');
    expect(ex.single.output, '{"from": "cloud"}');
    localReply = '{"ok": true}';
  });

  test('тяжёлые задачи и чат в режиме tasks идут в облако; в режиме all — локально', () async {
    final s = await _settings();
    final (ai, cloud) = _service(s, 'облако');
    await ask(ai, task: 'chat');
    await ask(ai, task: 'service_parse', json: false);
    expect(localCalls, 0);
    expect(cloud[0], 2);

    s.localMode = 'all';
    localReply = 'локальный ответ';
    final r = await ask(ai, task: 'chat', q: 'как дела у стрелка');
    expect(r.text, 'локальный ответ');
    expect(cloud[0], 2);
    localReply = '{"ok": true}';
  });

  test('без режима разработчика или с выключенным режимом — только облако', () async {
    for (final s in [await _settings(dev: false), await _settings(mode: 'off')]) {
      final (ai, cloud) = _service(s, 'облако');
      await ask(ai, task: 'note_create', json: true);
      expect(cloud[0], 1);
    }
    expect(localCalls, 0);
  });

  test('сбой движка → облако', () async {
    final s = await _settings();
    LocalAi.debugGenerate = (r) async => throw Exception('нет памяти');
    final (ai, cloud) = _service(s, 'облако');
    expect((await ask(ai, task: 'table_describe')).text, 'облако');
    expect(cloud[0], 1);
  });

  test('память: лимит объёма вытесняет давно неиспользованное, поиск находит похожее', () async {
    final s = await _settings();
    final m = LocalAiMemory(s.db, maxChars: 3000);
    m.remember('example', 'note_create', 'тренировка хвата пистолета', 'A' * 500);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    m.remember('example', 'note_create', 'стойка винтовка лёжа', 'B' * 500);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(m.examples('note_create', 'как улучшить хват пистолета', limit: 1).single.output, 'A' * 500);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    // переполнение: вытесняется «стойка» — к ней дольше всего не обращались
    m.remember('example', 'note_create', 'дыхание перед выстрелом', 'C' * 1000);
    m.remember('cache', 'x', 'y' * 100, 'z' * 900);
    expect(m.usedChars, lessThanOrEqualTo(3000));
    final left = m.examples('note_create', '', limit: 10).map((e) => e.output[0]).toSet();
    expect(left.contains('B'), isFalse);
    expect(left.contains('A'), isTrue);
    // длинный пример обрезается
    m.remember('example', 't', 'q', 'x' * 5000);
    expect(m.examples('t', 'q').single.output.length, LocalAiMemory.exampleChars + 1);
  });
}
