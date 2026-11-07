import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/shot_photo_detection.dart';

/// Масштаб калибровки по печатным кольцам.
///
/// Реальная причина «алгоритм работал ужасно»: контур калибровки означает
/// радиус БЛАНКА (у № 8 — 40 мм), а человек на фото обводит печатную
/// мишень по внешнему кольцу (22.75 мм). Ошибка масштаба — 1.76 раза.
/// Старое окно поиска 0.6…1.6 такой промах не покрывало, поэтому калибр
/// пробоины оставался неверным, и детектор принимал за попадания цифры
/// габаритов.
void main() {
  /// Синтетическая мишень № 8: кольца 10..1 с официальными радиусами,
  /// [pxPerMm] пикселей на миллиметр, бланк — светлее фона.
  GrayImage target({
    required double pxPerMm,
    int side = 600,
    List<double> ringRadiiMm = const [
      0.25, 2.75, 5.25, 7.75, 10.25, 12.75, 15.25, 17.75, 20.25, 22.75,
    ],
  }) {
    final img = GrayImage.filled(side, side, 90); // стол/фон — темнее бумаги
    final c = side / 2;
    final paperR = 40 * pxPerMm; // бланк 80 мм
    img.fillCircle(c, c, paperR, 210); // бумага
    for (final r in ringRadiiMm) {
      img.fillRing(c, c, r * pxPerMm, math.max(1.5, 0.35 * pxPerMm), 40);
    }
    img.fillCircle(c, c, 15.25 * pxPerMm, 40); // чёрное яблоко (№ 8)
    return img;
  }

  test('масштаб восстанавливается, когда контур обведён по кольцу, а не по бланку', () {
    const pxPerMm = 6.0; // бланк 80 мм = 480 px
    final img = target(pxPerMm: pxPerMm);
    const trueFaceRadiusPx = 40 * pxPerMm; // 240
    // Пользователь обвёл внешнее печатное кольцо (22.75 мм) — в 1.76 раза меньше.
    const initial = 22.75 * pxPerMm;

    final refined = refineRadiusByRings(
      image: img,
      center: const PixelPoint(300, 300),
      initialRadiusPx: initial,
      ringRadiiMm: const [
        0.25, 2.75, 5.25, 7.75, 10.25, 12.75, 15.25, 17.75, 20.25, 22.75,
      ],
      faceRadiusMm: 40,
    );

    expect((refined - trueFaceRadiusPx).abs() / trueFaceRadiusPx, lessThan(0.05),
        reason: 'ожидали ~$trueFaceRadiusPx px, получили $refined');
  });

  test('верный контур не сбивается', () {
    const pxPerMm = 6.0;
    final img = target(pxPerMm: pxPerMm);
    final refined = refineRadiusByRings(
      image: img,
      center: const PixelPoint(300, 300),
      initialRadiusPx: 40 * pxPerMm,
      ringRadiiMm: const [
        0.25, 2.75, 5.25, 7.75, 10.25, 12.75, 15.25, 17.75, 20.25, 22.75,
      ],
      faceRadiusMm: 40,
    );
    expect((refined - 240).abs() / 240, lessThan(0.05));
  });

  test('без колец на фото масштаб остаётся исходным', () {
    // Ровное поле: подгонять не по чему — нельзя уезжать в случайный пик.
    final img = GrayImage.filled(400, 400, 200);
    final refined = refineRadiusByRings(
      image: img,
      center: const PixelPoint(200, 200),
      initialRadiusPx: 150,
      ringRadiiMm: const [
        0.25, 2.75, 5.25, 7.75, 10.25, 12.75, 15.25, 17.75, 20.25, 22.75,
      ],
      faceRadiusMm: 40,
    );
    expect(refined, 150);
  });

  group('оценка шума', () {
    test('ровное поле — ноль', () {
      expect(estimateNoise(GrayImage.filled(200, 200, 128)), 0);
    });

    test('зерно даёт заметный шум', () {
      final img = GrayImage(200, 200, Uint8List(200 * 200));
      final rnd = math.Random(1);
      for (var i = 0; i < img.pixels.length; i++) {
        img.pixels[i] = (120 + rnd.nextInt(40) - 20).clamp(0, 255);
      }
      expect(estimateNoise(img), greaterThan(3));
    });
  });
}
