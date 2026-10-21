import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/ai_service.dart';

void main() {
  test('```json со спецификацией графика превращается в график, обычный ```json остаётся текстом', () {
    const raw = 'Вот график.\n```json\n{"type":"bar","title":"T","x":["a","b"],"series":[{"name":"s","values":[1,2]}]}\n```';
    final (text, chart) = AiService.splitChart(raw);
    expect(chart, isNotNull);
    expect(chart!['type'], 'bar');
    expect(text, 'Вот график.');
    const plain = 'Ответ:\n```json\n{"name":"Иван","score":10}\n```';
    final (t2, c2) = AiService.splitChart(plain);
    expect(c2, isNull);
    expect(t2, plain);
    final (t3, c3) = AiService.splitChart('x ```chart\n{"type":"line","series":[]}\n``` y');
    expect(c3, isNotNull);
    expect(t3.contains('chart'), isFalse);
  });
}
