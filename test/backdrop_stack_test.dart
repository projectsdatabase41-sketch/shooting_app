import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/theme/wallpaper.dart';
import 'package:shooting_app/widgets/app_backdrop.dart';
import 'package:shooting_app/widgets/tile_backdrop.dart';

void main() {
  testWidgets('фон ИИ: картинка видна сквозь прозрачный Scaffold раздела', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: const Color(0xFF101010)),
      home: RepaintBoundary(
        key: key,
        child: TileBackdropPage(
          icon: Icons.auto_awesome_outlined,
          child: AppBackdrop(kind: 'ai', child: const Scaffold(body: Center(child: Text('x')))),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Wallpaper), findsWidgets); // обои рисуются слоями, не картинкой
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    final image = await tester.runAsync(() => boundary.toImage());
    final data = (await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    // верхний центр (там свечение фона ИИ) заметно синее нижнего угла
    int px(int x, int y) {
      final i = (y * image!.width + x) * 4;
      return data.getUint8(i + 2); // blue
    }
    final top = px(image!.width ~/ 2, 120);
    final corner = px(5, image.height - 5);
    expect(top, greaterThan(corner));
  });
}
