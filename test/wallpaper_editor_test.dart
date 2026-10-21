import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/screens/wallpaper_editor_screen.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/theme/backdrop_tint.dart';

void main() {
  testWidgets('редактор обоев: тап ставит фигуру, «назад» убирает, «сохранить» запоминает', (tester) async {
    final db = LocalDbService();
    await tester.runAsync(() => db.open(overridePath: ':memory:'));
    BackdropTint.shapes = [];
    await tester.pumpWidget(MaterialApp(home: WallpaperEditorScreen(db: db)));
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    expect(BackdropTint.shapes.length, 1);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pump();
    expect(BackdropTint.shapes, isEmpty);
    await tester.tapAt(const Offset(100, 200));
    await tester.pump();
    await tester.tap(find.byTooltip('Сохранить'));
    await tester.pumpAndSettle();
    expect(BackdropTint.shapes.length, 1);
    BackdropTint.shapes = [];
  });
}
