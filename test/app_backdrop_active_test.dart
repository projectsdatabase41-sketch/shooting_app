import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/app_backdrop.dart';

void main() {
  testWidgets('активный фон — у верхнего экрана; при закрытии возвращается прежний', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => AppBackdrop(
          kind: 'home',
          child: TextButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => const AppBackdrop(kind: 'champions', child: SizedBox()))),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(AppBackdrop.active.value, 'home');
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(AppBackdrop.active.value, 'champions');
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pop();
    await tester.pumpAndSettle();
    expect(AppBackdrop.active.value, 'home');
  });
}
