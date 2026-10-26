import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/voice/voice_grammar.dart';

void main() {
  VoiceIntent? p(String s) => VoiceGrammar.parse(s);

  test('разделы: любой порядок слов, падежи и вежливость', () {
    const open = VoiceAction.open;
    expect(p('открой настройки'), const VoiceIntent(open, target: 'settings'));
    expect(p('Покажи мне пожалуйста статистику'), const VoiceIntent(open, target: 'statistics'));
    expect(p('финалы открой'), const VoiceIntent(open, target: 'finals'));
    expect(p('перейди в мессенджер'), const VoiceIntent(open, target: 'messenger'));
    expect(p('зайди в чат'), const VoiceIntent(open, target: 'messenger'));
    expect(p('Нексус, открой ассистента'), const VoiceIntent(open, target: 'assistant'));
    expect(p('google диск'), const VoiceIntent(open, target: 'drive'));
    expect(p('мои тренировки'), const VoiceIntent(open, target: 'exercises'));
  });

  test('тренировка: старт, пауза, продолжить, завершить, отмена выстрела', () {
    expect(p('начать тренировку'), const VoiceIntent(VoiceAction.trainingStart));
    expect(p('начни тренировку пожалуйста'), const VoiceIntent(VoiceAction.trainingStart));
    expect(p('старт'), const VoiceIntent(VoiceAction.trainingStart));
    expect(p('пауза'), const VoiceIntent(VoiceAction.trainingPause));
    expect(p('поставь на паузу'), const VoiceIntent(VoiceAction.trainingPause));
    expect(p('продолжить'), const VoiceIntent(VoiceAction.trainingResume));
    expect(p('заверши тренировку'), const VoiceIntent(VoiceAction.trainingFinish));
    expect(p('закончи'), const VoiceIntent(VoiceAction.trainingFinish));
    expect(p('отмени последний выстрел'), const VoiceIntent(VoiceAction.undoShot));
    expect(p('убери пробоину'), const VoiceIntent(VoiceAction.undoShot));
    expect(p('отмена'), const VoiceIntent(VoiceAction.undoShot));
  });

  test('режимы и финал', () {
    expect(p('режим концентрации'), const VoiceIntent(VoiceAction.focusMode));
    expect(p('чёрный экран'), const VoiceIntent(VoiceAction.focusMode));
    expect(p('готов'), const VoiceIntent(VoiceAction.finalReady));
    expect(p('я готов'), const VoiceIntent(VoiceAction.finalReady));
    expect(p('назад'), const VoiceIntent(VoiceAction.back));
  });

  test('заметка и вопрос ассистенту: текст сохраняется целиком', () {
    expect(p('заметка рывок на спуске'), const VoiceIntent(VoiceAction.addNote, text: 'рывок на спуске'));
    expect(p('запиши отвлёкся на шум'), const VoiceIntent(VoiceAction.addNote, text: 'отвлекся на шум'));
    expect(p('спроси как держать приклад'), const VoiceIntent(VoiceAction.askAi, text: 'как держать приклад'));
  });

  test('непонятное — null (дальше решает ИИ-помощник, если включён)', () {
    expect(p(''), isNull);
    expect(p('какая сегодня погода в москве'), isNull);
    expect(p('эээ ну'), isNull);
  });
}
