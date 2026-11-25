import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Положение стрелка для значка упражнения (отзыв a69f8d83, уточнён 25.11):
/// фигуры читаемые, как пиктограммы SCATT — человек с оружием, а не набор
/// линий. [allThree] — три положения в один ряд: лёжа, с колена, стоя.
enum StanceKind { standing, kneeling, prone, allThree }

/// Оружие: винтовка — длинный ствол; пистолет — короткий, у вытянутой руки.
enum WeaponKind { rifle, pistol }

/// Декоративный силуэт стрелка в изготовке. Рисуется простыми, но
/// анатомически узнаваемыми формами: голова, корпус, руки, ноги, оружие.
/// Цвет задаёт вызывающий — цвет плитки из персонализации.
///
/// Геометрия — в виртуальном квадрате 100×100 и масштабируется по [size]:
/// при size <= 0 ничего не рисуется, отрицательных радиусов не возникает.
class StanceIcon extends StatelessWidget {
  final StanceKind stance;
  final WeaponKind weapon;
  final Color color;

  /// Сторона квадратного значка, логические пиксели.
  final double size;

  /// Смысловая подпись для скринридеров — формирует вызывающий.
  final String? semanticLabel;

  const StanceIcon({
    super.key,
    required this.stance,
    required this.weapon,
    required this.color,
    this.size = 24,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    Widget icon = CustomPaint(
      size: Size.square(size),
      painter: _StancePainter(stance: stance, weapon: weapon, color: color),
    );
    if (semanticLabel != null) {
      icon = Semantics(label: semanticLabel, child: icon);
    }
    return SizedBox(width: size, height: size, child: icon);
  }
}

class _StancePainter extends CustomPainter {
  final StanceKind stance;
  final WeaponKind weapon;
  final Color color;

