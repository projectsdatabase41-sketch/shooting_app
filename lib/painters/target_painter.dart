import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../logic/contrast.dart';
import '../models/shot.dart';
import '../models/target_color_scheme.dart';
import '../models/target_face.dart';

/// Отрисовка мишени (раздел 5 tech-spec-v2.md). Принимает
/// `TargetColorScheme` параметром — не читает глобальный singleton
/// напрямую (задача 2.2 dev-task-spec.md), так его проще тестировать
/// изолированно (golden-тесты).
///
/// ПОРЯДОК ОТРИСОВКИ (важно для корректности — неверный порядок стирает
/// внутренние кольца): бумага → чёрное яблоко → линии колец →
/// перекрестие → подписи габаритов (с адаптивным цветом) → компас
/// (только во время редактирования) → пробоины → индикаторы
/// результата/угла.
///
/// Подписи рисуются ПОСЛЕ перекрестия намеренно: на настоящей мишени
/// цифры стоят ровно на горизонтальной и вертикальной осях, а
/// перекрестия там нет — если рисовать цифры раньше, линии прицела их
/// перечёркивают.
class TargetPainter extends CustomPainter {
  final TargetFace face;
  final TargetColorScheme colors;
  final List<Shot> visibleShots;
  final Shot? selectedShot;
  final int currentSeriesNo;
  final bool isEditing;
  final double? draftXMm;
  final double? draftYMm;
  final int? draftShotNumber;
  final double zoom;
  final Offset pan;

  /// Мелкая картинка (пресеты, превью): подписи колец рисуются и на узких полосах, мелким шрифтом.
  final bool denseLabels;

  /// Текущая серия — пристрелочная (без зачёта). На настоящем бланке такая
  /// мишень помечается загнутым уголком; рисуем его на бумаге, поэтому он
  /// масштабируется вместе с мишнью, а не висит поверх экрана (отзыв 16.11).
  final bool sighting;

