import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/theme/backdrop_tint.dart';
import 'package:shooting_app/theme/wallpaper.dart';

Future<ByteData> _render(WidgetTester tester, String kind) async {
  final key = GlobalKey();
  await tester.binding.setSurfaceSize(const Size(400, 800));
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: RepaintBoundary(key: key, child: SizedBox.expand(child: Wallpaper(kind: kind))),
  ));
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  return (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
}

int _lum(ByteData d, int x, int y) {
  final i = (y * 400 + x) * 4;
  return d.getUint8(i) + d.getUint8(i + 1) + d.getUint8(i + 2);
}

void main() {
  setUp(() async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    BackdropTint.mode = 'off';
    BackdropTint.frontOpacity = 1.0;
    BackdropTint.vignette = 0;
    BackdropTint.blur = 0;
    BackdropTint.eraseShape = 'none';
    BackdropTint.recompute();
  });

  testWidgets('обои: в прорези кольца виден цветной задний лист, на переднем листе — тёмный фон', (tester) async {
    final d = await _render(tester, 'home');
    // кольцо 1: радиус 0.14·ширины = 56 px от центра (200, 320)
    final slit = _lum(d, 256, 320);
    final paper = _lum(d, 280, 320);
    expect(slit, greaterThan(paper + 30));
  });

  testWidgets('стирание переднего листа: сторона «слева» открывает задний лист, у «нет» — нет', (tester) async {
    final before = _lum(await _render(tester, 'home'), 6, 700);
    BackdropTint.eraseShape = 'left';
    BackdropTint.eraseSoft = 0.3;
    BackdropTint.eraseStrength = 1.0;
    BackdropTint.eraseSize = 1.0;
    BackdropTint.recompute();
    final after = _lum(await _render(tester, 'home'), 6, 700);
    expect(after, greaterThan(before + 20));
    // дальний правый край не затронут
    expect(_lum(await _render(tester, 'home'), 395, 700), closeTo(before, 12));
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('оттенок: ручной режим меняет цвет обоев', (tester) async {
    BackdropTint.mode = 'manual';
    BackdropTint.hue = 0; // красный
    BackdropTint.sat = 1.0;
    BackdropTint.recompute();
    final d = await _render(tester, 'home');
    final i = (320 * 400 + 256) * 4; // в прорези
    expect(d.getUint8(i), greaterThan(d.getUint8(i + 2))); // красного больше, чем синего
    BackdropTint.mode = 'off';
    BackdropTint.recompute();
    await tester.binding.setSurfaceSize(null);
  });
}
