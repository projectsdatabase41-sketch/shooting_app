// Генератор чёрно-белых обоев: flutter test tool/gen_wallpapers_test.dart
// Рисует слои из WallpaperPainter в серых тонах и кладёт в assets/wall/<вид>_<dark|light>[_b].jpg
// (_b — размытая копия; в приложении плавно подмешивается по ползунку размытия).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'gen_wallpapers_painter.dart';

Color g(double l) => HSLColor.fromAHSL(1, 0, 0, l).toColor();

Future<void> render(String kind, bool dark, bool blurred) async {
  final w = blurred ? 270 : 720, h = blurred ? 540 : 1440;
  final style = WallpaperStyle(
    front: g(dark ? 0.07 : 0.96),
    backDark: g(dark ? 0.30 : 0.70),
    backGlow: g(dark ? 0.62 : 0.45),
    frontOpacity: 1,
    vignette: dark ? 0.4 : 0.25,
    blur: blurred ? 9 : 0,
  );
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  WallpaperPainter(kind, style, dark ? Brightness.dark : Brightness.light).paint(canvas, Size(w.toDouble(), h.toDouble()));
  final image = await rec.endRecording().toImage(w, h);
  final bd = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final gray = img.Image(width: w, height: h);
  for (var i = 0; i < w * h; i++) {
    final v = bd.getUint8(i * 4);
    gray.setPixelRgb(i % w, i ~/ w, v, v, v);
  }
  File('assets/wall/${kind}_${dark ? 'dark' : 'light'}${blurred ? '_b' : ''}.jpg').writeAsBytesSync(img.encodeJpg(gray, quality: blurred ? 80 : 86));
}

void main() {
  test('генерация обоев', () async {
    // Шрифт значков для прорезей-значков (в тесте по умолчанию рисуются квадраты).
    final bytes = File('C:/tools/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf').readAsBytesSync();
    final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    await Future(() async {
      for (final k in ['home', 'settings', 'ai', 'messenger', 'champions', 'finals', 'exercises', 'statistics', 'tasks', 'athletes', 'notes', 'drive']) {
        for (final d in [true, false]) {
          for (final b in [false, true]) {
            await render(k, d, b);
          }
        }
      }
    });
  });
}
