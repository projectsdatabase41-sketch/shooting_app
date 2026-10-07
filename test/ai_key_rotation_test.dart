import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/ai_service.dart';

void main() {
  setUp(AiService.resetKeyState);

  test('режим мышления: ключи идут по кругу', () {
    final firsts = [
      for (var i = 0; i < 4; i++) AiService.orderKeys(['a', 'b', 'c'], rotate: true).first
    ];
    expect(firsts, ['a', 'b', 'c', 'a']);
  });

  test('без rotate порядок прежний', () {
    expect(AiService.orderKeys(['a', 'b'], rotate: false), ['a', 'b']);
    expect(AiService.orderKeys(['a', 'b'], rotate: false), ['a', 'b']);
  });

  test('ключ с лимитом уходит в конец на минуту', () {
    AiService.markLimited('a');
    expect(AiService.orderKeys(['a', 'b', 'c'], rotate: false), ['b', 'c', 'a']);
    AiService.markLimited('b');
    expect(AiService.orderKeys(['a', 'b', 'c'], rotate: false), ['c', 'a', 'b']);
  });

  test('один ключ — без изменений', () {
    expect(AiService.orderKeys(['a'], rotate: true), ['a']);
  });

  test('модель с лимитом остывает, остальные пробуются первыми', () {
    AiService.markModelLimited('k', 'm1');
    expect(AiService.orderModels('k', ['m1', 'm2', 'm3']), ['m2', 'm3', 'm1']);
    expect(AiService.orderModels('other', ['m1', 'm2']), ['m1', 'm2']);
  });
}
