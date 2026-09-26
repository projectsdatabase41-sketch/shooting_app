import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/i18n/i18n.dart';

void main() {
  test('без словаря — русский текст с подстановками', () {
    expect(tr('Настройки'), 'Настройки');
    expect(tr('Не удалось скачать перевод: {e}', {'e': 'нет сети'}), 'Не удалось скачать перевод: нет сети');
  });
}
