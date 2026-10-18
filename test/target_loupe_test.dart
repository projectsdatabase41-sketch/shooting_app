import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/models/training_session.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';
import 'package:shooting_app/state/personalization_view_model.dart';
import 'package:shooting_app/state/target_view_model.dart';
import 'package:shooting_app/widgets/target_canvas.dart';

void main() {
  testWidgets('лупа при перетаскивании пробоины: над пальцем, у верхнего края — сбоку, не вниз', (tester) async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..isAthlete = true;
    const ex = Exercise(id: 'e', name: 'T', targetFaceCode: 'rifle_10m', totalShots: 10, seriesSize: 10);
    final vm = TargetViewModel(
      store: store,
      session: const TrainingSession(id: 's', exerciseId: 'e', targetFaceCode: 'rifle_10m'),
      exercise: ex,
      face: TargetFace.rifle10m,
    );
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<TargetViewModel>.value(value: vm),
        ChangeNotifierProvider(create: (_) => PersonalizationViewModel(db)..loadFromDb()),
      ],
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 400, height: 400, child: TargetCanvas()))),
    ));
    vm.beginAddNew();
    await tester.pump();
    expect(vm.isEditing, true);

    Finder loupe() => find.byWidgetPredicate((w) => w is ClipOval);
    expect(loupe(), findsNothing);

    // палец в нижней части: лупа выше пальца
    final g = await tester.startGesture(const Offset(200, 330) + tester.getTopLeft(find.byType(TargetCanvas)));
    await tester.pump();
    await g.moveBy(const Offset(5, 0));
    await tester.pump();
    expect(loupe(), findsOneWidget);
    final top1 = tester.getTopLeft(loupe()).dy - tester.getTopLeft(find.byType(TargetCanvas)).dy;
    expect(top1 + 140, lessThan(330)); // лупа целиком над пальцем

    // палец у верхнего края: лупа не уходит вниз — стоит сбоку на высоте пальца
    await g.moveTo(const Offset(200, 40) + tester.getTopLeft(find.byType(TargetCanvas)));
    await tester.pump();
    final r = tester.getRect(loupe());
    final base = tester.getTopLeft(find.byType(TargetCanvas));
    final fingerY = 40.0 + base.dy;
    expect(r.center.dy, lessThanOrEqualTo(fingerY + 75)); // не ниже пальца больше чем на полразмера лупы
    expect(r.left >= base.dx && r.right <= base.dx + 400, true);

    await g.up();
    await tester.pump();
    expect(loupe(), findsNothing);

    await tester.pumpWidget(const SizedBox());
    vm.dispose(); // останавливает секундомер тренировки
  });
}
