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
    expect(text.length, lessThan(6200), reason: 'промпт разросся — токены на каждый запрос');
    for (final k in ['```chart', '```exercise', '```feedback', '```note', '---ANSWER---', 'exercises_on_device', 'rifle_10m', 'pistol_25m', 'ПОДРОБНО']) {
      expect(text, contains(k), reason: k);
    }
  });

  test('у каждого режима свои правила; общая база не меняется', () {
    final speed = AiContext.systemPrompt(profile: AiProfile.speed);
    final quality = AiContext.systemPrompt(profile: AiProfile.quality);
    final thinking = AiContext.systemPrompt(profile: AiProfile.thinking);
    expect(speed, contains('MODE: SPEED'));
    expect(quality, contains('MODE: QUALITY'));
    expect(thinking, contains('MODE: THINKING'));
    for (final t in [speed, quality, thinking]) {
      expect(t, contains(AiContext.defaultBasePrompt));
      expect('MODE:'.allMatches(t).length, 1);
    }
    expect(thinking, contains('HELPER WORKING NOTES'));
    expect(speed.length, lessThan(quality.length));
    expect(AiContext.systemPrompt(), contains('MODE: QUALITY')); // по умолчанию
  });
}
