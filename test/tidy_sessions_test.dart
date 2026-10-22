import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/training_session.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

TrainingSession session(String id, String exId, DateTime at, {int n = 3, double score = 10.0, Map<String, dynamic>? extra, bool scatt = false}) => TrainingSession(
      id: id,
      exerciseId: exId,
      targetFaceCode: 'rifle_10m',
      status: SessionStatus.finished,
      startedAt: at,
      extra: extra,
      shots: [for (var i = 0; i < n; i++) Shot(id: '$id-$i', shotNumber: i + 1, seriesNo: 1, xMm: 0, yMm: 0, score: score, time: at, extra: scatt ? {'scatt': {}} : null)],
    );

void main() {
  test('порядок: дубли (в т.ч. со сдвигом часов) и пустые убираются, остаётся занесённая из отчёта', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();
    final ex = store.createExercise(name: 'ВП', targetFaceCode: 'rifle_10m', totalShots: 10, seriesSize: 10);
    final t = DateTime(2026, 9, 10, 12, 57);
    store.upsertSession(session('qwen', ex.id, t.add(const Duration(hours: 5))));
    store.upsertSession(session('pdf', ex.id, t, extra: {'импорт_ключ': 'k'}, scatt: true));
    store.upsertSession(session('other', ex.id, DateTime(2026, 9, 11), score: 9.0)); // другая тренировка
    store.upsertSession(session('sameDayDifferentSum', ex.id, t, score: 8.0));
    expect(store.tidySessions(), 1);
    expect(store.sessions.map((s) => s.id).toSet(), {'pdf', 'other', 'sameDayDifferentSum'});
    expect(store.tidySessions(), 0, reason: 'повторный проход ничего не меняет');
  });
}
