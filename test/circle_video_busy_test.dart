import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/circle_video.dart';

void main() {
  testWidgets('кружок: при передаче показывает значок передачи вместо «играть», после — снова «играть»', (tester) async {
    Widget app(bool busy) => MaterialApp(
          home: Scaffold(body: Center(child: CircleVideo(durationSec: 5, load: () async => null, busy: busy, progress: busy ? 0.4 : null))),
        );
    await tester.pumpWidget(app(false));
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);

    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byIcon(Icons.cloud_sync_outlined), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsNothing);

    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // анимации остановлены вместе с виджетом
  });
}
