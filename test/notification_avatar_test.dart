import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shooting_app/logic/notification_avatar.dart';

void main() {
  final photo = base64Encode(img.encodeJpg(img.Image(width: 300, height: 200)..clear(img.ColorRgb8(200, 0, 0))));
  final badge = img.encodePng(img.Image(width: 96, height: 96)..clear(img.ColorRgb8(0, 0, 255)));

  test('круглое фото, углы прозрачные, значок синий внизу справа', () {
    final png = composeNotificationAvatar(photo, badge)!;
    final out = img.decodePng(png)!;
    expect(out.width, 256);
    expect(out.getPixel(2, 2).a, 0); // угол вне круга
    final center = out.getPixel(128, 128);
    expect(center.r > 150 && center.b < 60, isTrue); // фото
    final b = out.getPixel(256 - 50, 256 - 50);
    expect(b.b > 150 && b.r < 60, isTrue); // значок
    final tl = out.getPixel(60, 60);
    expect(tl.r > 150, isTrue); // слева сверху значка нет
  });

  test('без фото или с мусором — null (покажется обычный значок)', () {
    expect(composeNotificationAvatar(null, badge), isNull);
    expect(composeNotificationAvatar('', badge), isNull);
    expect(composeNotificationAvatar('не base64!', badge), isNull);
  });

  test('без значка — просто круглое фото', () {
    final out = img.decodePng(composeNotificationAvatar(photo, null)!)!;
    expect(out.getPixel(206, 206).r > 150, isTrue);
  });
}
