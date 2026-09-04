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
  /// Внутренняя граница зоны компаса, долей радиуса мишени (B.4:
  /// r >= 0.85*R). Публичная, потому что тот же порог нужен жестовому
  /// слою (`TargetCanvas`), чтобы понять, что пользователь тянет за
  /// компас, а не двигает пробоину — два разных значения разъехались бы.
  static const double compassZoneFraction = 0.85;

  final TargetFace face;
  final TargetColorScheme colors;
  final List<Shot> visibleShots;
  final Shot? selectedShot;
  final int currentSeriesNo;
  final bool isEditing;
  final double? draftXMm;
  final double? draftYMm;
  final double zoom;
  final Offset pan;

  TargetPainter({
    required this.face,
    required this.colors,
    required this.visibleShots,
    required this.selectedShot,
    required this.currentSeriesNo,
    this.isEditing = false,
    this.draftXMm,
    this.draftYMm,
    this.zoom = 1.0,
    this.pan = Offset.zero,
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
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: radiusPx * 2, height: radiusPx * 2),
        Radius.circular(radiusPx * 0.06),
      ),
      Paint()..color = colors.targetPaper,
    );

    // 2. Чёрное яблоко (кольца 10..5 условно — см. scoring.dart)
    final bullseyeRadiusPx = face.bullseyeRadiusMm * mmToPx;
    canvas.drawCircle(center, bullseyeRadiusPx, Paint()..color = colors.targetBullseye);

    // 3. Линии колец
    _paintRings(canvas, center, mmToPx);

    // 4. Перекрестие — только внутри разметки
    _paintCrosshair(canvas, center, mmToPx);

    // 5. Подписи габаритов — после перекрестия, см. комментарий к классу
    _paintRingLabels(canvas, size, center, mmToPx);

    // 6. Компас — только во время редактирования
    if (isEditing) {
      _paintCompass(canvas, center, radiusPx);
    }

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
      final outerMm = radii[10 - ring]; // граница самого габарита N
      final innerMm = radii[9 - ring]; // граница габарита N+1
      final bandPx = (outerMm - innerMm) * mmToPx;
      // Слишком узкая полоса (сильно отдалённая мишень) — цифра
      // превратится в кашу, лучше не рисовать.
      if (bandPx < 8) continue;

      final midMm = (outerMm + innerMm) / 2;
      final rPx = midMm * mmToPx;
      final fontSize = (bandPx * 0.7).clamp(8.0, 15.0);
      final onBullseye = midMm <= face.bullseyeRadiusMm;
      final color = onBullseye ? colors.ringLabelsOnBullseye : colors.ringLabelsOnPaper;

      for (final dir in directions) {
        final pos = center + dir * rPx;
        if (pos.dx < -20 || pos.dy < -20 || pos.dx > size.width + 20 || pos.dy > size.height + 20) {
          continue;
        }
        _drawText(canvas, '$ring', pos, color, fontSize);
      }
    }
  }

  void _drawText(Canvas canvas, String text, Offset pos, Color color, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  /// Перекрестие центра — в пределах внешнего кольца, а не на весь
  /// экран.
  ///
  /// На настоящем бланке разметка заканчивается вместе с габаритом 1;
  /// линии до краёв окна выглядели как координатная сетка поверх
  /// мишени и мешали смотреть на группу.
  void _paintCrosshair(Canvas canvas, Offset center, double mmToPx) {
    final radii = face.ringRadiiMm;
    if (radii.isEmpty) return;
    final r = radii.last * mmToPx;
    final paint = Paint()
      ..color = colors.crosshair
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(center.dx - r, center.dy), Offset(center.dx + r, center.dy), paint);
    canvas.drawLine(Offset(center.dx, center.dy - r), Offset(center.dx, center.dy + r), paint);
  }

  /// Компас выбора угла — появляется только во время правки.
  ///
  /// Раньше это была просто закрашенная полоса во внешних 15% радиуса.
  /// Теперь это настоящий компас: кольцо, 12 делений по часам с
  /// подписями и стрелка на текущий угол пробоины. Потянув по этому
  /// кольцу, пользователь меняет ТОЛЬКО угол, не трогая результат —
  /// см. `TargetCanvas` и `TargetViewModel.setDraftAngleFromPoint`.
  /// Он заменил прежний степпер "Угол" с кнопками +/-.
  void _paintCompass(Canvas canvas, Offset center, double radiusPx) {
    final inner = radiusPx * compassZoneFraction;
    final mid = (radiusPx + inner) / 2;

    canvas.drawCircle(
      center,
      mid,
      Paint()
        ..color = colors.compassRing.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (radiusPx - inner),
    );

    final tickPaint = Paint()
      ..color = colors.compassRing
      ..strokeWidth = 1.5;
    for (var hour = 1; hour <= 12; hour++) {
      final angle = -math.pi / 2 + hour * (2 * math.pi / 12);
      final dir = Offset(math.cos(angle), math.sin(angle));
      final long = hour % 3 == 0;
      canvas.drawLine(
        center + dir * inner,
        center + dir * (inner + (radiusPx - inner) * (long ? 0.55 : 0.3)),
        tickPaint,
      );
      if (long) {
        _drawText(canvas, '$hour', center + dir * (mid + (radiusPx - inner) * 0.18),
            colors.compassRing, 11);
      }
    }

    // Стрелка на текущий угол пробоины — чтобы было видно, что именно
    // крутится, ещё до начала перетаскивания.
    final draftX = draftXMm;
    final draftY = draftYMm;
    if (draftX != null && draftY != null && (draftX != 0 || draftY != 0)) {
      final angle = math.atan2(draftX, draftY); // 0 = вверх, по часовой
      final dir = Offset(math.sin(angle), -math.cos(angle));
      canvas.drawCircle(
        center + dir * mid,
        (radiusPx - inner) * 0.32,
        Paint()..color = colors.shotSelected,
      );
    }
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
      _drawShotCircle(canvas, pos, radiusPx, colors.shotSelected, sel?.shotNumber ?? (visibleShots.length + 1));
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
        oldDelegate.zoom != zoom ||
        oldDelegate.pan != pan;
  }
}
