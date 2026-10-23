import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/round_label.dart';

void main() {
  test('подписи раундов: у 50 м — положение, у остальных — номер', () {
    expect(finalRoundLabel('rifle_3p_50m', 'series:1'), 'Колено, серия 1 из 3');
    expect(finalRoundLabel('rifle_3p_50m', 'series:5'), 'Лёжа, серия 2 из 3');
    expect(finalRoundLabel('rifle_3p_50m', 'series:8'), 'Стоя, серия 2 из 2');
    expect(finalRoundLabel('air_rifle_10m', 'series:2'), 'Серия 2');
    expect(finalRoundLabel('rifle_3p_50m', 'single:3'), 'Выстрел 3');
  });
}
