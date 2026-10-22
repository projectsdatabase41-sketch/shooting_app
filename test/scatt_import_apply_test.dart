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

  test('отчёт PDF → тренировка в базе; повторный импорт дублей не создаёт', () async {
    final f = dir.listSync().whereType<File>().firstWhere((e) => e.path.endsWith('.pdf'));
    final r = scattTryParse(Uint8List.fromList(f.readAsBytesSync()));
    expect(r['ok'], isTrue);
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();
    ImportBundle bundle() => SessionImport.parse(jsonEncode({
          'format': SessionImport.formatId,
          'version': SessionImport.supportedVersion,
          'source': 'SCATT (PDF)',
          'sessions': [r['session']],
        }));
    expect(SessionImport.alreadyHave(store, bundle().sessions.first), isFalse);
    expect(SessionImport.apply(store, bundle()), 1);
    expect(store.sessions.length, 1);
    final s = store.sessions.first;
    expect(s.shots.length, r['n_shots']);
    expect(s.totalScore, closeTo((r['total'] as num).toDouble(), 0.051));
    expect(store.exercises.any((e) => e.name == r['exercise']), isTrue);
    // второй раз — то же самое: ничего не добавляется
    expect(SessionImport.apply(store, bundle()), 0);
    expect(store.sessions.length, 1);
  }, skip: dir.existsSync() ? false : 'нет папки с отчётами');
}
