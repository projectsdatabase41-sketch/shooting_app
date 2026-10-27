import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/text_search.dart';

void main() {
  test('вопрос про само приложение — не запрос к книгам', () {
    for (final q in ['что можешь рассказать об этом приложении?', 'Что это за приложение', 'расскажи про Nexus', 'Что ты умеешь', 'кто ты?']) {
      expect(TextSearch.isSmallTalk(q), isTrue, reason: q);
    }
  });

  test('обычные вопросы про стрельбу идут в справочник', () {
    for (final q in ['как улучшить программу тренировок по пневматике', 'что такое приложение усилия при спуске', 'как стоять с винтовкой']) {
      expect(TextSearch.isSmallTalk(q), isFalse, reason: q);
    }
  });
}
