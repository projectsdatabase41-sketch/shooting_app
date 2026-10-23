import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/services/user_profile.dart';

void main() {
  test('упражнения по профилю: вид стрельбы и пол', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    // профиль пуст — подходит всё
    expect(UserProfile.exerciseRelevant(db, 'pistol_10m', 'female'), isTrue);
    db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('profile_disciplines', 'rifle')");
    db.db.execute("INSERT INTO color_prefs (key, hex) VALUES ('profile_gender', 'm')");
    expect(UserProfile.exerciseRelevant(db, 'rifle_10m', 'mixed'), isTrue);
    expect(UserProfile.exerciseRelevant(db, 'rifle_50m', 'male'), isTrue);
    expect(UserProfile.exerciseRelevant(db, 'rifle_50m', 'female'), isFalse);
    expect(UserProfile.exerciseRelevant(db, 'pistol_10m', 'mixed'), isFalse);
  });
}
