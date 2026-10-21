import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/workspace_page.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/workspace_view_model.dart';

void main() {
  test('мишень всегда первая: по умолчанию, при перестановке и в старых сохранённых настройках', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final vm = WorkspaceViewModel(db);
    expect(vm.order.first, WorkspacePage.target);
    // сами страницы двигаются ниже мишени
    final before = vm.order;
    vm.move(3, 1); // на место 1 — сразу под мишенью
    expect(vm.order.first, WorkspacePage.target);
    expect(vm.order[1], before[3]);
    // выше мишени нельзя: перенос на позицию 0 уходит под мишень
    vm.move(2, 0);
    expect(vm.order.first, WorkspacePage.target);
    // саму мишень не двигаем
    final snapshot = vm.order;
    vm.move(0, 3);
    expect(vm.order, snapshot);
    // старая раскладка (статистика слева от мишени) при чтении исправляется
    db.db.execute("INSERT OR REPLACE INTO color_prefs (key, hex) VALUES ('workspace_order', 'statistics,target,assistant')");
    expect(WorkspaceViewModel(db).order.first, WorkspacePage.target);
  });
}
