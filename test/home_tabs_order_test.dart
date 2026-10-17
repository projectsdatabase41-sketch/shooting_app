import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/home_tab_specs.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/home_tabs_view_model.dart';

void main() {
  test('единый набор вкладок: порядок задаётся списком и переживает перезапуск', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final vm = HomeTabsViewModel(db, mode: 'all', allIds: allTabIds, unhidable: unhidableTabs);
    expect(vm.order.first, 'exercises');
    vm.setOrder(['messenger', 'notes', 'exercises']);
    expect(vm.order.take(3), ['messenger', 'notes', 'exercises']);
    expect(vm.order.length, allTabIds.length); // остальные — следом
    final again = HomeTabsViewModel(db, mode: 'all', allIds: allTabIds, unhidable: unhidableTabs);
    expect(again.order.take(3), ['messenger', 'notes', 'exercises']);
  });

  test('первая загрузка наследует порядок прежних настроек спортсмена', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('home_tabs_visible_athlete', 'messenger,exercises,diary')");
    db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('home_tabs_hidden_athlete', '-')");
    final vm = HomeTabsViewModel(db, mode: 'all', allIds: allTabIds, unhidable: unhidableTabs);
    // 'diary' больше нет — отбрасывается, 'messenger' и 'exercises' остаются впереди.
    expect(vm.order.take(2), ['messenger', 'exercises']);
    expect(vm.order.contains('diary'), isFalse);
  });

  test('скрытая вкладка не теряется при смене порядка, «Настройки» скрыть нельзя', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final vm = HomeTabsViewModel(db, mode: 'all', allIds: allTabIds, unhidable: unhidableTabs);
    vm.hide('statistics');
    expect(vm.isHidden('statistics'), isTrue);
    vm.setOrder(['notes', 'messenger']);
    expect(vm.isHidden('statistics'), isTrue);
    vm.hide('settings');
    expect(vm.isHidden('settings'), isFalse);
  });

  test('перетаскивание при убранных по состоянию плитках двигает именно ту плитку', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final vm = HomeTabsViewModel(db, mode: 'all', allIds: allTabIds, unhidable: unhidableTabs);
    vm.setOrder(['exercises', 'statistics', 'tasks', 'notes', 'messenger']);
    vm.suppressed = {'statistics'}; // убрана (например, модуль выключен)
    expect(vm.visible.take(3), ['exercises', 'tasks', 'notes']);
    vm.move(2, 1); // «notes» выше «tasks»
    expect(vm.visible.take(3), ['exercises', 'notes', 'tasks']);
    vm.suppressed = {};
    expect(vm.visible.take(4), ['exercises', 'statistics', 'notes', 'tasks']);
  });
}
