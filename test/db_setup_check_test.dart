import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/db_setup_check.dart';

void main() {
  final sql = File('lib/db/nexus_personal_db.sql').readAsStringSync().toLowerCase();

  test('установочный SQL создаёт каждую таблицу и функцию из проверки', () {
    for (final t in DbSetupCheck.tables) {
      expect(sql.contains('create table if not exists $t') || sql.contains('create table if not exists public.$t'), true, reason: 'нет таблицы $t');
    }
    for (final f in DbSetupCheck.functions) {
      expect(sql.contains('function $f(') || sql.contains('function public.$f('), true, reason: 'нет функции $f');
    }
  });

  test('SQL идемпотентный: нет голых create table без if not exists', () {
    expect(RegExp(r'create table (?!if not exists)').hasMatch(sql), false);
  });

  test('SQL Editor: адрес по ref проекта; свои домены не угадываем', () {
    expect(DbSetupCheck.sqlEditorUri('https://abcdxyz.supabase.co')!.toString(), 'https://supabase.com/dashboard/project/abcdxyz/sql/new');
    expect(DbSetupCheck.sqlEditorUri('https://my.host.com'), isNull);
  });

  test('«нет такой таблицы» распознаётся по кодам PostgREST', () {
    expect(DbSetupCheck.isMissing(404, ''), true);
    expect(DbSetupCheck.isMissing(400, '{"code":"PGRST202"}'), true);
    expect(DbSetupCheck.isMissing(200, '[]'), false);
    expect(DbSetupCheck.isMissing(403, '{"message":"permission"}'), false);
  });
}
