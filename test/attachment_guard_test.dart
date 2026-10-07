import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/attachment_guard.dart';

Uint8List _b(List<int> head, [int pad = 64]) => Uint8List.fromList([...head, ...List.filled(pad, 0x20)]);

/// ZIP без сжатия: локальные заголовки + центральный каталог + EOCD.
Uint8List _zip(List<String> names) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void le(BytesBuilder b, int v, int n) {
    for (var i = 0; i < n; i++) {
      b.addByte((v >> (8 * i)) & 0xFF);
    }
  }

  for (final name in names) {
    final offset = out.length;
    final nb = name.codeUnits;
    le(out, 0x04034b50, 4);
    le(out, 20, 2);
    le(out, 0, 2 + 2 + 2 + 2 + 4 + 4 + 4);
    le(out, nb.length, 2);
    le(out, 0, 2);
    out.add(nb);
    le(central, 0x02014b50, 4);
    le(central, 20, 2);
    le(central, 20, 2);
    le(central, 0, 2 + 2 + 2 + 2 + 4 + 4 + 4);
    le(central, nb.length, 2);
    le(central, 0, 2 + 2 + 2 + 2 + 4);
    le(central, offset, 4);
    central.add(nb);
  }
  final cdOffset = out.length;
  out.add(central.toBytes());
  le(out, 0x06054b50, 4);
  le(out, 0, 4);
  le(out, names.length, 2);
  le(out, names.length, 2);
  le(out, central.length, 4);
  le(out, cdOffset, 4);
  le(out, 0, 2);
  return out.toBytes();
}

void main() {
  final jpeg = _b([0xFF, 0xD8, 0xFF, 0xE0]);
  final png = _b([0x89, 0x50, 0x4E, 0x47]);

  test('обычные файлы проходят', () {
    expect(AttachmentGuard.check(jpeg, 'фото.jpg').ok, isTrue);
    expect(AttachmentGuard.check(png, 'a.PNG').ok, isTrue);
    expect(AttachmentGuard.check(_b('%PDF-1.7\n'.codeUnits), 'правила.pdf').ok, isTrue);
    expect(AttachmentGuard.check(_zip(['a/b.txt', 'фото.jpg']), 'архив.zip').ok, isTrue);
    expect(AttachmentGuard.check(_b('просто текст'.codeUnits), 'заметки.txt').ok, isTrue);
  });

  test('опасные расширения и двойные расширения', () {
    for (final n in ['setup.exe', 'run.bat', 'x.apk', 'a.js', 'm.docm', 'акт.pdf.exe', 'акт.exe.pdf', 'page.html']) {
      expect(AttachmentGuard.check(_b([0x20]), n).ok, isFalse, reason: n);
    }
  });

  test('имя: скрытые символы и путь', () {
    expect(AttachmentGuard.checkName('invoice‮fdp.exe').ok, isFalse);
    expect(AttachmentGuard.checkName('../../etc/passwd').ok, isFalse);
    expect(AttachmentGuard.checkName(r'a\b.txt').ok, isFalse);
    expect(AttachmentGuard.checkName('').ok, isFalse);
  });

  test('исполняемое содержимое под безобидным именем', () {
    expect(AttachmentGuard.check(_b([0x4D, 0x5A, 0x90]), 'photo.jpg').ok, isFalse); // PE
    expect(AttachmentGuard.check(_b([0x7F, 0x45, 0x4C, 0x46]), 'doc.txt').ok, isFalse); // ELF
    expect(AttachmentGuard.check(_b('#!/bin/sh\nrm -rf /'.codeUnits), 'readme.txt').ok, isFalse);
  });

  test('картинка и PDF должны быть настоящими', () {
    expect(AttachmentGuard.check(_b('это не картинка'.codeUnits), 'a.jpg').ok, isFalse);
    expect(AttachmentGuard.check(_b('MZ'.codeUnits), 'a.png').ok, isFalse);
    expect(AttachmentGuard.check(_b('не pdf'.codeUnits), 'a.pdf').ok, isFalse);
  });

  test('PDF с активным содержимым блокируется', () {
    expect(AttachmentGuard.check(_b('%PDF-1.4 /OpenAction << /S /JavaScript /JS (app.alert(1)) >>'.codeUnits), 'a.pdf').ok, isFalse);
    expect(AttachmentGuard.check(_b('%PDF-1.4 /Launch'.codeUnits), 'a.pdf').ok, isFalse);
  });

  test('архивы: запрещённые файлы и приложение Android внутри', () {
    expect(AttachmentGuard.check(_zip(['docs/readme.txt', 'tools/setup.exe']), 'a.zip').ok, isFalse);
    expect(AttachmentGuard.check(_zip(['AndroidManifest.xml', 'classes.dex']), 'a.zip').ok, isFalse);
    expect(AttachmentGuard.check(_zip(['photo.jpg.scr']), 'a.zip').ok, isFalse);
  });
}
