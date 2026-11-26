import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/ai_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('вопрос «что это за приложение» уходит в обзор Nexus, а не в книги', () async {
    expect(AiContext.isAppQuestion('Что это за приложение?'), isTrue);
    await AiContext.prepareAppGuide('Что это за приложение?');
    expect(AiContext.hasAppGuide, isTrue,
        reason: 'должен подставиться блок ИНСТРУКЦИИ ПРИЛОЖЕНИЯ');
    expect(AiContext.appGuideBlock ?? '', contains('Nexus'),
        reason: 'ответ строится по обзору приложения, а не по страницам книг');
  });

  test('обычный стрелковый вопрос не тянет инструкции приложения', () async {
    await AiContext.prepareAppGuide('Сравни мои серии за неделю');
    expect(AiContext.hasAppGuide, isFalse);
  });
}
