// Детект пробоин по фото (лог. слой, без камеры и без package:image —
// синтетические изображения строятся прямо в тесте).
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/shot_photo_detection.dart';

void main() {
  group('findCandidateHoles', () {
    test('пустая мишень — кандидатов нет', () {
      final img = GrayImage.filled(200, 200, 200);
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, isEmpty);
    });

    test('тёмная пробоина на светлом поле — находится в нужной точке', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(120, 80, 8, 40); // тёмный кружок, радиус ~ калибр
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, hasLength(1));
      expect(result.first.center.x, closeTo(120, 1.5));
      expect(result.first.center.y, closeTo(80, 1.5));
      expect(result.first.radiusPx, closeTo(8, 2));
    });

    test('светлая пробоина на тёмном яблоке — тоже находится (не только тёмные пятна)', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(100, 100, 60, 30); // тёмное яблоко
      img.fillCircle(105, 95, 8, 190); // пробоина светлее фона под ней
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, hasLength(1));
      expect(result.first.center.x, closeTo(105, 1.5));
      expect(result.first.center.y, closeTo(95, 1.5));
    });

    test('уже известная пробоина не предлагается повторно', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(120, 80, 8, 40);
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
        knownHolesPx: const [PixelPoint(120, 80)],
      );
      expect(result, isEmpty);
    });

    test('пятно намного крупнее калибра отсеивается по размеру', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(100, 100, 40, 40); // радиус в разы больше калибра 8
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, isEmpty);
    });

    test('вытянутая полоса (обрезок линии кольца) отсеивается по форме', () {
      final img = GrayImage.filled(200, 200, 210);
      for (var x = 60; x < 140; x++) {
        for (var y = 98; y < 102; y++) {
          img.set(x, y, 40); // тонкая горизонтальная полоса, не круг
        }
      }
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 8,
      );
      expect(result, isEmpty);
    });

    test('две пробоины сразу — обе найдены раздельно', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(70, 70, 7, 45);
      img.fillCircle(130, 130, 7, 45);
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 90,
        caliberRadiusPx: 7,
      );
      expect(result, hasLength(2));
      final xs = result.map((c) => c.center.x).toList()..sort();
      expect(xs.first, closeTo(70, 1.5));
      expect(xs.last, closeTo(130, 1.5));
    });

    test('вне откалиброванного круга не ищем', () {
      final img = GrayImage.filled(200, 200, 210);
      img.fillCircle(10, 10, 7, 40); // далеко за пределами radiusPx от центра
      final result = findCandidateHoles(
        image: img,
        center: const PixelPoint(100, 100),
        radiusPx: 50,
        caliberRadiusPx: 7,
      );
      expect(result, isEmpty);
    });
  });

  group('pixelToMm', () {
    test('центр остаётся центром', () {
      final mm = pixelToMm(const PixelPoint(100, 100), const PixelPoint(100, 100), 90, 40);
      expect(mm.x, closeTo(0, 1e-9));
      expect(mm.y, closeTo(0, 1e-9));
    });

    test('вправо по пикселям = вправо по мм, вверх по пикселям = вверх по мм (Y инвертируется)', () {
      // Пиксель правее центра -> +X мм. Пиксель ВЫШЕ центра (меньший y)
      // -> +Y мм: та же конвенция, что и на экране мишени.
      final right = pixelToMm(const PixelPoint(190, 100), const PixelPoint(100, 100), 90, 45);
      expect(right.x, closeTo(45, 1e-6));
      expect(right.y, closeTo(0, 1e-6));

      final up = pixelToMm(const PixelPoint(100, 10), const PixelPoint(100, 100), 90, 45);
      expect(up.x, closeTo(0, 1e-6));
      expect(up.y, closeTo(45, 1e-6));
    });
  });
}
