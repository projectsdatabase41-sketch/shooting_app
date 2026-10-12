import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/demo_mode.dart';

void main() {
  testWidgets('режим «Демо»: кнопка видна только при включении и называет страницу', (tester) async {
    final key = GlobalKey<NavigatorState>();
    DemoMode.enabled.value = false;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      navigatorObservers: [DemoRouteObserver.instance],
      builder: (c, child) => DemoFeedbackOverlay(navigatorKey: key, child: child!),
      home: const _DemoScreen(),
    ));
    expect(find.text('Отзыв'), findsNothing);
    DemoMode.enabled.value = true;
    await tester.pump();
    expect(find.text('Отзыв'), findsOneWidget);
    expect(DemoMode.currentPage(), '_DemoScreen');
    DemoMode.enabled.value = false;
  });
}

class _DemoScreen extends StatelessWidget {
  const _DemoScreen();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('x'));
}
