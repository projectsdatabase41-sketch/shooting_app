import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/ai_context.dart';

void main() {
  test('системный промпт ассистента — на английском (кроме маркера «ПОДРОБНО»)', () {
    final text = AiContext.systemPrompt(coachMode: true).replaceAll('ПОДРОБНО', '');
    final cyrillic = RegExp(r'[А-Яа-яЁё]').allMatches(text).length;
    expect(cyrillic, lessThan(40), reason: 'остались русские фразы в промпте');
    expect(text, contains('language the user writes in'));
  });
}
