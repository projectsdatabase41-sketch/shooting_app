import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/linked_text.dart';

void main() {
  test('ссылки находятся без хвостовой пунктуации, host без www', () {
    final l = MessageLinks.find('смотри https://example.com/path?a=1, и (www.test.ru/x).');
    expect(l.map((e) => e.url), ['https://example.com/path?a=1', 'www.test.ru/x']);
    expect(MessageLinks.hostOf('www.test.ru/x'), 'test.ru');
    expect(LinkedMessageText.hasLink('без ссылок'), false);
  });
}
