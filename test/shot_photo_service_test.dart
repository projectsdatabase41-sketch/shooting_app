// Проверяет реальный путь декодирования (PNG-байты -> GrayImage), а не
// только логику поиска на синтетических GrayImage — здесь как раз то
// звено, которое code review не поймает: неверный ChannelOrder дал бы
// компилируемый, но бессмысленный (полностью серый) результат.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shooting_app/logic/shot_photo_detection.dart';
import 'package:shooting_app/services/shot_photo_service.dart';

void main() {
  test('decodeForAnalysis — реальный PNG даёт узнаваемую пробоину', () {
    final source = img.Image(width: 300, height: 300);
    img.fill(source, color: img.ColorRgb8(210, 210, 210));
    img.fillCircle(source, x: 150, y: 120, radius: 12, color: img.ColorRgb8(40, 40, 40));
    final bytes = Uint8List.fromList(img.encodePng(source));

    final decoded = ShotPhotoService.decode(bytes);
    final result = ShotPhotoService.analyze(decoded);
    expect(result.scale, 1.0, reason: '300px меньше рабочего разрешения — уменьшать не должно');
    expect(result.image.width, 300);
    expect(result.image.height, 300);

    // Пиксель в центре пробоины должен остаться тёмным, а не превратиться
    // в шум/чёрный/белый из-за неверного канала при чтении байтов.
    final centerValue = result.image.at(150, 120);
    expect(centerValue, lessThan(80));
    final paperValue = result.image.at(20, 20);
    expect(paperValue, greaterThan(180));

    final holes = findCandidateHoles(
      image: result.image,
      center: const PixelPoint(150, 150),
      radiusPx: 140,
      caliberRadiusPx: 12,
    );
    expect(holes, hasLength(1));
    expect(holes.first.center.x, closeTo(150, 2));
    expect(holes.first.center.y, closeTo(120, 2));
  });

  test('decodeForAnalysis — большое фото уменьшается до рабочего разрешения', () {
    final source = img.Image(width: 2400, height: 1600);
    img.fill(source, color: img.ColorRgb8(200, 200, 200));
    final bytes = Uint8List.fromList(img.encodePng(source));

    final decoded = ShotPhotoService.decode(bytes);
    final result = ShotPhotoService.analyze(decoded);
    expect(result.image.width, ShotPhotoService.maxWorkingSide);
    expect(result.scale, closeTo(ShotPhotoService.maxWorkingSide / 2400, 1e-9));
  });
}
