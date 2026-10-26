import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/models/training_session.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/state/app_data_store.dart';

TrainingSession _s(String id, String ex) => TrainingSession(
      id: id,
      exerciseId: ex,
      targetFaceCode: 'rifle_10m',
      status: SessionStatus.finished,
      startedAt: DateTime(2026, 10, 1),
      shots: [Shot(id: '$id-1', shotNumber: 1, seriesNo: 1, xMm: 0, yMm: 0, score: 10, time: DateTime(2026, 10, 1))],
    );

void main() {
  test('пол в названии не показывается (он в профиле), само название не меняется', () {
    expect(Exercise.stripGender('ВП-60, мужчины'), 'ВП-60');
    expect(Exercise.stripGender('МВ 3х20, мужчины'), 'МВ 3х20');
    expect(Exercise.stripGender('Пневматика (женщины)'), 'Пневматика');
    expect(Exercise.stripGender('ВП 10 м, стоя'), 'ВП 10 м, стоя');
    expect(Exercise.stripGender('мужчины'), 'мужчины'); // пустым название не бывает
  });

  test('переименование и объединение: тренировки переходят, второе упражнение скрыто', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();
    final a = store.createExercise(name: 'ВП-60, мужчины', targetFaceCode: 'rifle_10m', totalShots: 60, seriesSize: 10);
    final b = store.createExercise(name: 'Пневматика', targetFaceCode: 'rifle_10m', totalShots: 60, seriesSize: 10);
    store.upsertSession(_s('s1', a.id));
    store.upsertSession(_s('s2', a.id));
    store.upsertSession(_s('s3', b.id));

    store.renameExercise(b.id, 'ВП 10 м, 60');
    expect(store.exerciseForId(b.id)!.name, 'ВП 10 м, 60');

    expect(store.mergeExercises(a.id, b.id), 2);
    expect(store.sessions.where((s) => s.exerciseId == b.id).length, 3);
    expect(store.sessions.where((s) => s.exerciseId == a.id), isEmpty);
    expect(store.activeExercises.map((e) => e.id), [b.id]);
    expect(store.mergeExercises(b.id, b.id), 0);
  });
}
