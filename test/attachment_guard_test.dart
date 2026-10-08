import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/attachment_guard.dart';

Uint8List _b(List<int> head, [int pad = 64]) => Uint8List.fromList([...head, ...List.filled(pad, 0x20)]);

void main() {
  test('обычные документы, архивы, картинки и PDF проходят', () {
    expect(AttachmentGuard.check(_b([0xFF, 0xD8, 0xFF]), 'фото.jpg').ok, isTrue);
    expect(AttachmentGuard.check(_b('%PDF-1.4 /JavaScript /OpenAction'.codeUnits), 'правила.pdf').ok, isTrue);
    expect(AttachmentGuard.check(_b([0x50, 0x4B, 0x03, 0x04]), 'документ.docx').ok, isTrue);
    expect(AttachmentGuard.check(_b([0x50, 0x4B, 0x03, 0x04]), 'архив.zip').ok, isTrue);
    expect(AttachmentGuard.check(_b('текст'.codeUnits), 'заметки.txt').ok, isTrue);
    expect(AttachmentGuard.check(_b('<html>'.codeUnits), 'страница.html').ok, isTrue);
    expect(AttachmentGuard.check(_b('x'.codeUnits), 'site.com.pdf').ok, isTrue);
    expect(AttachmentGuard.check(_b('x'.codeUnits), 'отчёт.final.sh.2024.pdf').ok, isTrue);
  });

  test('исполняемые программы по расширению блокируются', () {
    for (final n in ['setup.exe', 'run.bat', 'x.apk', 'a.msi', 'tool.jar']) {
      expect(AttachmentGuard.check(_b([0x20]), n).ok, isFalse, reason: n);
    }
  });

  test('исполняемое содержимое под безобидным именем', () {
    expect(AttachmentGuard.check(_b([0x4D, 0x5A, 0x90]), 'photo.jpg').ok, isFalse); // PE
    expect(AttachmentGuard.check(_b([0x7F, 0x45, 0x4C, 0x46]), 'doc.txt').ok, isFalse); // ELF
  });

  test('имя: скрытые символы и путь', () {
    expect(AttachmentGuard.checkName('invoice\u202Efdp.exe').ok, isFalse);
    expect(AttachmentGuard.checkName('../../etc/passwd').ok, isFalse);
    expect(AttachmentGuard.checkName('').ok, isFalse);
  });
}
