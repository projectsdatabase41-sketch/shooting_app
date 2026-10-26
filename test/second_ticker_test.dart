import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/finals/second_ticker.dart';

void main() {
  test('секундомер: считает целые секунды по часам и догоняет пропущенные — минуты не растягиваются', () {
    var t = Duration.zero;
    var n = 0;
    final tk = SecondTicker(() => n++, now: () => t);
    tk.start();
    t = const Duration(milliseconds: 900);
    tk.poll();
    expect(n, 0);
    t = const Duration(milliseconds: 3400); // таймер «подвис» и пропустил срабатывания
    tk.poll();
    expect(n, 3);
    t = const Duration(milliseconds: 3900);
    tk.poll();
    expect(n, 3);
    t = const Duration(milliseconds: 4100);
    tk.poll();
    expect(n, 4);
    // 5 минут реального времени = ровно 300 секунд, как бы ни дробились замеры
    for (var ms = 4200; ms <= 300000; ms += 777) {
      t = Duration(milliseconds: ms);
      tk.poll();
    }
    t = const Duration(seconds: 300);
    tk.poll();
    expect(n, 300);
    tk.cancel();
  });

  test('слишком долгий сон не перематывает финал: догоняется не больше maxCatchUp секунд', () {
    var t = Duration.zero;
    var n = 0;
    final tk = SecondTicker(() => n++, now: () => t, maxCatchUp: 30)..start();
    t = const Duration(hours: 2);
    tk.poll();
    expect(n, 30);
    tk.cancel();
  });
}
