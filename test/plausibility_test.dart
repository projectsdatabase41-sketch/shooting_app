import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/plausibility.dart';

void main() {
  final train = [for (var i = 0; i < 100; i++) 9.0 + (i % 5) * 0.2]; // ~9.4 ± 0.28
  test('мало данных — неизвестно', () {
    expect(checkPlausibility(train.take(10).toList(), List.filled(24, 10.0)), Plausibility.unknown);
  });
  test('обычный финал — ок', () {
    expect(checkPlausibility(train, List.filled(24, 9.5)), Plausibility.ok);
  });
  test('сильно лучше тренировок — подозрительно', () {
    expect(checkPlausibility(train, List.filled(24, 10.5)), Plausibility.suspicious);
  });
}
