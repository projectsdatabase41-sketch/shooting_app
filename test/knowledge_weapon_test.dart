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
}
