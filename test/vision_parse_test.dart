import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/local_ai/local_vision.dart';

void main() {
  test('точки пробоин из ответа модели', () {
    expect(parseHolePoints('Вот: [{"x": 100, "y": 200}, {"x": 300.5, "y": 50}]', 896).length, 2);
    // Рамки Qwen — берётся центр; точка вне снимка отбрасывается.
    final boxes = parseHolePoints('[{"bbox_2d":[10,20,30,40]},{"bbox_2d":[900,900,950,950]}]', 896);
    expect(boxes.single.dx, 20);
    expect(boxes.single.dy, 30);
    // Не JSON — пары чисел; дубликаты рядом сливаются.
    expect(parseHolePoints('holes at 100,100 and 101,101 and 500, 400', 896).length, 2);
    expect(parseHolePoints('[]', 896), isEmpty);
  });
}
