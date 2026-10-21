import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/screens/final_run_screen.dart';

void main() {
  testWidgets('лупа финала: в верхнем слое, всегда над пальцем, не прыгает вниз у верха', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    Offset? shot;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(top: 300),
          child: SizedBox(
            width: 400,
            height: 400,
            child: ShotPad(face: TargetFace.rifle10m, marks: const [], enabled: true, onHold: (_) {}, onShot: (p) => shot = p),
          ),
        ),
      ),
    ));
    Finder loupe() => find.byWidgetPredicate((w) => w is ClipOval);
    expect(loupe(), findsNothing);
    final g = await tester.startGesture(const Offset(200, 600));
    await tester.pump();
    await tester.pump();
    expect(loupe(), findsOneWidget);
    expect(tester.getRect(loupe()).bottom, lessThan(600)); // над пальцем
    // палец у самой верхней границы площадки: лупа остаётся над ним, не уходит под палец
    await g.moveTo(const Offset(200, 330));
    await tester.pump();
    await tester.pump();
    final r = tester.getRect(loupe());
    expect(r.top, lessThan(330));
    expect(r.top, greaterThanOrEqualTo(0));
    await g.up();
    await tester.pump();
    await tester.pump();
    expect(loupe(), findsNothing);
    expect(shot, isNotNull);
  });
}
