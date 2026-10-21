import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/theme/backdrop_tint.dart';
import 'package:shooting_app/theme/wallpaper.dart';

Future<ByteData> _render(WidgetTester tester, String kind, {Brightness b = Brightness.dark}) async {
  final key = GlobalKey();
  await tester.binding.setSurfaceSize(const Size(400, 800));
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: b),
    home: RepaintBoundary(key: key, child: SizedBox.expand(child: Wallpaper(kind: kind))),
  ));
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  return (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
}

(int, int, int) _px(ByteData d, int x, int y) {
  final i = (y * 400 + x) * 4;
  return (d.getUint8(i), d.getUint8(i + 1), d.getUint8(i + 2));
}

void main() {
  setUp(() async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    BackdropTint.mode = 'off';
    BackdropTint.blur = 0;
    BackdropTint.mask = 0.55;
    BackdropTint.recompute();
  });

  testWidgets('обои без маски — чёрно-белая картинка', (tester) async {
    final (r, g, b) = _px(await _render(tester, 'home'), 200, 700);
    expect((r - b).abs(), lessThan(4));
    expect((r - g).abs(), lessThan(4));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('маска красит обои, прозрачность 100% — без цвета', (tester) async {
    BackdropTint.mode = 'manual';
    BackdropTint.hue = 0;
    BackdropTint.sat = 1.0;
    BackdropTint.mask = 1.0;
    BackdropTint.recompute();
    final (r, _, b) = _px(await _render(tester, 'settings'), 200, 700);
    expect(r, greaterThan(b + 5));
    BackdropTint.mask = 0.0;
    BackdropTint.recompute();
    final (r2, _, b2) = _px(await _render(tester, 'settings'), 200, 700);
    expect((r2 - b2).abs(), lessThan(4));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('тёмная тема — тёмные обои', (tester) async {
    expect(_px(await _render(tester, 'home'), 200, 700).$1, lessThan(80));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('светлая тема — светлые обои', (tester) async {
    expect(_px(await _render(tester, 'home', b: Brightness.light), 200, 700).$1, greaterThan(150));
    await tester.binding.setSurfaceSize(null);
  });
}
