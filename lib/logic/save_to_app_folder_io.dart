import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// «Скачать» вложение чата: переносит файл из приложения в отдельную папку
/// «Nexus» без вопросов, куда класть. Фото и видео попадают в альбом «Nexus»
/// галереи, остальное — в «Загрузки/Nexus». Пока пользователь не нажмёт
/// «Скачать», файл живёт только внутри приложения и в галерее/проводнике
/// не виден. Возвращает `false`, если сохранить не удалось.
Future<bool> saveToAppFolder(Uint8List bytes, String fileName, String? mime) async {
  final src = await _temp(_safeName(fileName));
  try {
    await src.writeAsBytes(bytes);
    return await saveFileToAppFolder(src.path, fileName, mime);
  } finally {
    try {
      if (await src.exists()) await src.delete();
    } catch (_) {}
  }
}

/// То же для файла на диске (большие вложения): не читается в память.
Future<bool> saveFileToAppFolder(String path, String fileName, String? mime) async {
  final name = _safeName(fileName);
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  final isImage = (mime?.startsWith('image/') ?? false) ||
      const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'}.contains(ext);
  final isVideo = (mime?.startsWith('video/') ?? false) ||
      const {'mp4', 'mov', 'mkv', 'webm', '3gp'}.contains(ext);
  try {
    if (Platform.isAndroid || Platform.isIOS) {
      if (isImage || isVideo) {
        if (!await Gal.hasAccess(toAlbum: true) && !await Gal.requestAccess(toAlbum: true)) return false;
        isImage ? await Gal.putImage(path, album: 'Nexus') : await Gal.putVideo(path, album: 'Nexus');
        return true;
      }
      if (Platform.isAndroid) {
        // media_store забирает файл и удаляет его — отдаём копию под исходным именем.
        final copy = await _temp(name);
        await File(path).copy(copy.path);
        await MediaStore.ensureInitialized();
        MediaStore.appFolder = 'Nexus';
        final info = await MediaStore().saveFile(
          tempFilePath: copy.path,
          dirType: DirType.download,
          dirName: DirName.download,
        );
        return info != null;
      }
    }
    // Компьютер (и iOS для не-медиа): «Загрузки/Nexus».
    final base = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'Nexus'));
    await dir.create(recursive: true);
    await File(path).copy(_unique(dir.path, name));
    return true;
  } catch (_) {
    return false;
  }
}

/// Только имя файла: путь из присланного имени не принимаем.
String _safeName(String fileName) {
  final n = p.basename(fileName);
  return n.isEmpty ? 'file' : n;
}

Future<File> _temp(String name) async {
  final dir = await getTemporaryDirectory();
  final sub = Directory(p.join(dir.path, 'nexus_${DateTime.now().microsecondsSinceEpoch}'));
  await sub.create(recursive: true);
  return File(p.join(sub.path, name));
}

String _unique(String dir, String name) {
  var path = p.join(dir, name);
  var i = 1;
  while (File(path).existsSync()) {
    path = p.join(dir, '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}');
    i++;
  }
  return path;
}
