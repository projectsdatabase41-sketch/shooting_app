import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/theme/app_theme.dart';
import 'package:shooting_app/theme/glass.dart';
import 'package:shooting_app/widgets/glass_route.dart';

void main() {
  tearDown(() => GlassTheme.sync(false, 1.0));

  testWidgets('стекло: кнопки и окна размывают фон; без стекла — обычные', (tester) async {
    Widget app() => MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  FilledButton(onPressed: () {}, child: const Text('btn')),
                  TextButton(
                    onPressed: () => showGlassDialog<void>(context: ctx, builder: (_) => const AlertDialog(title: Text('dlg'))),
                    child: const Text('open'),
                  ),
                ]),
              ),
            ),
          ),
        );
    GlassTheme.sync(false, 1.0);
    await tester.pumpWidget(app());
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('dlg'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing); // без стекла окно обычное
    Navigator.of(tester.element(find.text('dlg'))).pop();
    await tester.pumpAndSettle();

    GlassTheme.sync(true, 1.0);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing); // кнопка стеклянная, но без размытия (не мигает при прокрутке)
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget); // размытие за окном
    expect(GlassTheme.windowAlpha, greaterThan(GlassTheme.buttonAlpha)); // окна плотнее кнопок
  });
}
