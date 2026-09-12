import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Подготовка фото профиля для чата (пункт списка правок: "фото
/// пользователя, урезание и уменьшение качества не сильное") —
/// центральный квадратный кроп + уменьшение + сжатие в JPEG среднего
/// качества, чтобы аватар помещался обычной текстовой колонкой в базе
/// (без отдельного Supabase Storage — лишняя инфраструктура ради
/// картинки в десяток килобайт).
class AvatarUtils {
  static const int size = 256;
  static const int jpegQuality = 85;

  /// Открывает системную ГАЛЕРЕЮ напрямую (`image_picker`), а не общий
  /// chooser "выбрать файл" — тот на части Android-прошивок предлагает
  /// среди приложений и "Камеру", а снимок камерой Android сохраняет в
  /// галерею сам (обычное поведение приложения камеры, приложение это
  /// не выбирает и не может отключить). `null` — отменили выбор или
  /// файл не распознан как изображение.
  ///
  /// `image_picker` не поддерживает Windows desktop (тот же пробел, что
  /// у пакета `camera` — см. camera_scan_screen.dart) — там остаётся
  /// прежний общий выбор файла через `file_picker`.
  static Future<String?> pickAndProcess() async {
    final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final Uint8List? bytes;
    if (windows) {
      final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
      bytes = result?.files.first.bytes;
    } else {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      bytes = file == null ? null : await file.readAsBytes();
    }
    if (bytes == null) return null;
    return processToBase64(bytes);
  }

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
