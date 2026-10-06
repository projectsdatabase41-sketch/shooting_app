import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/logic/friendly_error.dart';
import 'package:shooting_app/logic/scoring.dart';
import 'package:shooting_app/models/target_face.dart';

// Размеры — World Archery Book 3 / Bylaw 8.2.1: 10 равных зон, диаметр
// десятки = размер_мишени / 10, внутренняя десятка (X) вдвое меньше.
void main() {
  TargetFace f(String c) => TargetFace.byCode(c);

  test('диаметры колец: внешнее кольцо = размер мишени, зоны равны', () {
    const sizes = {
      'archery_122': 1220.0,
      'archery_80': 800.0,
      'archery_60': 600.0,
      'archery_40': 400.0,
    };
    sizes.forEach((code, size) {
      final d = f(code).ringDiametersMm;
      expect(d.length, 10, reason: code);
      expect(d.last, size, reason: code);
      expect(d.first, size / 10, reason: code);
      expect(f(code).innerTenDiameterMm, size / 20, reason: code);
      expect(f(code).ringWidthMm, size / 20, reason: code);
    });
  });

  test('шестиколечная 80 см: кольца 10..5, внешнее 480 мм', () {
    final d = f('archery_80_6').ringDiametersMm;
    expect(d, [80, 160, 240, 320, 400, 480]);
  });

  test('тройная 40 см: 5 колец; компаунд — десятка 20 мм', () {
    expect(f('archery_40_3').ringDiametersMm, [40, 80, 120, 160, 200]);
    expect(f('archery_40_3_c').ringDiametersMm, [20, 80, 120, 160, 200]);
    expect(f('archery_40_c').ringDiametersMm.first, 20);
    expect(f('archery_60_c').ringDiametersMm.first, 30);
  });

  test('целые очки, касание линии стрелой = высшая зона', () {
    final face = f('archery_80'); // кольцо 10: радиус 40 мм, стрела 5.5 мм
    expect(scoreForRadius(0, face), 10);
    // центр стрелы на 42.75: ближний край ровно на линии 10 (40) → 10
    expect(scoreForRadius(42.75, face), 10);
    expect(scoreForRadius(42.8, face), 9);
    expect(scoreForRadius(100, face), 8);
    expect(scoreForRadius(400, face), 1);
    expect(scoreForRadius(500, face), 0);
  });

  test('шестиколечная: за кольцом 5 — промах; X по внутренней десятке', () {
    final face = f('archery_80_6');
    expect(scoreForRadius(100, face), 8);
    expect(scoreForRadius(238, face), 5);
    expect(scoreForRadius(250, face), 0);
    expect(isInnerTen(0, face), isTrue);
    expect(isInnerTen(22.75, face), isTrue); // край на 20.0
    expect(isInnerTen(23, face), isFalse);
  });

  test('компаунд 40 см: десятка только внутри 20 мм, остальное — девятка', () {
    final face = f('archery_40_c');
    expect(scoreForRadius(5, face), 10);
    expect(scoreForRadius(30, face), 9);
    expect(scoreForRadius(45, face), 8);
  });

  test('лук скрыт вне режима разработчика, выбранный остаётся', () {
    friendlyErrorDevMode = false;
    expect(TargetFace.selectable().any((e) => e.isArchery), isFalse);
    expect(TargetFace.selectable(keep: 'archery_40').map((e) => e.code), contains('archery_40'));
    friendlyErrorDevMode = true;
    expect(TargetFace.selectable().any((e) => e.isArchery), isTrue);
    friendlyErrorDevMode = false;
  });

  test('биатлон: одна зона, попал/мимо, скрыт вне режима разработчика', () {
    final prone = f('biathlon_prone');
    expect(prone.ringDiametersMm, [45]);
    expect(f('biathlon_standing').ringDiametersMm, [115]);
    expect(scoreForRadius(0, prone), 10);
    expect(scoreForRadius(22.5 + 2.8, prone), 10); // край пули на кромке
    expect(scoreForRadius(22.5 + 2.9, prone), 0);
    friendlyErrorDevMode = false;
    expect(TargetFace.selectable().any((e) => e.isBiathlon), isFalse);
  });

  test('коды уникальны и все знает справочник', () {
    final codes = TargetFace.all.map((e) => e.code).toSet();
    expect(codes.length, TargetFace.all.length);
    for (final face in TargetFace.all.where((e) => e.devOnly)) {
      expect(face.integerScoring, isTrue);
      expect(TargetFace.fromJson(face.toJson()).integerScoring, isTrue);
    }
  });
}
