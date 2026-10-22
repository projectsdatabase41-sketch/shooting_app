import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/import/scatt_pdf.dart';

/// Минимальный валидный PDF с классической таблицей xref: [creator] и [pages] пустых страниц.
Uint8List _pdf({String creator = 'Writer', int pages = 2, String content = ''}) {
  final objs = <String>[];
  objs.add('<< /Type /Catalog /Pages 2 0 R >>');
  final kids = [for (var i = 0; i < pages; i++) '${4 + i * 2} 0 R'].join(' ');
  objs.add('<< /Type /Pages /Kids [$kids] /Count $pages >>');
  objs.add('<< /Creator ($creator) /Producer (test) >>');
  for (var i = 0; i < pages; i++) {
    objs.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents ${5 + i * 2} 0 R /Resources << >> >>');
    objs.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final out = StringBuffer('%PDF-1.4\n');
  final offs = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offs.add(out.length);
    out.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final x = out.length;
  out.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offs) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Info 3 0 R >>\nstartxref\n$x\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(out.toString()));
}

void main() {
  test('чужие и битые файлы не принимаются и не роняют разбор', () {
    final cases = <String, Uint8List>{
      'пустой': Uint8List(0),
      'мусор': Uint8List.fromList(List.generate(5000, (i) => (i * 7919) % 256)),
      'текст': Uint8List.fromList(utf8.encode('Привет, это не PDF. ' * 40)),
      'обычный PDF': _pdf(creator: 'Microsoft Word', content: 'BT /F1 12 Tf (hello) Tj ET'),
      'PDF не от SCATT': _pdf(creator: 'Qt 6.7.3'),
      'SCATT в метаданных, но шапки нет': _pdf(creator: 'SCATT Expert 24.12.2', content: 'BT ET'),
      'SCATT, одна страница': _pdf(creator: 'SCATT Expert', pages: 1),
    };
    for (final e in cases.entries) {
      final r = scattTryParse(e.value);
      expect(r['ok'], isFalse, reason: e.key);
      expect(r['reason'], isA<String>(), reason: e.key);
    }
  });

  test('обрезанный и испорченный настоящий отчёт — не отчёт, а не мусор в базе', () {
    final dir = Directory('C:/Users/Admin/Downloads/Тренировки');
    if (!dir.existsSync()) return;
    final f = dir.listSync().whereType<File>().firstWhere((e) => e.path.endsWith('.pdf'));
    final good = Uint8List.fromList(f.readAsBytesSync());
    expect(scattTryParse(good)['ok'], isTrue);
    // обрезан до половины (нет xref в конце)
    expect(scattTryParse(Uint8List.sublistView(good, 0, good.length ~/ 2))['ok'], isFalse);
    // испорчена середина: либо не разобрался, либо замечания — но не тихий «ok» с неверными числами
    final bad = Uint8List.fromList(good);
    for (var i = bad.length ~/ 3; i < bad.length ~/ 3 + 200; i++) {
      bad[i] = (bad[i] + 1) & 0xFF;
    }
    final r = scattTryParse(bad);
    expect(r['ok'] == false || (r['problems'] as List).isNotEmpty || r['total'] == scattTryParse(good)['total'], isTrue);
  });
}
