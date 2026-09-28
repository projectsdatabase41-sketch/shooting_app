import 'dart:convert';
import 'dart:typed_data';

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

  Future<AiReply> ask(AiService ai,
          {String? task, bool json = false, String q = 'создай заметку про хват', Uint8List? image}) =>
      ai.ask(systemPrompt: 'sys', contextBlock: '', history: [(role: 'user', text: q)], task: task, json: json, image: image);

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

  test('выключенный режим — только облако; режим разработчика больше не нужен', () async {
    final off = await _settings(mode: 'off');
    final (ai, cloud) = _service(off, 'облако');
    await ask(ai, task: 'note_create', json: true);
    expect(cloud[0], 1);
    expect(localCalls, 0);

    final noDev = await _settings(dev: false);
    final (ai2, cloud2) = _service(noDev, 'облако');
    await ask(ai2, task: 'note_create', json: true);
    expect(localCalls, 1);
    expect(cloud2[0], 0);
  });

  test('сбой движка → облако', () async {
    final s = await _settings();
    LocalAi.debugGenerate = (r) async => throw Exception('нет памяти');
    final (ai, cloud) = _service(s, 'облако');
    expect((await ask(ai, task: 'table_describe')).text, 'облако');
    expect(cloud[0], 1);
  });

  test('ручной выбор модели чата: конкретная облачная — без перебора остальных', () async {
    final s = await _settings(mode: 'off'); // облако сразу, локальную не подмешивать
    // Отвечает успехом только на ПОСЛЕДНЮЮ модель цепочки — остальные 500.
    final requestedModels = <String>[];
    final client = MockClient((req) async {
      final model = (jsonDecode(req.body) as Map)['model'] as String;
      requestedModels.add(model);
      if (model != s.models.last) return http.Response('{"error":{"message":"нет"}}', 500);
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': {'content': 'ответ'}},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final ai = AiService(s, client: client);

    // auto — перебирает всю цепочку по очереди, пока не дойдёт до рабочей.
    final r = await ask(ai, task: 'chat');
    expect(requestedModels, s.models);
    expect(r.text, 'ответ');

    // Конкретная модель, которая как раз отвечает 500, — падает СРАЗУ, а не
    // пробует остальные (в отличие от auto выше).
    requestedModels.clear();
    s.chatModelChoice = s.models.first;
    await expectLater(ask(ai, task: 'chat'), throwsA(anything));
    expect(requestedModels, [s.models.first]);
  });

  test('ручной выбор модели чата: «локальная» — мимо localMode, вне chat не влияет', () async {
    final s = await _settings(mode: 'off'); // облако — обычный режим для всех остальных задач
    s.chatModelChoice = 'local';
    localReply = 'локальный ответ';
    final (ai, cloud) = _service(s, 'облако');
    // чат — форсирован на локальную, несмотря на localMode == off
    expect((await ask(ai, task: 'chat')).text, 'локальный ответ');
    expect(cloud[0], 0);
    // другая задача — chatModelChoice тут ни при чём, идёт в облако как обычно
    expect((await ask(ai, task: 'note_create', json: true)).text, 'облако');
    localReply = '{"ok": true}';
  });

  test('фото к вопросу: локальная модель без зрения — молча игнорирует картинку, не падает', () async {
    final s = await _settings(); // qwen2.5-1.5b — без projector, sees == false
    s.chatModelChoice = 'local';
    LocalAi.debugGenerate = (r) async {
      localCalls++;
      expect(r.image, isNull); // не умеет — и не должна получить
      return localReply;
    };
    final (ai, _) = _service(s, 'облако');
    final r = await ask(ai, task: 'chat', image: Uint8List.fromList([1, 2, 3]));
    expect(r.text, '{"ok": true}');
  });

  test('фото к вопросу: локальная модель со зрением — получает картинку, кэш не используется', () async {
    final s = await _settings();
    s.localModelId = 'qwen2.5-vl-3b'; // с projector — sees == true
    s.chatModelChoice = 'local';
    var seenImages = 0;
    LocalAi.debugGenerate = (r) async {
      localCalls++;
      if (r.image != null) seenImages++;
      return 'на фото мишень';
    };
    final ai = AiService(s, client: MockClient((_) async => http.Response('', 500)));
    final img1 = Uint8List.fromList([1, 2, 3]);
    final img2 = Uint8List.fromList([4, 5, 6]);
    expect((await ask(ai, task: 'chat', q: 'что на фото', image: img1)).text, 'на фото мишень');
    expect((await ask(ai, task: 'chat', q: 'что на фото', image: img2)).text, 'на фото мишень');
    expect(seenImages, 2); // оба раза дошло до движка — не подменено кэшем по тому же тексту
    expect(localCalls, 2);
  });

  test('фото к вопросу: облачная модель — уходит как image_url в последнем сообщении', () async {
    final s = await _settings(mode: 'off');
    s.chatModelChoice = 'qwen/vl-model:free';
    Map<String, dynamic>? sentBody;
    final client = MockClient((req) async {
      sentBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {'message': {'content': 'вижу фото'}},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final ai = AiService(s, client: client);
    final img = Uint8List.fromList([9, 9, 9]);
    final r = await ask(ai, task: 'chat', q: 'что на фото', image: img);
    expect(r.text, 'вижу фото');
    final messages = sentBody!['messages'] as List;
    final last = messages.last as Map<String, dynamic>;
    final content = last['content'] as List;
    expect(content.any((c) => c['type'] == 'image_url'), isTrue);
    expect('${content.firstWhere((c) => c['type'] == 'image_url')['image_url']['url']}',
        contains(base64Encode(img)));
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
