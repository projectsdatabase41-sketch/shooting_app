import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/voice/voice_control.dart';
import 'package:shooting_app/voice/voice_grammar.dart';

void main() {
  test('экраны регистрируют команды; действует верхний экран; после закрытия команда снова недоступна', () async {
    final vc = VoiceControl.instance;
    final home = Object(), training = Object();
    const pause = VoiceIntent(VoiceAction.trainingPause);
    expect(await vc.execute(pause), isNot('Пауза'));
    expect(vc.canDo(VoiceAction.trainingPause), isFalse);

    vc.register(home, {VoiceAction.trainingPause: (_) => 'домашний'});
    vc.register(training, {VoiceAction.trainingPause: (_) => 'тренировка'});
    expect(await vc.execute(pause), 'тренировка'); // последний зарегистрированный — верхний экран
    vc.unregister(training);
    expect(await vc.execute(pause), 'домашний');
    vc.unregister(home);
    expect(vc.canDo(VoiceAction.trainingPause), isFalse);
  });

  test('обработчик без текста ответа — «Готово»', () async {
    final vc = VoiceControl.instance;
    final o = Object();
    vc.register(o, {VoiceAction.back: (_) => null});
    expect(await vc.execute(const VoiceIntent(VoiceAction.back)), isNotEmpty);
    vc.unregister(o);
  });
}
