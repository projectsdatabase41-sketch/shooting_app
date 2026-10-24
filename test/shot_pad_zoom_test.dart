import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/screens/final_run_screen.dart';

void main() {
  pinchOutIn();
  testWidgets('мишень: один палец — выстрел; два пальца (щипок) — зум без выстрела; снова один — выстрел', (tester) async {
    final shots = <Offset>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ShotPad(face: TargetFace.rifle10m, marks: const [], enabled: true, onHold: (_) {}, onShot: shots.add),
          ),
        ),
      ),
    ));
    final c = tester.getCenter(find.byType(ShotPad));

    // Один палец: нажал и отпустил — выстрел.
    await tester.tapAt(c + const Offset(20, 20));
    await tester.pump();
    expect(shots.length, 1);

    // Щипок двумя пальцами: выстрела нет.
    final a = await tester.startGesture(c + const Offset(-30, 0));
    final b = await tester.startGesture(c + const Offset(30, 0));
    await a.moveTo(c + const Offset(-80, 0));
    await b.moveTo(c + const Offset(80, 0));
    await a.up();
    await b.up();
    await tester.pump();
    expect(shots.length, 1);

    // Один палец после зума и отпускания всех — снова обычный выстрел.
    await tester.tapAt(c + const Offset(10, 10));
    await tester.pump();
    expect(shots.length, 2);

    // Отпустили один из двух пальцев — второй не делает выстрел.
    final p = await tester.startGesture(c + const Offset(-30, 0));
    final q = await tester.startGesture(c + const Offset(30, 0));
    await p.up();
    await q.up();
    await tester.pump();
    expect(shots.length, 2);

    // На телефоне зум только щипком: ползунок есть лишь в веб-версии.
    expect(find.byType(Slider), findsNothing);
  });
}

void pinchOutIn() {
  testWidgets('зум щипком: увеличить и обратно уменьшить до целой мишени', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ShotPad(face: TargetFace.rifle10m, marks: const [], enabled: true, onHold: (_) {}, onShot: (_) {}),
          ),
        ),
      ),
    ));
    final c = tester.getCenter(find.byType(ShotPad));
    double scale() => (tester.state(find.byType(ShotPad)) as dynamic).debugScale as double;
    expect(scale(), 1);
    var a = await tester.startGesture(c + const Offset(-30, 0));
    var b = await tester.startGesture(c + const Offset(30, 0));
    await a.moveTo(c + const Offset(-90, 0));
    await b.moveTo(c + const Offset(90, 0));
    await a.up();
    await b.up();
    await tester.pump();
    expect(scale(), greaterThan(2));
    // обратно: пальцы сводятся
    a = await tester.startGesture(c + const Offset(-90, 0));
    b = await tester.startGesture(c + const Offset(90, 0));
    await a.moveTo(c + const Offset(-10, 0));
    await b.moveTo(c + const Offset(10, 0));
    await a.up();
    await b.up();
    await tester.pump();
    expect(scale(), 1); // мишень снова целиком
  });
}
