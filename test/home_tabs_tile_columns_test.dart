// Зум плиток главного экрана (HomeTileGrid, щипок) — тут только
// не-визуальная часть: клампинг, сохранение и общий счёт между режимами
// спортсмен/тренер (сам жест — руками на устройстве).
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/home_tabs_view_model.dart';

void main() {
  test('по умолчанию 2, клампится к 2..5, сохраняется и переживает перезапуск', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final vm = HomeTabsViewModel(db, mode: 'athlete', allIds: ['target'], unhidable: {'target'});
    expect(vm.tileColumns, 2);

    vm.tileColumns = 4;
    expect(vm.tileColumns, 4);
    vm.tileColumns = 99; // клампится
    expect(vm.tileColumns, 5);
    vm.tileColumns = 0; // клампится
    expect(vm.tileColumns, 2);

    vm.tileColumns = 3;
    final reloaded = HomeTabsViewModel(db, mode: 'athlete', allIds: ['target'], unhidable: {'target'});
    expect(reloaded.tileColumns, 3);
  });

  test('общий счёт для обоих режимов (не привязан к mode)', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final athlete = HomeTabsViewModel(db, mode: 'athlete', allIds: ['target'], unhidable: {'target'});
    athlete.tileColumns = 5;
    final coach = HomeTabsViewModel(db, mode: 'coach', allIds: ['diary'], unhidable: {'diary'});
    expect(coach.tileColumns, 5);
  });
}
