import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/circle_video.dart';
import 'package:shooting_app/widgets/voice_bubble.dart';

void main() {
  test('формат времени', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(9), '0:09');
    expect(formatClock(75), '1:15');
    expect(formatClock(3601), '60:01');
  });

  testWidgets('голосовое в пузыре: длительность, play, скорость переключается', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoicePlayerBar(durationSec: 42, fg: Colors.white, load: () async => null),
      ),
    ));
    expect(find.text('0:42'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.text('1×'), findsOneWidget);
    await tester.tap(find.text('1×'));
    await tester.pump();
    expect(find.text('1.5×'), findsOneWidget);
    await tester.tap(find.text('1.5×'));
    await tester.pump();
    expect(find.text('2×'), findsOneWidget);
    await tester.tap(find.text('2×'));
    await tester.pump();
    expect(find.text('1×'), findsOneWidget);
  });

  testWidgets('кружок до загрузки: круг с play и длительностью', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: CircleVideo(durationSec: 75, load: () async => null))),
    ));
    expect(find.text('1:15'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(tester.getSize(find.byType(CircleVideo)), const Size(200, 200));
  });
}
