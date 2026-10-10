import 'local_db_service.dart';

/// Профиль спортсмена: вид стрельбы, пол, год рождения, разряд, регион.
/// Нужен, чтобы подбирать упражнения и нормативы и, позже, для финалов и
/// таблицы чемпионов. Хранится на устройстве; в облако и в общую таблицу
/// уходит только по решению самого пользователя.
class UserProfile {
  UserProfile._();

  static const disciplines = <(String, String)>[
    ('pistol', /*tr*/ 'Пистолет'),
    ('rifle', /*tr*/ 'Винтовка'),
    ('archery', /*tr*/ 'Лук'),
    ('shotgun', /*tr*/ 'Стендовая (дробовик)'),
    ('biathlon', /*tr*/ 'Биатлон'),
    ('ipsc', /*tr*/ 'Практическая (IPSC)'),
  ];

  static const ranks = <String>[
    /*tr*/ 'Нет разряда',
    /*tr*/ '3 юношеский',
    /*tr*/ '2 юношеский',
    /*tr*/ '1 юношеский',
    /*tr*/ '3 разряд',
    /*tr*/ '2 разряд',
    /*tr*/ '1 разряд',
    /*tr*/ 'КМС',
    /*tr*/ 'МС',
    /*tr*/ 'МСМК',
    /*tr*/ 'ЗМС',
  ];

  static const _kDisciplines = 'profile_disciplines';
  static const _kGender = 'profile_gender';
  static const _kYear = 'profile_birth_year';
  static const _kRank = 'profile_rank';
  static const _kRegion = 'profile_region';
  static const _kDone = 'profile_done';
  static const _kSyncOffered = 'profile_sync_offered';

  static String _read(LocalDbService db, String key) {
    final rows = db.db.select('SELECT hex FROM color_prefs WHERE key = ?', [key]);
    return rows.isEmpty ? '' : '${rows.first['hex'] ?? ''}';
  }

  static void _write(LocalDbService db, String key, String value) {
    db.db.execute(
      'INSERT INTO color_prefs (key, hex) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hex = excluded.hex',
      [key, value],
    );
  }

  /// Пользовался ли человек приложением до появления профиля (есть сохранённые
  /// вкладки или тренировки) — таким анкету не навязываем, она в настройках.
  static bool isExistingUser(LocalDbService db) {
    if (_read(db, 'home_tabs_visible_athlete').isNotEmpty ||
        _read(db, 'home_tabs_visible_coach').isNotEmpty) {
      return true;
    }
    final n = db.db.select('SELECT COUNT(*) AS n FROM training_sessions').first['n'] as int;
    return n > 0;
  }

  /// Нужно ли показать обязательную анкету при открытии.
  static bool needsOnboarding(LocalDbService db) =>
      _read(db, _kDone).isEmpty && !isExistingUser(db);

  static List<String> disciplinesOf(LocalDbService db) =>
      _read(db, _kDisciplines).split(',').where((e) => e.isNotEmpty).toList();
  static String genderOf(LocalDbService db) => _read(db, _kGender); // 'm' | 'f'
  static int? birthYearOf(LocalDbService db) => int.tryParse(_read(db, _kYear));
  static String rankOf(LocalDbService db) => _read(db, _kRank);
  static String regionOf(LocalDbService db) => _read(db, _kRegion);

  /// Сохраняет анкету. Обязательны вид стрельбы, пол и год рождения.
  static void save(
    LocalDbService db, {
    required List<String> disciplines,
    required String gender,
    required int birthYear,
    String rank = '',
    String region = '',
  }) {
    assert(disciplines.isNotEmpty && (gender == 'm' || gender == 'f'));
    _write(db, _kDisciplines, disciplines.join(','));
    _write(db, _kGender, gender);
    _write(db, _kYear, '$birthYear');
    _write(db, _kRank, rank);
    _write(db, _kRegion, region.trim());
    _write(db, _kDone, '1');
  }

  /// Предлагали ли уже синхронизацию с облаком (один раз после анкеты).
  static bool syncOffered(LocalDbService db) => _read(db, _kSyncOffered) == '1';
  static void markSyncOffered(LocalDbService db) => _write(db, _kSyncOffered, '1');
}