  const _StancePainter({
    required this.stance,
    required this.weapon,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    if (s <= 0) return;
    switch (stance) {
      case StanceKind.standing:
        _figure(canvas, s, const Rect.fromLTWH(0, 0, 100, 100), _drawStanding);
      case StanceKind.kneeling:
        _figure(canvas, s, const Rect.fromLTWH(0, 0, 100, 100), _drawKneeling);
      case StanceKind.prone:
        _figure(canvas, s, const Rect.fromLTWH(0, 0, 100, 100), _drawProne);
      case StanceKind.allThree:
        // Три положения в ряд, без наложений: лёжа снизу слева, с колена в
        // середине, стоя справа. Слоты разнесены, чтобы силуэты не липли.
        _figure(canvas, s, const Rect.fromLTWH(2, 58, 58, 40), _drawProne);
        _figure(canvas, s, const Rect.fromLTWH(34, 34, 50, 62), _drawKneeling);
        _figure(canvas, s, const Rect.fromLTWH(60, 2, 40, 96), _drawStanding);
    }
  }

  /// Рисует фигуру в прямоугольник [box] (координаты базовой сетки 0..100).
  void _figure(Canvas canvas, double s, Rect box, void Function(Canvas, _Ink) draw) {
    final basis = s / 100.0; // виртуальная единица → пиксели
    final m = math.min(box.width, box.height) / 100.0; // фигура → её слот
    if (m <= 0) return;
    canvas.save();
    canvas.translate(box.left * basis, box.top * basis);
    canvas.scale(basis * m);
    draw(canvas, _Ink(color));
    canvas.restore();
  }

  // ---- Позы (сетка 100×100, стрелок смотрит вправо) ---------------------

  void _drawStanding(Canvas canvas, _Ink ink) {
    // Ноги: устойчивая стойка, ступни чуть в стороны.
    ink.limb(canvas, 46, 56, 40, 88, 9);
    ink.limb(canvas, 54, 56, 62, 88, 9);
    ink.limb(canvas, 40, 88, 35, 91, 7);
    ink.limb(canvas, 62, 88, 67, 91, 7);
    // Корпус и голова.
    ink.limb(canvas, 50, 30, 50, 58, 13);
    ink.head(canvas, 47, 18, 8.5);
    // Оружие и руки.
    if (weapon == WeaponKind.rifle) {
      ink.limb(canvas, 22, 40, 88, 32, 5); // винтовка
      ink.limb(canvas, 46, 36, 60, 32, 6); // рука к цевью
      ink.limb(canvas, 52, 34, 44, 40, 6); // рука к прикладу
    } else {
      ink.limb(canvas, 50, 32, 78, 25, 8); // вытянутая рука
      _pistol(canvas, ink, 78, 25, 0.55);
    }
  }

  void _drawKneeling(Canvas canvas, _Ink ink) {
    // Передняя нога согнута, задняя стоит на КОЛЕНЕ (колено — на земле).
    ink.limb(canvas, 48, 58, 66, 68, 9); // бедро передней
    ink.limb(canvas, 66, 68, 66, 89, 8); // голень передней
    ink.limb(canvas, 66, 89, 73, 91, 6); // ступня
    ink.limb(canvas, 46, 58, 32, 84, 9); // бедро задней — вниз к земле
    ink.head(canvas, 30, 86, 4.5); // само колено на земле
    ink.limb(canvas, 30, 86, 14, 88, 8); // голень лежит назад
    // Корпус и голова.
    ink.limb(canvas, 48, 32, 48, 58, 12);
    ink.head(canvas, 46, 20, 8);
    if (weapon == WeaponKind.rifle) {
      ink.limb(canvas, 20, 44, 88, 36, 5); // винтовка
      ink.limb(canvas, 44, 40, 58, 36, 6); // рука
    } else {
      ink.limb(canvas, 48, 34, 74, 27, 8);
      _pistol(canvas, ink, 74, 27, 0.55);
    }
  }

  void _drawProne(Canvas canvas, _Ink ink) {
    // Тело вдоль земли; голова — отдельно впереди, ноги — отдельно сзади:
    // раньше всё сливалось в один горизонтальный брус и человек не читался.
    ink.head(canvas, 74, 54, 7.5); // голова
    ink.limb(canvas, 68, 58, 64, 62, 6); // шея
    ink.limb(canvas, 64, 62, 34, 68, 9); // корпус — тоньше, чтобы не «бревно»
    ink.limb(canvas, 34, 68, 20, 74, 7); // бедро
    ink.limb(canvas, 20, 74, 8, 80, 7); // голень
    ink.limb(canvas, 36, 68, 24, 82, 6); // вторая нога отдельной линией
    if (weapon == WeaponKind.rifle) {
      ink.limb(canvas, 50, 50, 96, 47, 4.5); // винтовка над телом
      ink.limb(canvas, 58, 72, 63, 56, 6); // локоть-упор к земле
    } else {
      ink.limb(canvas, 68, 56, 84, 50, 7);
      _pistol(canvas, ink, 84, 50, 0.5);
    }
  }

  /// Пистолет: короткий ствол и рукоять вниз — иначе он не отличается от
  /// просто вытянутой руки (замечание по превью значков, 25.11).
  void _pistol(Canvas canvas, _Ink ink, double x, double y, double k) {
    ink.limb(canvas, x, y, x + 14 * k, y - 2 * k, 5); // ствол
    ink.limb(canvas, x + 2 * k, y + 1, x + 2 * k, y + 9 * k, 6); // рукоять
  }

  @override
  bool shouldRepaint(_StancePainter oldDelegate) =>
      oldDelegate.stance != stance ||
      oldDelegate.weapon != weapon ||
      oldDelegate.color != color;
}

/// Мелкие помощники рисования: толстые скруглённые линии и голова.
class _Ink {
  final Color color;
  _Ink(this.color);

  Paint get _paint => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  /// Конечность/оружие: линия толщиной [w] (в единицах сетки 100).
  void limb(Canvas canvas, double x1, double y1, double x2, double y2, double w) {
    canvas.drawLine(Offset(x1, y1), Offset(x2, y2), _paint..strokeWidth = w);
  }

  /// Голова — залитый круг.
  void head(Canvas canvas, double x, double y, double r) {
    canvas.drawCircle(Offset(x, y), r, Paint()..color = color);
  }
}
