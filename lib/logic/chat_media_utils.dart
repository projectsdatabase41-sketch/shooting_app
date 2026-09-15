import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

/// Результат выбора вложения — байты плюс исходное имя файла.
class ChatAttachmentPick {
  final Uint8List bytes;
  final String name;
  const ChatAttachmentPick(this.bytes, this.name);
}

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

  /// Свой выбор вложения (Камера/Галерея/Файл) вместо системного
  /// chooser'а `file_picker` без ограничений — тот на Android показывает
  /// длинный список приложений вперемешку с двумя "Камера" (см. правку
  /// пользователя). Камера и галерея — через `image_picker` (как у
  /// аватара, `AvatarUtils`), файл — через `file_picker`, как раньше.
  /// На Windows `image_picker` не работает (см. `AvatarUtils`) — там
  /// сразу открывается обычный выбор файла, без листа выбора.
  static Future<ChatAttachmentPick?> pickAttachment(BuildContext context) async {
    final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    if (windows) return _pickFile();

    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: const Text('Камера'),
            onTap: () => Navigator.pop(ctx, 0),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Галерея'),
            onTap: () => Navigator.pop(ctx, 1),
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: const Text('Файл'),
            onTap: () => Navigator.pop(ctx, 2),
          ),
        ]),
      ),
    );
    if (choice == null) return null;
    if (choice == 2) return _pickFile();

    final xfile = await ImagePicker().pickImage(source: choice == 0 ? ImageSource.camera : ImageSource.gallery);
    if (xfile == null) return null;
    return ChatAttachmentPick(await xfile.readAsBytes(), xfile.name);
  }

  static Future<ChatAttachmentPick?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.first;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return null;
    return ChatAttachmentPick(bytes, file.name);
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
