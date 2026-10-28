import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/screen_buttons.dart';

void main() {
  test('список разделов веера: лишние и «Настройки» отбрасываются', () {
    expect(ScreenButtons.parseTabs('notes,settings,zzz,assistant'), ['notes', 'assistant']);
    expect(ScreenButtons.parseTabs(''), isEmpty);
  });

  test('недоступные разделы не попадают в видимые', () {
    ScreenButtons.tabs.value = ['notes', 'assistant'];
    ScreenButtons.suppressed = {'assistant'};
    expect(ScreenButtons.visibleTabs, ['notes']);
    ScreenButtons.suppressed = {};
  });
}
