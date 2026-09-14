import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';

/// Подготовка фото для отправки в чат — в отличие от аватара
/// (`AvatarUtils`, квадратный кроп под миниатюру), здесь только
/// уменьшение длинной стороны и сжатие: пропорции кадра сохраняются,
/// как в любом обычном чате с фото.
class ChatMediaUtils {
  static const int maxSide = 1600;
  static const int jpegQuality = 80;

  /// Совпадает с лимитом бакета chat-media в Storage (см.
  /// sql/chat-schema.sql) — проверка на клиенте до отправки, а не после
  /// отказа сервера. Личный чат хранит вложение как base64 в локальной
  /// sqlite и целиком гоняет его в теле JSON-запроса — гораздо большие
  /// файлы (сотни МБ) там не просто "долго", а реально рискуют уронить
  /// приложение по памяти, поэтому лимит consciously не поднят выше.
  static const int maxAttachmentBytes = 50 * 1024 * 1024;

  /// `null`, если файл не распознан как изображение — тогда стоит
  /// отправить как есть, типом `file`, а не `image`.
  static Uint8List? compressImage(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final longSide = decoded.width > decoded.height ? decoded.width : decoded.height;
    final resized = longSide <= maxSide
        ? decoded
        : (decoded.width >= decoded.height
            ? img.copyResize(decoded, width: maxSide)
            : img.copyResize(decoded, height: maxSide));
    return img.encodeJpg(resized, quality: jpegQuality);
  }

  /// По расширению имени файла — простая, но достаточная для решения
  /// "показать как фото или как файл" эвристика, без завязки на
  /// платформенный MIME-детектор.
  static bool looksLikeImage(String fileName) {
    final lower = fileName.toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic'].any(lower.endsWith);
  }

  static String mimeFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic')) return 'image/heic';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  /// Имя файла с пробелами/скобками/юникодом (обычное дело — "Screenshot
  /// 2024-01-01 (1).png") ломает путь объекта в Storage: сырой пробел в
  /// URL сервер отклоняет 400-й ошибкой. Читаемое имя всё равно хранится
  /// отдельно (`attachment_name`), в пути нужна только уникальность.
  static String safePathSegment(String name) {
    final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return sanitized.isEmpty ? 'file' : sanitized;
  }

  /// "Сохранить" у вложения (см. ChatPreferences.photoDownloadEnabled) —
  /// системный лист "Поделиться", а не прямая запись в галерею/загрузки:
  /// уже есть в зависимостях, работает на всех платформах без отдельных
  /// разрешений на хранилище, и пользователь сам решает, куда сохранить.
  static Future<void> shareAttachment(Uint8List bytes, String fileName, String? mime) {
    return SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, name: fileName, mimeType: mime)],
    ));
  }

  /// Читаемый размер — "2.4 МБ" вместо голого числа байт.
  static String formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
}
