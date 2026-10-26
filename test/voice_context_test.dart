import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/voice/clock_shot.dart';
import 'package:shooting_app/voice/voice_grammar.dart';

void main() {
  VoiceIntent? t(String s) => VoiceGrammar.parse(s, mode: VoiceMode.training);
  VoiceIntent? c(String s) => VoiceGrammar.parse(s, mode: VoiceMode.chat);

  test('тренировка: «десять пять на 5 часов» — выстрел, остальное — заметка', () {
    final i = t('Десять пять на 5 часов. Дернул пальцем и вроде ноги не правильно стоят')!;
    expect(i.action, VoiceAction.placeShot);
    expect(i.score, 10.5);
    expect(i.hour, 5);
    expect(i.text, 'Дернул пальцем и вроде ноги не правильно стоят');
    expect(t('10 5 на пять часов')!.score, 10.5);
    expect(t('девять на три часа')!, const VoiceIntent(VoiceAction.placeShot, score: 9.0, hour: 3));
    expect(t('десять девять на двенадцать часов')!.hour, 12);
    // в другом режиме та же фраза — не выстрел
    expect(VoiceGrammar.parse('Десять пять на 5 часов', mode: VoiceMode.chat)?.action, isNot(VoiceAction.placeShot));
    expect(VoiceGrammar.parse('Десять пять на 5 часов')?.action, isNot(VoiceAction.placeShot));
    // без направления выстрел не ставим (не угадываем)
    expect(t('десять пять'), isNull);
  });

  test('геометрия: точка по результату и часам даёт именно названный результат и нужное направление', () {
    for (final face in [TargetFace.rifle10m, TargetFace.pistol10m]) {
      for (final score in [9.0, 9.5, 10.0, 10.3, 10.5, 10.8]) {
        for (final hour in [12.0, 3.0, 5.0, 7.0, 10.0]) {
          final (x, y) = pointForScore(face, score, hour);
          expect(scoreForPoint(x, y, face), closeTo(score, 0.051), reason: '${face.code} $score ${hour}ч');
        }
      }
    }
    final (x, y) = pointForScore(TargetFace.rifle10m, 9.0, 3);
    expect(x, greaterThan(0));
    expect(y.abs(), lessThan(1e-6), reason: '3 часа — строго вправо');
    final (x6, y6) = pointForScore(TargetFace.rifle10m, 9.0, 6);
    expect(x6.abs(), lessThan(1e-6));
    expect(y6, lessThan(0), reason: '6 часов — вниз');
    final (x5, y5) = pointForScore(TargetFace.rifle10m, 9.0, 5);
    expect(x5, greaterThan(0));
    expect(y5, lessThan(0), reason: '5 часов — вправо-вниз');
    expect(pointForScore(TargetFace.rifle10m, 10.9, 5), (0.0, 0.0)); // выше достижимого — в центр
  });

  test('переписка: поиск по основам слов и фильтр «фото»', () {
    final i = c('найди фото с долгами')!;
    expect(i.action, VoiceAction.chatSearch);
    expect(i.query, 'долг');
    expect(i.filter, 'photo');
    expect(c('Найди картинки про долги')!.query, 'долг');
    expect(c('покажи голосовые про тренировку')!.filter, 'audio');
    expect(c('поищи файлы договор')!.filter, 'file');
    expect(c('найди видео с соревнований')!.query, 'соревнован');
    expect(VoiceGrammar.searchStem('долгами'), 'долг');
    expect(VoiceGrammar.searchStem('долги'), 'долг');
    expect(VoiceGrammar.searchStem('долгов'), 'долг');
    expect(VoiceGrammar.searchStem('мишень'), 'мишен');
    // вне переписки «найди фото» поиском по чату не считается
    expect(VoiceGrammar.parse('найди фото с долгами', mode: VoiceMode.training)?.action, isNot(VoiceAction.chatSearch));
  });

  test('на любой странице: интернет, заметки, создание упражнения', () {
    for (final mode in [null, VoiceMode.training, VoiceMode.chat]) {
      expect(VoiceGrammar.parse('Найди в интернете как держать приклад', mode: mode), const VoiceIntent(VoiceAction.webSearch, query: 'как держать приклад'));
      expect(VoiceGrammar.parse('посмотри в интернете расписание соревнований', mode: mode)!.query, 'расписание соревнований');
      expect(VoiceGrammar.parse('Запиши в заметки купить мишени', mode: mode), const VoiceIntent(VoiceAction.addDiaryNote, text: 'купить мишени'));
      final ex = VoiceGrammar.parse('создай упражнение пневматика 40 выстрелов', mode: mode)!;
      expect(ex.action, VoiceAction.createExercise);
      expect(ex.shots, 40);
      expect(ex.face, 'rifle_10m');
    }
    expect(VoiceGrammar.parse('создай тренировку пистолет 60 выстрелов')!.face, 'pistol_10m');
    // заметка к выстрелу и запись в дневник — разные вещи
    expect(VoiceGrammar.parse('заметка рывок', mode: VoiceMode.training)!.action, VoiceAction.addNote);
  });
}
