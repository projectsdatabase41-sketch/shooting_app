import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/starter_exercises.dart';
import 'package:shooting_app/services/user_profile.dart';
import 'package:shooting_app/state/app_data_store.dart';

void main() {
  test('стартовые упражнения по профилю: винтовка + женщина; один раз; чужие не трогаем', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();

    // профиль не заполнен — ничего
    expect(StarterExercises.seedIfNeeded(store), false);

    UserProfile.save(db, disciplines: ['rifle'], gender: 'f', birthDate: DateTime(2000, 1, 1));
    expect(StarterExercises.seedIfNeeded(store), true);
    final list = store.activeExercises;
    expect(list.length, 5);
    expect(list.every((e) => e.gender == ExerciseGender.female), true);
    expect(list.any((e) => e.name.contains('3 положения') && e.totalShots == 60), true);
    expect(list.any((e) => e.targetFaceCode == 'rifle_10m' && e.totalShots == 60), true);

    // повторно не создаёт
    expect(StarterExercises.seedIfNeeded(store), false);
    expect(store.activeExercises.length, 5);
  });

  test('мужчина-пистолетчик: 4 упражнения; если уже есть свои — набор не нужен', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    final store = AppDataStore(db)..loadAll();
    UserProfile.save(db, disciplines: ['pistol'], gender: 'm', birthDate: DateTime(1990, 5, 5));
    StarterExercises.seedIfNeeded(store);
    expect(store.activeExercises.length, 4);

    final db2 = LocalDbService();
    await db2.open(overridePath: ':memory:');
    final store2 = AppDataStore(db2)..loadAll();
    store2.createExercise(name: 'Моё', targetFaceCode: 'rifle_10m', totalShots: 10, seriesSize: 10);
    UserProfile.save(db2, disciplines: ['rifle'], gender: 'm', birthDate: DateTime(1990, 5, 5));
    expect(StarterExercises.seedIfNeeded(store2), false);
    expect(store2.activeExercises.length, 1);
  });
}
