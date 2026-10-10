import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/user_profile.dart';

void main() {
  test('профиль: сохраняется, новым пользователям анкета нужна, старым — нет', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    expect(UserProfile.needsOnboarding(db), isTrue);
    UserProfile.save(db, disciplines: ['pistol', 'rifle'], gender: 'f', birthYear: 2008, rank: '2 разряд', region: ' Москва ');
    expect(UserProfile.needsOnboarding(db), isFalse);
    expect(UserProfile.disciplinesOf(db), ['pistol', 'rifle']);
    expect(UserProfile.genderOf(db), 'f');
    expect(UserProfile.birthYearOf(db), 2008);
    expect(UserProfile.rankOf(db), '2 разряд');
    expect(UserProfile.regionOf(db), 'Москва');

    final old = LocalDbService();
    await old.open(overridePath: ':memory:');
    old.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('home_tabs_visible_athlete', 'x')");
    expect(UserProfile.needsOnboarding(old), isFalse);
  });
}
