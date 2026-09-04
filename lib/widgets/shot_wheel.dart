import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Колесо-барабан: горизонтальная прокрутка с фиксацией по делениям.
///
/// Заменило горизонтальный слайдер десятых (решение пользователя:
/// «не в виде слайдера, а в виде колеса — вид не с торца, а сбоку, с
/// делениями типа эффекта 3д»). Работает в двух режимах, но выглядит и
/// ощущается одинаково:
///
/// - **вне правки** — переход между выстрелами;
/// - **во время правки** — подбор десятой доли результата.
///
/// Направление одинаковое в обоих режимах и задано пользователем:
/// ведём слева направо — идём НАЗАД, справа налево — ВПЕРЁД. Это
/// совпадает с физикой настоящего барабана: толкаешь его переднюю
/// (обращённую к тебе) поверхность вправо — верх уезжает влево.
///
/// ## Как получается «3д»
///
/// Барабан — это цилиндр с вертикальной осью, на который смотрят сбоку.
/// Деление, повёрнутое на угол θ от направления на зрителя, проецируется
/// в `x = R·sin(θ)`, поэтому у краёв деления сгущаются, а у центра идут
/// редко — именно это и читается глазом как объём. Видны только те, у
/// которых `cos(θ) > 0` (передняя половина), и их яркость гасится тем же
/// косинусом, так что деления «уходят за горизонт», а не обрываются.
/// Сверху и снизу цилиндр затемнён вертикальным градиентом — блик
/// посередине, тень к кромкам.
class ShotWheel extends StatefulWidget {
  /// Текущее положение (номер деления). Виджет сам его не хранит.
  final int value;

  /// Границы включительно. Если [minValue] == [maxValue], колесо
  /// показывается, но не крутится.
  final int minValue;
  final int maxValue;

  /// Новое значение после прокрутки на одно или несколько делений.
  final ValueChanged<int> onChanged;

  /// Есть ли чем управлять.
  ///
  /// Когда управлять нечем (в тренировке один выстрел, габарит 0 не
  /// делится на десятые), колесо ВСЁ РАВНО крутится — просто вхолостую,
  /// не меняя значения. Так решил пользователь: приглушённый
  /// неподвижный барабан «бросается в глаза», а свободно вращающийся
  /// выглядит как обычный элемент, которому сейчас нечего листать.
  final bool enabled;

  const ShotWheel({
    super.key,
    required this.value,
    required this.minValue,
    required this.maxValue,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<ShotWheel> createState() => _ShotWheelState();
}

class _ShotWheelState extends State<ShotWheel> {
  /// Сколько пикселей проводит палец на одно деление. Подобрано так,
  /// чтобы промахнуться мимо нужного деления было трудно — это и есть
  /// «низкая чувствительность», о которой просил пользователь.
  static const double _pixelsPerStep = 34.0;

  /// Остаток хода, не дотянувший до целого деления. Копится между
  /// событиями, иначе медленное ведение не двигало бы колесо вовсе.
  double _residual = 0;

  /// Доля деления, на которую барабан довёрнут прямо сейчас (-1..1) —
  /// нужна только для картинки, значение от неё не зависит.
  double get _phase => (_residual / _pixelsPerStep).clamp(-1.0, 1.0);

  void _onDragUpdate(DragUpdateDetails details) {
    _residual += details.delta.dx;

    final rolled = (_residual / _pixelsPerStep).truncate();
    if (rolled != 0) {
      _residual -= rolled * _pixelsPerStep;
      if (widget.enabled) {
        // Слева направо (rolled > 0) — НАЗАД, поэтому вычитаем.
        final next = (widget.value - rolled).clamp(widget.minValue, widget.maxValue);
        if (next != widget.value) {
          widget.onChanged(next);
        } else {
          // Упёрлись в край — не копим ход, иначе колесо «залипает» и
          // потом резко проскакивает при движении обратно.
          _residual = 0;
        }
      }
      // Управлять нечем — деление просто проворачивается вхолостую:
      // остаток уже списан, барабан провернулся, значение не тронуто.
    }
    setState(() {});
  }

  void _onDragEnd(DragEndDetails details) {
    setState(() => _residual = 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: () => setState(() => _residual = 0),
      // Приглушения нет намеренно: колесо выглядит одинаково всегда,
      // просто иногда крутится вхолостую.
      child: SizedBox(
        // Высота уменьшена на 20% (была 66) — по просьбе пользователя.
        height: 53,
        child: CustomPaint(
          painter: _WheelPainter(
            phase: _phase,
            barrel: cs.surfaceContainerHighest,
            barrelEdge: cs.surfaceContainerLowest,
            tick: cs.onSurfaceVariant,
            marker: AppTheme.accentFor(cs),
            outline: cs.outlineVariant,
          ),
        ),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  final double phase; // -1..1, доля деления
  final Color barrel;
  final Color barrelEdge;
  final Color tick;
  final Color marker;
  final Color outline;

  _WheelPainter({
    required this.phase,
    required this.barrel,
    required this.barrelEdge,
    required this.tick,
    required this.marker,
    required this.outline,
  });

  /// Сколько делений умещается на видимой (передней) половине барабана.
  static const int _ticksPerHalf = 9;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(12));

    // Тело барабана: светлее по центру высоты, темнее к кромкам —
    // отсюда ощущение цилиндра, а не плоской полосы.
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [barrelEdge, barrel, barrel, barrelEdge],
          stops: const [0.0, 0.32, 0.68, 1.0],
        ).createShader(rect),
    );

    canvas.save();
    canvas.clipRRect(rrect);

    final cx = size.width / 2;
    final radius = size.width / 2;
    final midY = size.height / 2;

    // Деления. Индекс i — номер деления относительно центрального;
    // угол на цилиндре пропорционален (i - phase), проекция — синус.
    for (var i = -_ticksPerHalf; i <= _ticksPerHalf; i++) {
      final theta = (i - phase) * (math.pi / 2) / _ticksPerHalf;
      final depth = math.cos(theta); // 1 в центре, 0 у краёв
      if (depth <= 0.02) continue;

      final x = cx + radius * math.sin(theta);
      final major = (i - phase).round() % 5 == 0;
      final half = size.height * (major ? 0.30 : 0.20) * depth;

      canvas.drawLine(
        Offset(x, midY - half),
        Offset(x, midY + half),
        Paint()
          ..color = tick.withValues(alpha: 0.12 + 0.55 * depth * depth)
          ..strokeWidth = major ? 2.0 : 1.2
          ..strokeCap = StrokeCap.round,
      );
    }

    canvas.restore();

    // Указатель текущего положения — по центру, поверх делений.
    canvas.drawLine(
      Offset(cx, 4),
      Offset(cx, size.height - 4),
      Paint()
        ..color = marker.withValues(alpha: 0.85)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawRRect(
      rrect,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) {
    return old.phase != phase ||
        old.barrel != barrel ||
        old.barrelEdge != barrelEdge ||
        old.tick != tick ||
        old.marker != marker ||
        old.outline != outline;
  }
}
