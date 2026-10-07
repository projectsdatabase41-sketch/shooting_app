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

  test('у каждого режима свой промпт', () {
    final fast = AiContext.systemPrompt(profile: AiProfile.fast);
    final normal = AiContext.systemPrompt(profile: AiProfile.normal);
    final think = AiContext.systemPrompt(profile: AiProfile.think);
    // Fast — простой короткий промпт, не общая база.
    expect(fast, contains('Answer fast and briefly'));
    expect(fast, isNot(contains(AiContext.defaultBasePrompt)));
    expect(fast.length, lessThan(3000));
    for (final k in ['```chart', '```exercise', '```feedback', 'rifle_10m', 'exercises_on_device']) {
      expect(fast, contains(k), reason: 'fast: $k');
    }
    // Normal и Think — общая база + свои правила (ровно одни).
    for (final t in [normal, think]) {
      expect(t, contains(AiContext.defaultBasePrompt));
      expect('MODE:'.allMatches(t).length, 1);
    }
    expect(normal, contains('MODE: NORMAL'));
    expect(think, contains('MODE: THINK'));
    expect(think, contains('HELPER WORKING NOTES'));
    expect(fast.length, lessThan(normal.length));
    expect(AiContext.systemPrompt(), contains('MODE: NORMAL')); // по умолчанию
    // Правка базы не трогает Fast.
    expect(AiContext.systemPrompt(profile: AiProfile.fast, baseOverride: 'X' * 50), isNot(contains('XXXXX')));
    expect(AiContext.systemPrompt(profile: AiProfile.normal, baseOverride: 'X' * 50), contains('XXXXX'));
  });
}
