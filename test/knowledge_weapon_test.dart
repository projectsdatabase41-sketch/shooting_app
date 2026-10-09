import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/knowledge_service.dart';

void main() {
  test('вопрос про пистолет отбрасывает куски про винтовку', () {
    const q = 'Расскажи про прицеливание с пистолета';
    expect(KnowledgeService.weaponMismatch(q, 'Прицеливание из винтовки: приклад в плечо'), isTrue);
    expect(KnowledgeService.weaponMismatch(q, 'Прицеливание из пистолета на вытянутой руке'), isFalse);
    expect(KnowledgeService.weaponMismatch(q, 'Общие правила безопасности'), isFalse);
    expect(KnowledgeService.weaponMismatch(q, 'Пистолет и винтовка: сравнение'), isFalse);
  });

  test('вопрос про винтовку отбрасывает куски про пистолет; без оружия — ничего', () {
    expect(KnowledgeService.weaponMismatch('как держать винтовку', 'хват пистолета'), isTrue);
    expect(KnowledgeService.weaponMismatch('как целиться', 'хват пистолета'), isFalse);
    expect(KnowledgeService.weaponMismatch('пистолет или винтовка', 'хват пистолета'), isFalse);
  });

  test('дополнительные термины от модели: основа 6 букв, от 3 символов, не больше 8, без дублей', () {
    final base = ['прицел', 'пистол'];
    final w = KnowledgeService.withExtraTerms(base, ['ISSF', 'прицеливание', 'ab', '10м', 'два слова', 'ПИСТОЛЕТ', 'a', 'х', 'мишень', 'винтовка', 'стойка', 'дыхание', 'спуск']);
    expect(w.take(2), base);
    expect(w, containsAll(['issf', 'мишень']));
    expect(w.where((e) => e == 'пистол').length, 1);
    expect(w.length, lessThanOrEqualTo(8));
    expect(w.any((e) => e.contains(' ') || e.length < 3), isFalse);
  });

  test('поиск: короткие значимые слова не теряются, синонимы добавляются', () {
    expect(KnowledgeService.keywords('Какие правила ISSF для 10м пневматики'), containsAll(['issf', '10м']));
    expect(KnowledgeService.keywords('как правильно делать вдох перед выстрелом'), contains('вдох'));
    expect(KnowledgeService.keywords('Привет как дела'), isNot(contains('как')));
    final w = KnowledgeService.withSynonyms(['прицел', 'пистол']);
    expect(w, containsAll(['прицел', 'пистол', 'мушка', 'диопт']));
    expect(KnowledgeService.withSynonyms(KnowledgeService.keywords('прицеливание дыхание спуск стойка кучность волнение')).length, lessThanOrEqualTo(10));
  });
}
