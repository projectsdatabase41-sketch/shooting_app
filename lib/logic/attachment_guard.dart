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

/// Защитный фильтр вложений мессенджера. Это НЕ антивирус: он не знает
/// сигнатур вредоносных программ. Он отсекает то, что опасно по самому виду
/// файла: исполняемые и скриптовые форматы, двойные расширения, файлы,
/// выдающие себя за картинку или PDF, пакеты Android, активное содержимое
/// PDF и архивы с исполняемыми файлами внутри.
class AttachmentGuard {
  AttachmentGuard._();

  /// Расширения, которые нельзя ни отправлять, ни принимать.
  static const Set<String> blockedExtensions = {
    // Windows / общие исполняемые и скрипты
    'exe', 'msi', 'bat', 'cmd', 'com', 'scr', 'pif', 'cpl', 'dll', 'sys', 'drv',
    'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'ps1', 'psm1', 'hta', 'msc', 'inf',
    'reg', 'lnk', 'url', 'gadget', 'application', 'appx', 'appxbundle', 'msix',
    // Unix / macOS
    'sh', 'bash', 'zsh', 'run', 'bin', 'elf', 'command', 'app', 'dmg', 'pkg',
    'deb', 'rpm',
    // Android / iOS / Java
    'apk', 'aab', 'xapk', 'ipa', 'jar', 'class', 'dex',
    // Документы с макросами и веб-страницы с кодом
    'docm', 'xlsm', 'pptm', 'dotm', 'xlam', 'ppam', 'html', 'htm', 'xhtml', 'svg',
    // Образы дисков и прочее
    'iso', 'img', 'vhd', 'vhdx', 'chm',
  };

  static const Set<String> _imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
  static const int _scanLimit = 5 * 1024 * 1024;
  static const int _tailLimit = 256 * 1024;

  /// Проверка файла целиком в памяти.
  static AttachmentVerdict check(Uint8List bytes, String fileName) {
    final head = bytes.length > _scanLimit ? Uint8List.sublistView(bytes, 0, _scanLimit) : bytes;
    final tail = bytes.length > _tailLimit
        ? Uint8List.sublistView(bytes, bytes.length - _tailLimit)
        : bytes;
    return _check(fileName, head, tail, bytes.length);
  }

  /// Проверка скачанного на диск большого файла (читаются начало и конец).
  static Future<AttachmentVerdict> checkFile(String path, [String? fileName]) async {
    final name = fileName ?? p.basename(path);
    final byName = checkName(name);
    if (!byName.ok) return byName;
    final f = File(path);
    final len = await f.length();
    final raf = await f.open();
    try {
      final head = await _read(raf, 0, len < _scanLimit ? len : _scanLimit);
      final tail = len > _tailLimit ? await _read(raf, len - _tailLimit, _tailLimit) : head;
      return _check(name, head, tail, len);
    } finally {
      await raf.close();
    }
  }

  static Future<Uint8List> _read(RandomAccessFile raf, int from, int count) async {
    await raf.setPosition(from);
    return Uint8List.fromList(await raf.read(count));
  }

