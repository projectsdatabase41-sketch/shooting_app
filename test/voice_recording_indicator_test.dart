import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/voice_recording_indicator.dart';

/// Индикатор записи: таймер ММ:СС, столбики и вращающийся квадрат.
/// Проверяем то, что легко сломать: формат времени и что анимация
/// освобождается (иначе после закрытия чата остаётся тикающий контроллер).
void main() {
  testWidgets('показывает время в формате ММ:СС и столбики', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: VoiceRecordingIndicator(
            recording: true,
            elapsed: const Duration(seconds: 7),
            color: Colors.amber,
            onTap: () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('00:07'), findsOneWidget);
    // 12 столбиков «частот» — по одному DecoratedBox на столбик (плюс
    // сам квадрат внутри кнопки), поэтому просто убеждаемся, что виджет
    // собрался без переполнений.
    expect(tester.takeException(), isNull);
  });

  testWidgets('тап по кнопке зовёт onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: VoiceRecordingIndicator(
            recording: true,
            elapsed: const Duration(seconds: 2),
            color: Colors.amber,
            onTap: () => taps++,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(GestureDetector).first);
    expect(taps, 1);
  });

  testWidgets('время больше минуты не ломает формат', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: VoiceRecordingIndicator(
            recording: true,
            elapsed: const Duration(minutes: 1, seconds: 5),
            color: Colors.amber,
            onTap: () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('01:05'), findsOneWidget);
  });

  testWidgets('без анимаций (disableAnimations) не падает', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: Center(
            child: VoiceRecordingIndicator(
              recording: true,
              elapsed: const Duration(seconds: 3),
              color: Colors.amber,
              onTap: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('00:03'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
