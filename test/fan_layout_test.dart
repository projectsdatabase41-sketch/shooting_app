import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/fan_menu.dart';

/// Веер у кнопки «+» в поле ввода чата уходил за нижний край экрана
/// (отзыв от 02.11.2026): пункт на «7 часов» оказывался под экраном.
/// Здесь проверяется геометрия, а не отрисовка: все пункты обязаны
/// попадать в безопасную область и не залезать под клавиатуру.
void main() {
  const itemSize = 50.0;
  const phone = Size(400, 800);

  bool inside(Offset p, Size screen, EdgeInsets safe, double keyboard,
      {double margin = 8}) {
    return p.dx >= safe.left + margin + itemSize / 2 - 0.01 &&
        p.dx <= screen.width - safe.right - margin - itemSize / 2 + 0.01 &&
        p.dy >= safe.top + margin + itemSize / 2 - 0.01 &&
        p.dy <= screen.height - safe.bottom - keyboard - margin - itemSize / 2 + 0.01;
  }

  List<Offset> layout({
    required Offset center,
    Size screen = phone,
    EdgeInsets safe = const EdgeInsets.only(top: 24, bottom: 16),
    double keyboard = 0,
    int count = 5,
    bool mirror = false,
  }) =>
      FanLayout.offsets(
        center: center,
        screen: screen,
        safe: safe,
        keyboard: keyboard,
        itemSize: itemSize,
        count: count,
        mirror: mirror,
      );

  test('кнопка внизу экрана: все пункты выше нижнего края', () {
    final center = const Offset(330, 720); // «+» в поле ввода
    final offs = layout(center: center);
    expect(offs.length, 5);
    for (final o in offs) {
      expect(inside(center + o, phone, const EdgeInsets.only(top: 24, bottom: 16), 0),
          isTrue,
          reason: 'пункт $o вылез за экран');
    }
    // Главное из отзыва: ничего не уходит ниже кнопки.
    expect(offs.every((o) => o.dy <= 0.01), isTrue);
  });

  test('открыта клавиатура: пункты не прячутся под ней', () {
    const center = Offset(330, 400);
    final offs = layout(center: center, keyboard: 320);
    for (final o in offs) {
      expect(inside(center + o, phone, const EdgeInsets.only(top: 24, bottom: 16), 320), isTrue,
          reason: 'пункт $o под клавиатурой');
    }
  });

  test('кнопка у верхнего края: веер разворачивается вниз и остаётся на экране', () {
    const center = Offset(60, 90);
    final offs = layout(center: center);
    for (final o in offs) {
      expect(inside(center + o, phone, const EdgeInsets.only(top: 24, bottom: 16), 0), isTrue,
          reason: 'пункт $o вылез за экран');
    }
  });

  test('кнопка у правого края: пункты не уезжают вправо', () {
    const center = Offset(390, 400);
    final offs = layout(center: center);
    for (final o in offs) {
      expect(inside(center + o, phone, const EdgeInsets.only(top: 24, bottom: 16), 0), isTrue);
    }
  });

  test('разное число пунктов и зеркальный веер — всегда в границах', () {
    for (final n in [1, 2, 3, 4, 5, 6, 7]) {
      for (final mirror in [false, true]) {
        final offs = layout(center: const Offset(330, 720), count: n, mirror: mirror);
        expect(offs.length, n);
        for (final o in offs) {
          expect(
              inside(const Offset(330, 720) + o, phone,
                  const EdgeInsets.only(top: 24, bottom: 16), 0),
              isTrue,
              reason: 'n=$n mirror=$mirror пункт $o');
        }
      }
    }
  });

  test('пункты не налезают друг на друга', () {
    final offs = layout(center: const Offset(330, 720));
    for (var i = 1; i < offs.length; i++) {
      expect((offs[i] - offs[i - 1]).distance, greaterThanOrEqualTo(itemSize),
          reason: 'пункты ${i - 1} и $i слишком близко');
    }
  });

  test('большой экран: веер остаётся прежним (дуга 11→7 часов)', () {
    final offs = layout(center: const Offset(900, 600), screen: const Size(1400, 1000));
    expect(offs.length, 5);
    // Крайняя точка дуги — слева-снизу от кнопки, как и было задумано.
    expect(offs.last.dx, lessThan(0));
    expect(offs.last.dy, greaterThan(0));
  });
}