  /// Проверка только по имени (до скачивания).
  static AttachmentVerdict checkName(String fileName) {
    final name = fileName.trim();
    if (name.isEmpty) return AttachmentVerdict.blocked(tr('у файла нет имени'));
    // Управляющие символы и «переворот» направления текста (invoicefdp.exe).
    if (RegExp(r'[\u0000-\u001f\u202a-\u202e\u2066-\u2069]').hasMatch(name)) {
      return AttachmentVerdict.blocked(tr('в имени файла скрытые символы'));
    }
    if (name.contains('/') || name.contains(r'\')) {
      return AttachmentVerdict.blocked(tr('в имени файла путь к папке'));
    }
    final parts = name.toLowerCase().split('.');
    if (parts.length > 1) {
      // Опасное расширение в любой позиции после первой части: «акт.exe.pdf».
      for (final part in parts.skip(1)) {
        if (blockedExtensions.contains(part.trim())) {
          return AttachmentVerdict.blocked(
              tr('запрещённый тип файла (.{ext})', {'ext': part.trim()}));
        }
      }
    }
    return const AttachmentVerdict.ok();
  }

  static AttachmentVerdict _check(String fileName, Uint8List head, Uint8List tail, int totalLen) {
    final byName = checkName(fileName);
    if (!byName.ok) return byName;
    final ext = fileName.toLowerCase().split('.').last;

    // Исполняемые файлы по содержимому, что бы ни было написано в имени.
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
    if (_startsWith(head, const [0x23, 0x21])) {
      return AttachmentVerdict.blocked(tr('это скрипт'));
    }
    if (_startsWith(head, const [0xCA, 0xFE, 0xBA, 0xBE]) && ext != 'png') {
      return AttachmentVerdict.blocked(tr('это программа Java'));
    }

    // Файл выдаёт себя за картинку, но картинкой не является.
    if (_imageExt.contains(ext) && !_looksLikeImage(head, ext)) {
      return AttachmentVerdict.blocked(tr('файл не является картинкой'));
    }

    final isZip = _startsWith(head, const [0x50, 0x4B, 0x03, 0x04]) ||
        _startsWith(head, const [0x50, 0x4B, 0x05, 0x06]);
    if (isZip) {
      for (final entry in _zipEntryNames(tail, totalLen)) {
        final lower = entry.toLowerCase();
        if (lower == 'androidmanifest.xml' || lower == 'classes.dex') {
          return AttachmentVerdict.blocked(tr('это приложение Android'));
        }
        final bad = checkName(entry.split('/').last);
        if (!bad.ok) {
          return AttachmentVerdict.blocked(
              tr('в архиве запрещённый файл ({name})', {'name': entry}));
        }
      }
    }

    if (_startsWith(head, '%PDF'.codeUnits)) {
      final text = String.fromCharCodes(head);
      if (RegExp(r'/(JavaScript|JS|Launch|EmbeddedFile|OpenAction|AA)\b').hasMatch(text)) {
        return AttachmentVerdict.blocked(tr('в PDF есть скрипты или вложения'));
      }
    } else if (ext == 'pdf') {
      return AttachmentVerdict.blocked(tr('файл не является PDF'));
    }

    return const AttachmentVerdict.ok();
  }

  /// Имена файлов из центрального каталога ZIP (он лежит в конце файла).
  /// Пусто, если каталог не найден в [tail] (необычный архив).
  static List<String> _zipEntryNames(Uint8List tail, int totalLen) {
    final bd = ByteData.sublistView(tail);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (bd.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return const [];
    final cdSize = bd.getUint32(eocd + 12, Endian.little);
    final cdOffset = bd.getUint32(eocd + 16, Endian.little);
    var pos = cdOffset - (totalLen - tail.length);
    if (pos < 0 || cdSize == 0) return const [];
    final names = <String>[];
    final end = pos + cdSize;
    while (pos + 46 <= tail.length && pos < end && names.length < 2000) {
      if (bd.getUint32(pos, Endian.little) != 0x02014b50) break;
      final nameLen = bd.getUint16(pos + 28, Endian.little);
      final extraLen = bd.getUint16(pos + 30, Endian.little);
      final commentLen = bd.getUint16(pos + 32, Endian.little);
      if (pos + 46 + nameLen > tail.length) break;
      names.add(String.fromCharCodes(tail.sublist(pos + 46, pos + 46 + nameLen)));
      pos += 46 + nameLen + extraLen + commentLen;
    }
    return names;
  }

  static bool _startsWith(Uint8List b, List<int> magic) {
    if (b.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (b[i] != magic[i]) return false;
    }
    return true;
  }

  static bool _looksLikeImage(Uint8List b, String ext) {
    if (_startsWith(b, const [0xFF, 0xD8, 0xFF])) return true; // JPEG
    if (_startsWith(b, const [0x89, 0x50, 0x4E, 0x47])) return true; // PNG
    if (_startsWith(b, 'GIF8'.codeUnits)) return true;
    if (_startsWith(b, 'BM'.codeUnits)) return true;
    if (_startsWith(b, 'RIFF'.codeUnits) && b.length > 12 && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
      return true;
    }
    // HEIC/HEIF: «....ftyp»
    if (b.length > 12 && String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') return true;
    return false;
  }
}
