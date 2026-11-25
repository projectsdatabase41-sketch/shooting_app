import 'package:flutter/material.dart';

/// Положение стрелка для значка упражнения (отзыв a69f8d83, уточнён 25.11).
///
/// [allThree] — три положения в один ряд: лёжа, с колена, стоя.
enum StanceKind { standing, kneeling, prone, allThree }

/// Оружие: винтовка — длинный ствол; пистолет — короткий, у вытянутой руки.
enum WeaponKind { rifle, pistol }

/// Значок изготовки для плитки упражнения.
///
/// Силуэты — картинки владельца (он нарисовал их 25.11): чёрный силуэт на
/// прозрачном фоне, который перекрашивается в цвет плитки. Рисованный
/// `CustomPainter` оставлен запасным вариантом, если ассет не загрузился.
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

  static const _assets = 'assets/stances';

  String? _assetFor(StanceKind s, WeaponKind w) {
    switch (s) {
      case StanceKind.standing:
        return w == WeaponKind.rifle ? '$_assets/standing_rifle.png' : '$_assets/standing_pistol.png';
      case StanceKind.kneeling:
        // Пистолетной стойки с колена в наборе владельца нет: положение
        // важнее оружия, поэтому показываем винтовочный силуэт (раньше здесь
        // был «палочный человечек» — замечание проверки 25.11).
        return '$_assets/kneeling_rifle.png';
      case StanceKind.prone:
        return '$_assets/prone_rifle.png';
      case StanceKind.allThree:
        return w == WeaponKind.rifle ? '$_assets/standing_rifle.png' : '$_assets/standing_pistol.png';
    }
  }

  Widget _img(String path, double h) => Image.asset(
        path,
        height: h,
        fit: BoxFit.contain,
        color: color,
        colorBlendMode: BlendMode.srcIn,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => SizedBox(
          width: h,
          height: h,
          child: CustomPaint(painter: _StancePainter(stance: stance, weapon: weapon, color: color)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    Widget icon;
    if (stance == StanceKind.allThree) {
      // Три положения в ряд: лёжа — с колена — стоя, низ выровнен.
      // FittedBox: широкий ряд масштабируется в квадрат значка без переполнения.
      icon = FittedBox(
        fit: BoxFit.contain,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // У пистолета своя стоячая фигура (с пистолетом), винтовочные —
            // для kneeling/prone: других в наборе нет.
            _img('$_assets/prone_rifle.png', size * 0.7),
            const SizedBox(width: 2),
            _img('$_assets/kneeling_rifle.png', size * 1.0),
            const SizedBox(width: 2),
            _img(_assetFor(StanceKind.standing, weapon)!, size * 1.35),
          ],
        ),
      );
    } else {
      final path = _assetFor(stance, weapon);
      icon = path == null
          ? CustomPaint(
              size: Size.square(size),
              painter: _StancePainter(stance: stance, weapon: weapon, color: color),
            )
          // Широкие силуэты (лёжа) вписываются в квадрат через contain.
          : Image.asset(
              path,
              width: size,
              height: size,
              fit: BoxFit.contain,
              color: color,
              colorBlendMode: BlendMode.srcIn,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => CustomPaint(
                size: Size.square(size),
                painter: _StancePainter(stance: stance, weapon: weapon, color: color),
              ),
            );
    }
    if (semanticLabel != null) {
      icon = Semantics(label: semanticLabel, child: icon);
    }
    return SizedBox(width: size, height: size, child: Center(child: icon));
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
    final s = size.shortestSide;
    if (s <= 0) return;
    // Запасной простой рисунок: голова + корпус + оружие.
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.09;
    canvas.drawCircle(Offset(s * 0.5, s * 0.22), s * 0.1, Paint()..color = color);
    canvas.drawLine(Offset(s * 0.5, s * 0.32), Offset(s * 0.5, s * 0.66), p);
    canvas.drawLine(Offset(s * 0.5, s * 0.66), Offset(s * 0.38, s * 0.92), p);
    canvas.drawLine(Offset(s * 0.5, s * 0.66), Offset(s * 0.62, s * 0.92), p);
    canvas.drawLine(Offset(s * 0.22, s * 0.44), Offset(s * 0.86, s * 0.38), p..strokeWidth = s * 0.06);
  }

  @override
  bool shouldRepaint(_StancePainter oldDelegate) =>
      oldDelegate.stance != stance ||
      oldDelegate.weapon != weapon ||
      oldDelegate.color != color;
}
