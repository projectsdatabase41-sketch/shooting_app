import 'dart:io' show File, RandomAccessFile;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../i18n/i18n.dart';

/// Итог проверки вложения.
class AttachmentVerdict {
  final bool ok;

  /// Причина блокировки (уже на языке интерфейса), `null` если [ok].
  final String? reason;
  const AttachmentVerdict.ok()
      : ok = true,
        reason = null;
  const AttachmentVerdict.blocked(this.reason) : ok = false;
}

/// Защита при ПРИЁМЕ вложений: не сохраняем исполняемые программы (по
/// расширению и по «магическим байтам»), чтобы не принести их на устройство.
/// Обычные документы, архивы, картинки и PDF не проверяются. Это не антивирус.
/// При отправке файлы не проверяются.
class AttachmentGuard {
  AttachmentGuard._();

  /// Расширения исполняемых программ.
  static const Set<String> blockedExtensions = {
    'exe', 'msi', 'bat', 'cmd', 'scr', 'pif', 'cpl', 'dll', 'sys', 'vbs', 'vbe',
    'wsf', 'wsh', 'ps1', 'hta', 'lnk', 'apk', 'aab', 'xapk', 'jar', 'sh', 'app',
    'dmg', 'pkg', 'deb', 'rpm',
  };

  static const int _headLimit = 64;

  /// Проверка файла целиком в памяти.
  static AttachmentVerdict check(Uint8List bytes, String fileName) =>
      _check(fileName, bytes);

  /// Проверка скачанного на диск большого файла (читается только начало).
  static Future<AttachmentVerdict> checkFile(String path, [String? fileName]) async {
    final name = fileName ?? p.basename(path);
    final byName = checkName(name);
    if (!byName.ok) return byName;
    final RandomAccessFile raf = await File(path).open();
    try {
      return _check(name, Uint8List.fromList(await raf.read(_headLimit)));
    } finally {
      await raf.close();
    }
  }

  /// Проверка только по имени: скрытые символы управления текстом, путь,
  /// расширение исполняемой программы.
  static AttachmentVerdict checkName(String fileName) {
    final name = fileName.trim();
    if (name.isEmpty) return AttachmentVerdict.blocked(tr('у файла нет имени'));
    if (RegExp(r'[\u0000-\u001f\u202a-\u202e\u2066-\u2069]').hasMatch(name)) {
      return AttachmentVerdict.blocked(tr('в имени файла скрытые символы'));
    }
    if (name.contains('/') || name.contains(r'\')) {
      return AttachmentVerdict.blocked(tr('в имени файла путь к папке'));
    }
    final parts = name.toLowerCase().split('.');
    if (parts.length > 1 && blockedExtensions.contains(parts.last.trim())) {
      return AttachmentVerdict.blocked(
          tr('запрещённый тип файла (.{ext})', {'ext': parts.last.trim()}));
    }
    return const AttachmentVerdict.ok();
  }

  static AttachmentVerdict _check(String fileName, Uint8List head) {
    final byName = checkName(fileName);
    if (!byName.ok) return byName;
    if (_startsWith(head, const [0x4D, 0x5A])) {
      return AttachmentVerdict.blocked(tr('это исполняемая программа Windows'));
    }
    if (_startsWith(head, const [0x7F, 0x45, 0x4C, 0x46])) {
      return AttachmentVerdict.blocked(tr('это исполняемая программа Linux/Android'));
    }
    if (_startsWith(head, const [0xCF, 0xFA, 0xED, 0xFE]) ||
        _startsWith(head, const [0xCE, 0xFA, 0xED, 0xFE]) ||
        _startsWith(head, const [0xFE, 0xED, 0xFA, 0xCE]) ||
        _startsWith(head, const [0xFE, 0xED, 0xFA, 0xCF])) {
      return AttachmentVerdict.blocked(tr('это исполняемая программа macOS'));
    }
    return const AttachmentVerdict.ok();
  }

  static bool _startsWith(Uint8List b, List<int> magic) {
    if (b.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (b[i] != magic[i]) return false;
    }
    return true;
  }
}
