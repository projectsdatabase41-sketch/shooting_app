import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/theme/wallpaper.dart';
import 'package:shooting_app/widgets/app_backdrop.dart';
import 'package:shooting_app/widgets/tile_backdrop.dart';

void main() {
  testWidgets('фон ИИ: картинка видна сквозь прозрачный Scaffold раздела',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF101010)),
      home: TileBackdropPage(
        icon: Icons.auto_awesome_outlined,
        child: AppBackdrop(
            kind: 'ai', child: const Scaffold(body: Center(child: Text('x')))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Wallpaper), findsWidgets);
  });
}
