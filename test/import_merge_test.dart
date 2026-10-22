import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/i18n/known_names.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/training_session.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/session_import.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  test('лишнее упражнение от импорта сливается с подходящим своим: тренировки переезжают, лишнее удаляется', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();
    final mine = store.createExercise(name: 'Винтовка 50 м, лёжа — 60 выстрелов', targetFaceCode: 'rifle_50m', totalShots: 60, seriesSize: 10);
    final extra = store.createExercise(name: 'МВ 50 м, лёжа', targetFaceCode: 'rifle_50m', totalShots: 20, seriesSize: 10);
    final other = store.createExercise(name: 'Пневматическая винтовка 10 м — 60 выстрелов', targetFaceCode: 'rifle_10m', totalShots: 60, seriesSize: 10);
    store.upsertSession(TrainingSession(
        id: 's1',
        exerciseId: extra.id,
        targetFaceCode: 'rifle_50m',
        status: SessionStatus.finished,
        startedAt: DateTime(2026, 7, 13, 16),
        shots: [Shot(id: 'x1', shotNumber: 1, seriesNo: 1, xMm: 0, yMm: 0, score: 10.0, time: DateTime(2026, 7, 13, 16))]));
    final merges = SessionImport.plannedMerges(store, scattExerciseNames.toSet());
    expect(merges.length, 1);
    expect(merges.single.$1.id, extra.id);
    expect(merges.single.$2.id, mine.id);
    expect(SessionImport.applyMerges(store, merges), 1);
    expect(store.sessions.single.exerciseId, mine.id);
    // и в базе: после перезагрузки тренировка осталась у нового упражнения
    final reloaded = AppDataStore(db)..loadAll();
    expect(reloaded.sessions.single.exerciseId, mine.id);
    expect(store.exercises.any((e) => e.id == extra.id), isFalse);
    expect(store.exercises.any((e) => e.id == other.id), isTrue);
  });
}
