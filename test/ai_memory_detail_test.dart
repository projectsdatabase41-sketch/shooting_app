import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/ai_memory_summary.dart';
import 'package:shooting_app/services/ai_memory_service.dart';

void main() {
  test('просьба вспомнить распознаётся, обычный вопрос — нет', () {
    expect(AiMemoryService.isRecallQuestion('Вспомни, что ты мне советовал по дыханию'), isTrue);
    expect(AiMemoryService.isRecallQuestion('в прошлый раз мы обсуждали упражнение'), isTrue);
    expect(AiMemoryService.isRecallQuestion('какой у меня средний результат?'), isFalse);
  });

  test('развёрнутая запись уходит в JSON только когда нужна', () {
    final s = AiMemorySummary(periodStart: DateTime(2026, 1, 1), periodEnd: DateTime(2026, 1, 1), summary: 'кратко', detail: 'полный текст');
    expect(s.toJson()['detail'], 'полный текст');
    expect(s.toJson(withDetail: false).containsKey('detail'), isFalse);
  });
}
