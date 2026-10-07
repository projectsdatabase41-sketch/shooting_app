import 'dart:typed_data';

import 'save_file_web.dart';

/// Веб: браузер сам кладёт файл в свою папку загрузок, без вопросов.
Future<bool> saveToAppFolder(Uint8List bytes, String fileName, String? mime) =>
    saveBytes(bytes, fileName);

/// В вебе файлов на диске нет — большие вложения скачиваются иначе.
Future<bool> saveFileToAppFolder(String path, String fileName, String? mime) async => false;
