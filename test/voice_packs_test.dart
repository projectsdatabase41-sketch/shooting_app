import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shooting_app/finals/announcer.dart';
import 'package:shooting_app/finals/voice_packs.dart';
import 'package:shooting_app/finals/voice_texts.dart';
import 'package:shooting_app/services/ai_settings.dart';
import 'package:shooting_app/services/local_db_service.dart';

void main() {
  test('«бот» не произносится; счёт собирается из записей чисел', () {
    expect(VoiceTexts.spokenName('Бывалый (Bot)'), 'Бывалый');
    expect(VoiceTexts.spokenName('Иван Иванов'), 'Иван Иванов');
    expect(VoiceTexts.numberRefs(105.3), ['num_100', 'num_005', 'num_comma', 'num_003']);
    expect(VoiceTexts.numberRefs(97.9), ['num_090', 'num_007', 'num_comma', 'num_009']);
    expect(VoiceTexts.numberRefs(112.0), ['num_100', 'num_012', 'num_comma', 'num_000']);
    expect(VoiceTexts.numberRefs(200.4), ['num_200', 'num_comma', 'num_004']);
    expect(VoiceTexts.numberRefs(0.5), ['num_000', 'num_comma', 'num_005']);
    expect(VoiceTexts.common('ru').length, 37);
    expect(VoiceTexts.namedIds().length, 9);
  });

  test('фраза рейтинга: именные записи + числа; в тексте нет слова «Bot»', () {
    final rows = [
      AnnounceRow('Бывалый (Bot)', 105.3, true),
      AnnounceRow('Рыцарь (Bot)', 104.1, true),
      AnnounceRow('Усталый (Bot)', 103.0, true),
      AnnounceRow('Я', 99.5, true, isMe: true),
    ];
    final refs = standingsRefs(rows)!;
    expect(refs.first, 'name:leads:Бывалый');
    expect(refs.contains('name:p2:Рыцарь'), isTrue);
    expect(refs.contains('name:p3:Усталый'), isTrue);
    expect(refs.contains('name:pl4:Я'), isTrue);
    expect(standingsSpeech(rows).contains('Bot'), isFalse);
    expect(standingsRefs(rows, lead: 'Внимание'), isNull); // произвольное вступление — только голосом телефона
  });

  test('записи имён: создаются по одному запросу на фразу, повторно не запрашиваются, удаляются при смене имени', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final dir = await Directory.systemTemp.createTemp('voice_test');
    addTearDown(() => dir.delete(recursive: true));
    VoicePacks.useRootForTest(dir);
    expect(VoicePacks.config(db).usable, isFalse); // без своего ключа ИИ озвучка моделью недоступна
    AiSettings(db).apiKey = 'k';
    AiSettings(db).apiBaseUrl = 'https://tts.example/v1/';
    VoicePacks.saveSettings(db, model: 'm', voice: 'v', urlOverride: '', enabled: true);
    expect(VoicePacks.config(db).url, 'https://tts.example/v1/audio/speech');
    expect(VoicePacks.config(db).usable, isTrue);
    var calls = 0;
    final texts = <String>[];
    http.Client factory() => MockClient((req) async {
          calls++;
          texts.add(req.body);
          expect(req.headers['Authorization'], 'Bearer k');
          return http.Response.bytes(List.filled(400, 7), 200);
        });
    final made = await VoicePacks.ensureNames(db, ['Иванов', 'Бывалый (Bot)'], clientFactory: factory);
    expect(made, 18); // 9 фраз на имя
    expect(calls, 18);
    expect(texts.any((t) => t.contains('Бот') || t.contains('Bot')), isFalse);
    calls = 0;
    expect(await VoicePacks.ensureNames(db, ['Иванов'], clientFactory: factory), 0);
    expect(calls, 0);
    expect(await VoicePacks.canPlay(db, ['name:leads:Иванов', 'name:pl4:Бывалый (Bot)']), isTrue);
    expect(await VoicePacks.canPlay(db, ['name:leads:Иванов', 'num_100']), isFalse); // общих записей ещё нет
    await VoicePacks.forgetName(db, 'Иванов');
    expect(await VoicePacks.canPlay(db, ['name:leads:Иванов']), isFalse);
    expect(await VoicePacks.canPlay(db, ['name:leads:Бывалый']), isTrue);
  });

  test('по одной записи: заново озвучивается только выбранная, остальные не трогаются', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final dir = await Directory.systemTemp.createTemp('voice_test2');
    addTearDown(() => dir.delete(recursive: true));
    VoicePacks.useRootForTest(dir);
    AiSettings(db).apiKey = 'k';
    AiSettings(db).apiBaseUrl = 'https://tts.example/v1';
    VoicePacks.saveSettings(db, model: 'm', voice: 'v', urlOverride: '', enabled: true);
    var calls = 0;
    http.Client factory() => MockClient((req) async {
          calls++;
          return http.Response.bytes(List.filled(400, calls), 200);
        });
    await VoicePacks.ensureNames(db, ['Иванов'], clientFactory: factory);
    expect(calls, 9);
    expect(VoicePacks.knownNames(db), ['Иванов']);
    final groups = VoicePacks.groups(db);
    expect(groups.first.$2.length, 37); // общие
    expect(groups.any((g) => g.$1 == 'Иванов' && g.$2.length == 9), isTrue);
    const ref = 'name:leads:Иванов';
    expect(await VoicePacks.clipExists(db, ref), isTrue);
    calls = 0;
    expect(await VoicePacks.regenerate(db, ref, 'Лидирует Иванов.', clientFactory: factory), isTrue);
    expect(calls, 1); // один запрос, а не девять
    await VoicePacks.deleteClip(db, ref);
    expect(await VoicePacks.clipExists(db, ref), isFalse);
    expect(await VoicePacks.clipExists(db, 'name:p2:Иванов'), isTrue);
  });
}
