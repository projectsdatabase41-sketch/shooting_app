import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/ai_context.dart';

void main() {
  test('системный промпт ассистента — на английском (кроме маркера «ПОДРОБНО»)', () {
    final text = AiContext.systemPrompt(coachMode: true).replaceAll('ПОДРОБНО', '');
    final cyrillic = RegExp(r'[А-Яа-яЁё]').allMatches(text).length;
    expect(cyrillic, lessThan(40), reason: 'остались русские фразы в промпте');
    expect(text, contains('language the user writes in'));
  });

  test('промпт компактен и содержит все форматы блоков', () {
    final text = AiContext.systemPrompt(coachMode: true);
    expect(text.length, lessThan(5600), reason: 'промпт разросся — токены на каждый запрос');
    for (final k in ['```chart', '```exercise', '```feedback', '```note', '---ANSWER---', 'exercises_on_device', 'rifle_10m', 'pistol_25m', 'ПОДРОБНО']) {
      expect(text, contains(k), reason: k);
    }
  });
}
