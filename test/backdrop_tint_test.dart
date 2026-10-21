import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/services/local_db_service.dart';
import 'package:shooting_app/theme/backdrop_tint.dart';

List<double> _apply(List<double> m, List<double> rgb) => [
      for (var i = 0; i < 3; i++) m[i * 5] * rgb[0] + m[i * 5 + 1] * rgb[1] + m[i * 5 + 2] * rgb[2],
    ];

void main() {
  test('матрица оттенка: без сдвига — тождество; сдвиг на 120° перекрашивает синий в красный; яркость сохраняется', () {
    final id = BackdropTint.matrix(0, 1);
    final c = _apply(id, [0.2, 0.4, 0.8]);
    expect(c[0], closeTo(0.2, 1e-6));
    expect(c[2], closeTo(0.8, 1e-6));
    final shifted = _apply(BackdropTint.matrix(120, 1), [0, 0, 1]);
    expect(shifted[0], greaterThan(shifted[1]));
    expect(shifted[0], greaterThan(shifted[2]));
    double lum(List<double> v) => 0.213 * v[0] + 0.715 * v[1] + 0.072 * v[2];
    expect(lum(shifted), closeTo(lum([0, 0, 1]), 5e-3));
    // насыщенность 0 — серый
    final gray = _apply(BackdropTint.matrix(0, 0), [0.1, 0.5, 0.9]);
    expect(gray[0], closeTo(gray[1], 1e-6));
    expect(gray[1], closeTo(gray[2], 1e-6));
  });

  test('режимы: исходный, ручной, авто по пресету; золотые фоны не перекрашиваются', () async {
    final db = LocalDbService();
    await db.open(overridePath: ':memory:');
    BackdropTint.save(db, newMode: 'auto');
    BackdropTint.setAccent(null, null);
    expect(BackdropTint.filter.value, isNull); // пресет не выбран — картинки как есть
    BackdropTint.setAccent(const Color(0xFF4B5320), const Color(0xFFEDEAE0)); // «Хаки»
    expect(BackdropTint.filter.value, isNotNull);
    BackdropTint.setAccent(const Color(0xFF34302B), const Color(0xFF808080)); // серое всё — приглушение
    expect(BackdropTint.filter.value, isNotNull);
    BackdropTint.save(db, newMode: 'off');
    expect(BackdropTint.filter.value, isNull);
    BackdropTint.save(db, newMode: 'manual', newHue: BackdropTint.baseHue, newSat: 1.0);
    expect(BackdropTint.filter.value, isNull); // ручной режим без изменений
    BackdropTint.save(db, newHue: 300);
    expect(BackdropTint.filter.value, isNotNull);
    // сохранение и загрузка
    BackdropTint.mode = 'auto';
    BackdropTint.hue = 0;
    BackdropTint.load(db);
    expect(BackdropTint.mode, 'manual');
    expect(BackdropTint.hue, 300);
    expect(BackdropTint.exempt.contains('champions') && BackdropTint.exempt.contains('finals'), isTrue);
    BackdropTint.save(db, newMode: 'auto');
    BackdropTint.setAccent(null, null);
  });
}
