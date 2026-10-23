import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/announcer.dart';

void main() {
  test('«Заряжай» звучит один раз за этап', () {
    final a = PhaseAnnouncer();
    a.update('sighting', secondsLeft: 60, announcing: false);
    a.update('shooting', secondsLeft: 30, announcing: false);
    a.update('grace', secondsLeft: 5, announcing: false);
    final said = <String?>[
      a.update('loading', secondsLeft: 20, announcing: false),
      a.update('loading', secondsLeft: 19, announcing: false),
      a.update('loading', secondsLeft: 18, announcing: false),
    ];
    expect(said.where((s) => s == 'Заряжай.').length, 1);
  });
}
