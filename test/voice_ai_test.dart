import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/voice/voice_ai.dart';
import 'package:shooting_app/voice/voice_grammar.dart';

void main() {
  test('ответ ИИ-помощника: только действия из закрытого списка', () {
    expect(VoiceAi.parseReply('{"action":"open","target":"finals"}'), const VoiceIntent(VoiceAction.open, target: 'finals'));
    expect(VoiceAi.parseReply('Вот: {"action":"trainingPause"} готово'), const VoiceIntent(VoiceAction.trainingPause));
    expect(VoiceAi.parseReply('{"action":"addNote","text":"  рывок на спуске "}'), const VoiceIntent(VoiceAction.addNote, text: 'рывок на спуске'));
    // вне списка, чужой раздел, пустой вопрос, не JSON — отбрасываются
    expect(VoiceAi.parseReply('{"action":"deleteEverything"}'), isNull);
    expect(VoiceAi.parseReply('{"action":"open","target":"secret"}'), isNull);
    expect(VoiceAi.parseReply('{"action":"askAi","text":""}'), isNull);
    expect(VoiceAi.parseReply('{"action":"none"}'), isNull);
    expect(VoiceAi.parseReply('просто текст'), isNull);
  });
}
