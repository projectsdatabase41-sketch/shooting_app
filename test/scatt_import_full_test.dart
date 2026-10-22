import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/import/scatt_pdf.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/session_import.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  final dir = Directory('C:/Users/Admin/Downloads/Тренировки');
  final reportFile = File('C:/Users/Admin/Downloads/Тренировки/scatt_import_report.json');
  final have = dir.existsSync() && reportFile.existsSync();

  test('импорт всех отчётов: ничего не теряется, лишних упражнений нет, повтор и сдвинутое время — не дубли', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();
    final air = store.createExercise(name: 'Пневматическая винтовка 10 м — 60 выстрелов', targetFaceCode: 'rifle_10m', totalShots: 60, seriesSize: 10);
    final prone = store.createExercise(name: 'Винтовка 50 м, лёжа — 60 выстрелов', targetFaceCode: 'rifle_50m', totalShots: 60, seriesSize: 10);
    final three = store.createExercise(name: 'Винтовка 50 м, 3 положения — 120 выстрелов', targetFaceCode: 'rifle_50m', totalShots: 120, seriesSize: 10);
    final before = store.exercises.length;

    final rep = (jsonDecode(reportFile.readAsStringSync()) as List).cast<Map<String, dynamic>>();
    ImportBundle bundleOf(Map<String, dynamic> parsed) => SessionImport.parse(jsonEncode({
          'format': SessionImport.formatId,
          'version': SessionImport.supportedVersion,
          'source': 'SCATT (PDF)',
          'sessions': [parsed['session']],
        }));
    final parsedAll = <Map<String, dynamic>>[];
    for (final e in rep) {
      final r = scattTryParse(Uint8List.fromList(File('${dir.path}/${e['file']}').readAsBytesSync()));
      expect(r['ok'], isTrue, reason: '${e['file']}');
      parsedAll.add(r);
    }

    // одна из тренировок уже есть, но с временем, сдвинутым на 5 часов (как у раннего импорта через ИИ)
    final first = bundleOf(parsedAll.first).sessions.first;
    store.upsertSession(first.session.copyWith(id: 'old1', exerciseId: air.id, startedAt: first.session.startedAt!.add(const Duration(hours: 5))));

    var written = 0;
    for (final r in parsedAll) {
      written += SessionImport.apply(store, bundleOf(r));
    }
    expect(written, rep.length - 1, reason: 'сдвинутая по времени — дубль, остальные записаны');
    expect(store.sessions.length, rep.length);
    expect(store.exercises.length, before, reason: 'новых упражнений создаваться не должно');

    // потерь нет: число выстрелов и сумма каждой тренировки совпадают с отчётом
    for (var i = 0; i < rep.length; i++) {
      final h = rep[i]['header'] as Map<String, dynamic>;
      final key = parsedAll[i]['key'];
      final s = store.sessions.firstWhere((x) => x.extra?['импорт_ключ'] == key || (i == 0 && x.id == 'old1'));
      expect(s.shots.length, h['n_shots']);
      expect(s.totalScore, closeTo((h['total'] as num).toDouble(), 0.051), reason: '${rep[i]['file']}');
      if (s.id != 'old1') {
        expect(s.finishedAt!.isAfter(s.startedAt!) || s.finishedAt == s.startedAt, isTrue);
        expect(s.shots.every((x) => x.counts), isTrue);
        expect(s.shots.first.extra?['scatt'], isNotNull, reason: 'показатели выстрела сохранены');
      }
    }
    // повторный импорт — ничего нового
    for (final r in parsedAll) {
      expect(SessionImport.apply(store, bundleOf(r)), 0);
    }
    expect(store.sessions.length, rep.length);
    expect([air.id, prone.id, three.id].every((id) => store.exercises.any((e) => e.id == id)), isTrue);
  }, skip: have ? false : 'нет папки с отчётами', timeout: const Timeout(Duration(minutes: 3)));
}