  TargetPainter({
    required this.face,
    required this.colors,
    required this.visibleShots,
    required this.selectedShot,
    required this.currentSeriesNo,
    this.isEditing = false,
    this.draftXMm,
    this.draftYMm,
    this.draftShotNumber,
    this.zoom = 1.0,
    this.pan = Offset.zero,
    this.denseLabels = false,
    this.sighting = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2) + pan;
    final radiusPx = math.min(size.width, size.height) / 2 * zoom;
    final mmToPx = radiusPx / face.faceRadiusMm;

    // 1. Бумага — СКРУГЛЁННЫЙ ПРЯМОУГОЛЬНИК, а не круг.
    //
    // Настоящий бланк квадратный (№ 8 — 80×80 мм, № 9 — 170×170,
    // № 7 — 250×250, № 4 — 550×550), и `faceRadiusMm` — это как раз
    // половина его стороны. Круглая бумага была упрощением: она теряла
    // углы бланка, а именно на них теперь выводятся значения выстрела
    // (номер, оценка, X/Y, сумма) вместо прежней нижней панели.
    if (face.zones.isNotEmpty) {
      // Многоугольная мишень (IPSC): картон по контуру, внутри зоны.
      Path poly(List<List<double>> pts) {
        final path = Path();
        for (var i = 0; i < pts.length; i++) {
          final o = center + Offset(pts[i][0], -pts[i][1]) * mmToPx;
          i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
        }
        return path..close();
      }

      final line = Paint()
        ..color = Colors.brown.shade900
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawPath(poly(face.outline!.poly), Paint()..color = const Color(0xFFB98F5E));
      canvas.drawPath(poly(face.outline!.poly), line);
      for (var i = face.zones.length - 1; i >= 0; i--) {
        final path = poly(face.zones[i].poly);
        canvas.drawPath(path, Paint()..color = Color.lerp(const Color(0xFFD9B98A), const Color(0xFFB98F5E), i / face.zones.length)!);
        canvas.drawPath(path, line);
        // Подпись зоны: A — в центре, C — между низом A и низом C, D — слева.
        double minY(int k) => face.zones[k].poly.map((p) => p[1]).reduce(math.min);
        double maxY(int k) => face.zones[k].poly.map((p) => p[1]).reduce(math.max);
        final pos = switch (i) {
          0 => Offset(0, (minY(0) + maxY(0)) / 2),
          1 => Offset(0, (minY(0) + minY(1)) / 2),
          _ => Offset(face.zones[2].poly.map((p) => p[0]).reduce(math.min) * 0.9, 0),
        };
        _drawText(canvas, ['A', 'C', 'D'][i], center + Offset(pos.dx, -pos.dy) * mmToPx, Colors.brown.shade900, 14);
      }
    } else if (face.isArchery) {
      // Мишень лука круглая.
      canvas.drawCircle(center, radiusPx, Paint()..color = colors.targetPaper);
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: center, width: radiusPx * 2, height: radiusPx * 2),
          Radius.circular(radiusPx * 0.06),
        ),
        Paint()..color = colors.targetPaper,
      );
    }

    // 1a. Загнутый уголок — признак пристрелочной мишени (как на бланке и на
    // пульте SIUS). Рисуется на бумаге, в её координатах: при зуме растёт
    // вместе с мишенью, при панорамировании уезжает с углом, а не висит перед
    // ней. Зона инвертирует цвета (BlendMode.difference) — на белом листе
    // тёмная, на чёрном яблоке — светлая. Размер +30% (было 0.28, стало ~0.36).
    if (sighting && face.zones.isEmpty && !face.isArchery) {
      final rect = Rect.fromCenter(
          center: center, width: radiusPx * 2, height: radiusPx * 2);
      final fold = radiusPx * 0.36; // +30% от 0.28
      final path = Path()
        ..moveTo(rect.right - fold, rect.top)
        ..lineTo(rect.right, rect.top)
        ..lineTo(rect.right, rect.top + fold)
        ..close();
      // Рисуем треугольник с инверсией цвета (негатив). BlendMode.difference
      // инвертирует под собой: на белой бумаге — чёрный, на чёрном яблоке — белый,
      // на цветных зонах — комплементарный цвет. Сама зона пристрелочной
      // мишени всегда узнаваема.
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..blendMode = BlendMode.difference,
      );
      // Сгиб: линия по диагонали угла — объём «загнутого» уголка, тоже в негативе.
      canvas.drawLine(
        Offset(rect.right - fold, rect.top),
        Offset(rect.right, rect.top + fold),
        Paint()
          ..color = Colors.white
          ..blendMode = BlendMode.difference
          ..strokeWidth = math.max(1.0, radiusPx * 0.015),
      );
    }

    // 2. Чёрное яблоко (кольца 10..5 условно — см. scoring.dart)
    if (face.zones.isNotEmpty) {
      // уже нарисовано выше
    } else if (face.isArchery) {
      // Зоны лука окрашены (белая 1–2, чёрная 3–4, синяя 5–6, красная 7–8,
      // золотая 9–10) — от внешней к внутренней.
      final radii = face.ringRadiiMm;
      for (var i = radii.length - 1; i >= 0; i--) {
        canvas.drawCircle(center, radii[i] * mmToPx, Paint()..color = archeryZoneColor(10 - i));
      }
    } else {
      final bullseyeRadiusPx = face.bullseyeRadiusMm * mmToPx;
      canvas.drawCircle(center, bullseyeRadiusPx, Paint()..color = colors.targetBullseye);
    }

    // 3. Линии колец
    _paintRings(canvas, center, mmToPx);

    // 4. Перекрестие — только внутри разметки
    // Центральный крест убран: мишень как бумажная, без лишней разметки.

    // 5. Подписи габаритов — после перекрестия, см. комментарий к классу
    _paintRingLabels(canvas, size, center, mmToPx);

    // 6. Компас убран (отзыв 17.11 08:04) — больше не нужен.

    // 7. Пробоины
    _paintShots(canvas, center, mmToPx);

    // 8. Индикаторы результата/угла (во время правки) — рисуются
    // виджетом поверх Canvas (Positioned), не здесь, см. target_canvas.dart.
  }

  void _paintRings(Canvas canvas, Offset center, double mmToPx) {
    // Официальные границы колец (мм) — TargetFace.ringRadiiMm, индекс 0 =
    // кольцо 10 .. индекс 9 = кольцо 1 (см. комментарий в target_face.dart
    // и logic/scoring.dart — раньше здесь было равномерное деление
    // яблока на 6 долей, заменено на реальную геометрию ISSF).
    final radii = face.ringRadiiMm;
    final ringPaint = Paint()
      ..color = colors.ringLines
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (var i = 0; i < radii.length; i++) {
      if (face.isArchery) {
        // Линия на фоне окрашенной зоны: светлая на тёмных, тёмная на светлых.
        ringPaint.color = _isDark(archeryZoneColor(10 - i)) ? Colors.white : Colors.black;
      }
      canvas.drawCircle(center, radii[i] * mmToPx, ringPaint);
    }

    // Внутренняя десятка — самая маленькая окружность бланка, внутри
    // габарита 10. Есть не у всех мишеней: у № 8 (винтовка 10м) её на
    // бумаге нет вообще, там внутренняя десятка определяется
    // калибромером, а не линией (см. TargetFace.innerTenDiameterMm).
    //
    // Замечена по разбору фото реального бланка № 7: пользователь
    // пересчитал окружности внутрь от восьмёрки — на бланке их три
    // (габарит 9, габарит 10, внутренняя десятка), а рисовалось две.
    final innerTenMm = face.innerTenRadiusMm;
    if (innerTenMm != null) {
      canvas.drawCircle(center, innerTenMm * mmToPx, ringPaint);
    }
  }

  /// Подписи габаритов — КАК НА НАСТОЯЩЕЙ ПЕЧАТНОЙ МИШЕНИ.
  ///
  /// Два отличия от прежней версии (обе — по замечанию пользователя
  /// "на мелкашке нет габарита 10; разметь цифры как в оригинале"):
  ///
  /// 1. Цифра стоит В СЕРЕДИНЕ СВОЕЙ ЗОНЫ, а не на линии. Зона габарита
  ///    N — это кольцевая полоса между границей габарита N+1 (внутренняя)
  ///    и границей габарита N (внешняя). Раньше цифра рисовалась ровно на
  ///    внешней границе, из-за чего счёт зон визуально сбивался на одну:
  ///    внутрь от "8" оказывалось ТРИ области вместо двух (9 и 10), и
  ///    десятка читалась как лишний неподписанный круг. Все 10 линий при
  ///    этом рисовались и раньше — ошибка была именно в разметке.
  /// 2. Цифра повторяется ЧЕТЫРЕ раза по осям (слева, справа, сверху,
  ///    снизу), как на печатном бланке, а не один раз по диагонали 25°.
  ///
  /// Габариты 9 и 10 не подписываются — так же, как на настоящих
  /// мишенях ISSF (раздел 3 ТЗ): десятка — это внутренний круг, самая
  /// маленькая линия.
  void _paintRingLabels(Canvas canvas, Size size, Offset center, double mmToPx) {
    const directions = [
      Offset(-1, 0),
      Offset(1, 0),
      Offset(0, -1),
      Offset(0, 1),
    ];
    final radii = face.ringRadiiMm;

    for (var ring = 1; ring <= 8; ring++) {
      // У мишеней с неполным набором колец (лук: 6 или 5) внешних нет.
      if (10 - ring >= radii.length) continue;
      final outerMm = radii[10 - ring]; // граница самого габарита N
      final innerMm = radii[9 - ring]; // граница габарита N+1
      final bandPx = (outerMm - innerMm) * mmToPx;
      // Слишком узкая полоса (сильно отдалённая мишень) — цифра
      // превратится в кашу, лучше не рисовать.
      if (bandPx < (denseLabels ? 3.5 : 8)) continue;

      final midMm = (outerMm + innerMm) / 2;
      final rPx = midMm * mmToPx;
      final fontSize = (bandPx * 0.7).clamp(denseLabels ? 5.0 : 8.0, 48.0);
      final onBullseye = midMm <= face.bullseyeRadiusMm;
      final color = face.isArchery
          ? (_isDark(archeryZoneColor(ring)) ? Colors.white : Colors.black)
          : onBullseye
              ? colors.ringLabelsOnBullseye
              : colors.ringLabelsOnPaper;

      for (final dir in directions) {
        final pos = center + dir * rPx;
        if (pos.dx < -20 || pos.dy < -20 || pos.dx > size.width + 20 || pos.dy > size.height + 20) {
          continue;
        }
        _drawText(canvas, '$ring', pos, color, fontSize);
      }
    }
  }

  static bool _isDark(Color c) => c.computeLuminance() < 0.35;

  void _drawText(Canvas canvas, String text, Offset pos, Color color, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  void _paintShots(Canvas canvas, Offset center, double mmToPx) {
    final radiusPx = face.caliberRadiusMm * mmToPx;
    for (final shot in visibleShots) {
      final isSelected = shot.id == selectedShot?.id;
      final isCurrentSeries = shot.seriesNo == currentSeriesNo;
      final color = isSelected
          ? colors.shotSelected
          : (isCurrentSeries ? colors.shotCurrentSeries : colors.shotPastSeries);
      final pos = center + Offset(shot.xMm, -shot.yMm) * mmToPx;
      if (!isSelected) {
        _drawShotCircle(canvas, pos, radiusPx, color, shot.shotNumber);
      }
    }
    // Жёлтый (выбранный) — всегда поверх остальных, рисуется последним.
    final sel = selectedShot;
    if (sel != null && visibleShots.any((s) => s.id == sel.id)) {
      final pos = center + Offset(sel.xMm, -sel.yMm) * mmToPx;
      _drawShotCircle(canvas, pos, radiusPx, colors.shotSelected, sel.shotNumber);
    }

    // Черновик правки/добавления — рисуется поверх всего.
    if (isEditing && draftXMm != null && draftYMm != null) {
      final pos = center + Offset(draftXMm!, -draftYMm!) * mmToPx;
      _drawShotCircle(canvas, pos, radiusPx, colors.shotSelected, draftShotNumber ?? (visibleShots.length + 1));
    }
  }

  void _drawShotCircle(Canvas canvas, Offset pos, double radiusPx, Color color, int number) {
    canvas.drawCircle(pos, radiusPx, Paint()..color = color);

    // Контур того же цвета, что и цифра внутри, — то есть контрастного
    // к самой пробоине.
    //
    // Нужен потому, что одна и та же пробоина ложится и на светлый
    // бланк, и на почти чёрное яблоко, а один цвет не может отличаться
    // от обоих фонов сразу: расчёт по WCAG даёт для середины потолок
    // около 3.0, и у нескольких пресетов пробоина на яблоке пропадала
    // совсем. Контур снимает вопрос независимо от палитры — включая
    // цвета, которые пользователь выбрал сам в персонализации.
    final contrast = autoContrastTextColor(color);
    canvas.drawCircle(
      pos,
      radiusPx,
      Paint()
        ..color = contrast.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, radiusPx * 0.12),
    );

    // Цвет цифры: авто-контраст к заливке пробоины или заданный вручную.
    //
    // Раньше здесь всегда стоял авто-контраст, и переключатель «Авто» в
    // пипетке не делал ничего: пользователь выбирал цвет номера, а на
    // мишени он не менялся.
    final textColor = colors.shotNumberTextAuto ? contrast : colors.shotNumberText;
    _drawText(canvas, '$number', pos, textColor, math.max(9, radiusPx * 0.7));
  }

  @override
  bool shouldRepaint(covariant TargetPainter oldDelegate) {
    return oldDelegate.face != face ||
        oldDelegate.colors != colors ||
        oldDelegate.visibleShots != visibleShots ||
        oldDelegate.selectedShot != selectedShot ||
        oldDelegate.isEditing != isEditing ||
        oldDelegate.draftXMm != draftXMm ||
        oldDelegate.draftYMm != draftYMm ||
        oldDelegate.draftShotNumber != draftShotNumber ||
        oldDelegate.zoom != zoom ||
        oldDelegate.pan != pan;
  }
}

/// Цвет зоны мишени лука (World Archery): 1–2 белая, 3–4 чёрная, 5–6 синяя,
/// 7–8 красная, 9–10 золотая.
Color archeryZoneColor(int ring) {
  if (ring >= 9) return const Color(0xFFFFD84A);
  if (ring >= 7) return const Color(0xFFE53935);
  if (ring >= 5) return const Color(0xFF3FA7E0);
  if (ring >= 3) return const Color(0xFF1B1B1B);
  return const Color(0xFFFFFFFF);
}
