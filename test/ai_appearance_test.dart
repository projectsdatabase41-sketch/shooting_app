import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/ai_service.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/theme/backdrop_tint.dart';

void main() {
  test('блок appearance: валидный выделяется, негодный отбрасывается', () {
    final ok = AiService.splitAppearance('Готово.\n```appearance\n{"blur":0.3,"mode":"manual","hue":200}\n```');
    expect(ok.$1, 'Готово.');
    expect(ok.$2, {'blur': 0.3, 'mode': 'manual', 'hue': 200});
    expect(AiService.splitAppearance('x ```appearance {"blur":5}```').$2, isNull);
    expect(AiService.splitAppearance('x ```appearance {"evil":0.1}```').$2, isNull);
    expect(AiService.splitAppearance('x ```appearance {}```').$2, isNull);
  });

  test('применение и откат настроек оформления', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    BackdropTint.save(db, newBlur: 3, newMask: 0.65);
    final before = BackdropTint.applyAppearance(db, {'blur': 1.0, 'transparency': 1.0});
    expect(BackdropTint.blur, 30);
    expect(BackdropTint.mask, 0);
    BackdropTint.restoreAppearance(db, before);
    expect(BackdropTint.blur, closeTo(3, 0.5));
    expect(BackdropTint.mask, closeTo(0.65, 0.01));
  });
}
