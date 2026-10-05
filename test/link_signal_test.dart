import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/link_signal.dart';

void main() {
  test('уровни связи: прямая > живой канал > в сети > нет', () {
    expect(linkLevel(direct: true, live: true, online: true), 4);
    expect(linkLevel(direct: false, live: true, online: true), 3);
    expect(linkLevel(direct: false, live: false, online: true), 2);
    expect(linkLevel(direct: false, live: false, online: false), 0);
  });
}
