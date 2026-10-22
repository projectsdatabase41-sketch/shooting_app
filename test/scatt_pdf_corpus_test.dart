import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/import/scatt_pdf.dart';

/// Сверка с эталоном: отчёт Python-скрипта по реальным файлам владельца (папка и отчёт лежат у него
/// в Загрузках). Без них тест пропускается.
void main() {
  final dir = Directory('C:/Users/Admin/Downloads/Тренировки');
  final reportFile = File('C:/Users/Admin/Downloads/Тренировки/scatt_import_report.json');
  final have = dir.existsSync() && reportFile.existsSync();

  test('разбор PDF в Dart совпадает с эталонным отчётом скрипта на всех файлах', () {
    final rep = (jsonDecode(reportFile.readAsStringSync()) as List).cast<Map<String, dynamic>>();
    var checked = 0, shots = 0;
    final errors = <String>[];
    for (final e in rep) {
      final f = File('${dir.path}/${e['file']}');
      final r = scattTryParse(Uint8List.fromList(f.readAsBytesSync()));
      if (r['ok'] != true) {
        errors.add('${e['file']}: не разобран: ${r['reason']}');
        continue;
      }
      final h = e['header'] as Map<String, dynamic>;
      final s = r['session'] as Map<String, dynamic>;
      final exp = (e['series'] as List).cast<Map<String, dynamic>>().where((x) => x['sighter'] != true).expand((x) => (x['shots'] as List).cast<Map<String, dynamic>>().map((y) => {...y, 'series': x['no']})).toList();
      final got = (s['shots'] as List).cast<Map<String, dynamic>>();
      if (r['athlete'] != h['athlete']) errors.add('${e['file']}: спортсмен ${r['athlete']} ≠ ${h['athlete']}');
      if ((r['total'] as num) != (h['total'] as num)) errors.add('${e['file']}: сумма ${r['total']} ≠ ${h['total']}');
      if (r['n_shots'] != h['n_shots']) errors.add('${e['file']}: выстрелов ${r['n_shots']} ≠ ${h['n_shots']}');
      if (!(h['started'] as String).startsWith((r['started'] as String).substring(0, 16))) errors.add('${e['file']}: дата ${r['started']} ≠ ${h['started']}');
      if (r['stance'] != h['stance']) errors.add('${e['file']}: изготовка ${r['stance']} ≠ ${h['stance']}');
      if ((r['problems'] as List).length != (e['problems'] as List).length) errors.add('${e['file']}: замечания ${r['problems']} ≠ ${e['problems']}');
      if (got.length != exp.length) {
        errors.add('${e['file']}: строк ${got.length} ≠ ${exp.length}');
        continue;
      }
      for (var i = 0; i < got.length; i++) {
        shots++;
        final a = got[i], b = exp[i];
        if (a['n'] != b['no'] || a['series'] != b['series'] || (a['score'] as num) != (b['score'] as num)) {
          errors.add('${e['file']} выстр.$i: ${a['n']}/${a['series']}/${a['score']} ≠ ${b['no']}/${b['series']}/${b['score']}');
          break;
        }
        if (((a['x_mm'] as num) - (b['x_mm'] as num)).abs() > 0.011 || ((a['y_mm'] as num) - (b['y_mm'] as num)).abs() > 0.011) {
          errors.add('${e['file']} выстр.$i: координаты ${a['x_mm']},${a['y_mm']} ≠ ${b['x_mm']},${b['y_mm']}');
          break;
        }
      }
      checked++;
    }
    // ignore: avoid_print
    print('сверено файлов: $checked, выстрелов: $shots, расхождений: ${errors.length}');
    expect(errors.take(15).toList(), isEmpty);
    expect(checked, rep.length);
  }, skip: have ? false : 'нет папки с отчётами');
}
