import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/shot.dart';
import 'package:shooting_app/widgets/target_canvas.dart';

Shot _shot(int n, double x, double y) =>
    Shot(id: '$n', shotNumber: n, seriesNo: 1, xMm: x, yMm: y, score: 0, time: DateTime(2026));

void main() {
  test('касание выбирает ближайший выстрел', () {
    final shots = [_shot(1, 0, 0), _shot(2, 10, 10), _shot(3, -5, 2)];
    expect(nearestShotIndex(shots, 9, 8), 1);
    expect(nearestShotIndex(shots, -4, 1), 2);
    expect(nearestShotIndex(const [], 0, 0), -1);
  });
}
