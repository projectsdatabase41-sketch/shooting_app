import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Подготовка фото профиля для чата (пункт списка правок: "фото
/// пользователя, урезание и уменьшение качества не сильное") —
/// центральный квадратный кроп + уменьшение + сжатие в JPEG среднего
/// качества, чтобы аватар помещался обычной текстовой колонкой в базе
/// (без отдельного Supabase Storage — лишняя инфраструктура ради
/// картинки в десяток килобайт).
class AvatarUtils {
  static const int size = 256;
  static const int jpegQuality = 85;

  /// `null`, если файл не распознан как изображение.
  static String? processToBase64(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final side = decoded.width < decoded.height ? decoded.width : decoded.height;
    final x = (decoded.width - side) ~/ 2;
    final y = (decoded.height - side) ~/ 2;
    final cropped = img.copyCrop(decoded, x: x, y: y, width: side, height: side);
    final resized = side == size ? cropped : img.copyResize(cropped, width: size, height: size);
    return base64Encode(img.encodeJpg(resized, quality: jpegQuality));
  }
}
