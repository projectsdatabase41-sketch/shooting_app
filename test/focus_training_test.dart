import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/models/training_session.dart';
import 'package:shooting_app/screens/focus_training_screen.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';
import 'package:shooting_app/state/target_view_model.dart';

void main() {
  testWidgets('режим концентрации: выстрел касанием по мишени записывается, «Отменить» убирает', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..isAthlete = true;
    const ex = Exercise(id: 'e', name: 'T', targetFaceCode: 'rifle_10m', totalShots: 10, seriesSize: 10);
    final vm = TargetViewModel(
      store: store,
      session: const TrainingSession(id: 's', exerciseId: 'e', targetFaceCode: 'rifle_10m'),
      exercise: ex,
      face: TargetFace.rifle10m,
    )..start();
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider<AppDataStore>.value(value: store), ChangeNotifierProvider<TargetViewModel>.value(value: vm)],
      child: const MaterialApp(home: FocusTrainingScreen()),
    ));
    expect(vm.session.shots, isEmpty);
    final pad = find.byType(ClipOval);
    await tester.tapAt(tester.getCenter(pad) + const Offset(30, -20));
    await tester.pump();
    expect(vm.session.shots.length, 1);
    expect(find.text('Отменить выстрел'), findsOneWidget);
    await tester.tap(find.text('Отменить выстрел'));
    await tester.pump();
    expect(vm.session.shots, isEmpty);
    await tester.pumpWidget(const SizedBox());
    vm.dispose(); // останавливает секундомер тренировки
  });
}
