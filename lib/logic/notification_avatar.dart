import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Картинка для уведомления о сообщении: круглое фото отправителя и
/// маленький значок приложения в правом нижнем углу (как в обычных
/// мессенджерах). Чистый Dart (`image`), работает и в фоновом изоляте
/// push, где интерфейса нет. `null` — фото нет или оно битое: тогда
/// система покажет обычный значок приложения.
Uint8List? composeNotificationAvatar(String? avatarBase64, Uint8List? badgePng, {int size = 256}) {
  if (avatarBase64 == null || avatarBase64.isEmpty) return null;
  try {
    final src = img.decodeImage(base64Decode(avatarBase64));
    if (src == null) return null;
    final side = src.width < src.height ? src.width : src.height;
    final square = img.copyCrop(src,
        x: (src.width - side) ~/ 2, y: (src.height - side) ~/ 2, width: side, height: side);
    final out = img.copyResize(square, width: size, height: size).convert(numChannels: 4);
    _circle(out, size / 2, size / 2, size / 2);

    final badge = badgePng == null ? null : img.decodePng(badgePng);
    if (badge != null) {
      final r = size * 0.19; // радиус значка
      final c = size - r - size * 0.02; // центр ближе к углу
      // белая обводка, чтобы значок отделялся от фото
      img.fillCircle(out, x: c.round(), y: c.round(), radius: (r + size * 0.025).round(), color: img.ColorRgba8(255, 255, 255, 255));
      final b = img.copyResize(badge, width: (r * 2).round(), height: (r * 2).round()).convert(numChannels: 4);
      _circle(b, r, r, r);
      img.compositeImage(out, b, dstX: (c - r).round(), dstY: (c - r).round());
    }
    return img.encodePng(out);
  } catch (_) {
    return null;
  }
}

/// Делает прозрачным всё за пределами круга.
void _circle(img.Image im, double cx, double cy, double r) {
  for (final p in im) {
    final dx = p.x + 0.5 - cx, dy = p.y + 0.5 - cy;
    if (dx * dx + dy * dy > r * r) p.a = 0;
  }
}
