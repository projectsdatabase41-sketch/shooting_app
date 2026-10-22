import '../models/exercise.dart';
import '../state/app_data_store.dart';
import 'local_db_service.dart';
import 'user_profile.dart';

/// Стартовый набор упражнений по профилю (вид стрельбы и пол): при первом
/// открытии «Тренировки», если список пуст, заводятся типовые программы. Всё это
/// обычные упражнения — их можно изменить и удалить. Выполняется один раз.
class StarterExercises {
  StarterExercises._();

  static const _doneKey = 'starter_exercises_done';

  /// (название, код мишени, выстрелов, в серии, для кого).
  static List<({String name, String face, int shots, int series, ExerciseGender gender})> catalog(
      List<String> disciplines, String gender) {
    final g = gender == 'f' ? ExerciseGender.female : ExerciseGender.male;
    final out = <({String name, String face, int shots, int series, ExerciseGender gender})>[];
    void add(String name, String face, int shots, int series) =>
        out.add((name: name, face: face, shots: shots, series: series, gender: g));

    if (disciplines.contains('rifle')) {
      add(/*tr*/ 'Пневматическая винтовка 10 м — 60 выстрелов', 'rifle_10m', 60, 10);
      add(/*tr*/ 'Пневматическая винтовка 10 м — 40 выстрелов', 'rifle_10m', 40, 10);
      add(/*tr*/ 'Пневматическая винтовка 10 м — 10 выстрелов (разминка)', 'rifle_10m', 10, 10);
      add(/*tr*/ 'Винтовка 50 м, лёжа — 60 выстрелов', 'rifle_50m', 60, 10);
      // 3 положения: мужчины 3×40, женщины 3×20.
      add(gender == 'f' ? /*tr*/ 'Винтовка 50 м, 3 положения — 60 выстрелов' : /*tr*/ 'Винтовка 50 м, 3 положения — 120 выстрелов',
          'rifle_50m', gender == 'f' ? 60 : 120, 10);
    }
    if (disciplines.contains('pistol')) {
      add(/*tr*/ 'Пневматический пистолет 10 м — 60 выстрелов', 'pistol_10m', 60, 10);
      add(/*tr*/ 'Пневматический пистолет 10 м — 40 выстрелов', 'pistol_10m', 40, 10);
      add(/*tr*/ 'Пневматический пистолет 10 м — 10 выстрелов (разминка)', 'pistol_10m', 10, 10);
      add(/*tr*/ 'Пистолет 25 м — 60 выстрелов', 'pistol_25m', 60, 5);
    }
    return out;
  }

  /// Пол по названию стартового упражнения: только «3 положения» различается у мужчин и
  /// женщин. Для упражнений из облака, где пол ещё не сохранялся. Иначе — `null`.
  static ExerciseGender? genderOfName(String name) {
    if (name == 'Винтовка 50 м, 3 положения — 60 выстрелов') return ExerciseGender.female;
    if (name == 'Винтовка 50 м, 3 положения — 120 выстрелов') return ExerciseGender.male;
    return null;
  }

  /// Заводит набор, если пора. `true` — упражнения созданы.
  static bool seedIfNeeded(AppDataStore store) {
    final db = store.db;
    if (_get(db) == '1') return false;
    if (store.activeExercises.isNotEmpty) {
      _put(db); // пользователь уже завёл свои — набор не нужен
      return false;
    }
    final disciplines = UserProfile.disciplinesOf(db);
    final gender = UserProfile.genderOf(db);
    if (disciplines.isEmpty || (gender != 'm' && gender != 'f')) return false; // профиль ещё не заполнен
    final items = catalog(disciplines, gender);
    if (items.isEmpty) return false;
    // в обратном порядке: createExercise кладёт новое в начало списка
    for (final e in items.reversed) {
      store.createExercise(
        name: e.name,
        targetFaceCode: e.face,
        totalShots: e.shots,
        seriesSize: e.series,
        gender: e.gender,
      );
    }
    _put(db);
    return true;
  }

  static String? _get(LocalDbService db) {
    final r = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [_doneKey]);
    return r.isEmpty ? null : '${r.first['hex']}';
  }

  static void _put(LocalDbService db) => db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex', [_doneKey, '1']);
}
