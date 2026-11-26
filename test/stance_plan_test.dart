import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/stance_plan.dart';
import 'package:shooting_app/models/exercise.dart';
import 'package:shooting_app/widgets/stance_icon.dart';

Exercise _ex(String name, String face, int shots, int seriesSize) => Exercise(
      id: 'e',
      name: name,
      targetFaceCode: face,
      totalShots: shots,
      seriesSize: seriesSize,
    );

void main() {
  test('3 положения: порядок ISSF — с колена, лёжа, стоя', () {
    final plan = StancePlan.forExercise(
        _ex('Винтовка 50 м, 3 положения — 120 выстрелов', 'rifle_50m', 120, 10));
    expect(plan.threePositions, isTrue);
    expect(plan.bySeries.length, 12);
    expect(plan.stanceFor(1), StanceKind.kneeling);
    expect(plan.stanceFor(4), StanceKind.kneeling);
    expect(plan.stanceFor(5), StanceKind.prone);
    expect(plan.stanceFor(9), StanceKind.standing);
    expect(plan.stanceFor(12), StanceKind.standing);
    expect(plan.orderHint, contains('колена'));
    expect(plan.weapon, WeaponKind.rifle);
  });

  test('50 м лёжа — одна изготовка на все серии', () {
    final plan = StancePlan.forExercise(
        _ex('Винтовка 50 м, лёжа — 60 выстрелов', 'rifle_50m', 60, 10));
    expect(plan.threePositions, isFalse);
    expect(plan.bySeries.every((s) => s == StanceKind.prone), isTrue);
    expect(plan.orderHint, 'Лёжа');
  });

  test('пистолет — стоя и признак оружия pistol', () {
    final plan = StancePlan.forExercise(
        _ex('Пневматический пистолет 10 м — 60 выстрелов', 'pistol_10m', 60, 10));
    expect(plan.weapon, WeaponKind.pistol);
    expect(plan.stanceFor(1), StanceKind.standing);
  });

  test('подсказка при выборе мишени', () {
    expect(StancePlan.hintForFace('rifle_50m'), contains('с колена'));
    expect(StancePlan.hintForFace('rifle_10m'), contains('стоя'));
    expect(StancePlan.hintForFace('pistol_10m'), contains('стоя'));
  });
}
