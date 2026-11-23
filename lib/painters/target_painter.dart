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

  /// Текущая серия — пристрелочная (без зачёта).
  ///
  /// На настоящем бланке такая мишень помечается загнутым уголком. Уголок
  /// рисуется ЗДЕСЬ, а не бейджем в углу виджета: только здесь есть та же
  /// проекция «мм → пиксели», что и у пробоин, поэтому маркер гарантированно
  /// стоит на углу бланка, а не «где-то в углу экрана» (отзыв 22.11, №7).
  /// При зуме и панораме он прижимается к краю видимой области
  /// (отзыв 19.11 — «треугольник пристрелки не виден при зуме»).
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
    // Вся пиксельная геометрия — из одного места (`TargetProjection`):
    // пробоины, контур мишени и маркер пристрелки считаются одними и теми же
    // center/mmToPx. Пока пересчёт был скопирован по местам, маркер
    // пристрелки жил по своей формуле и стоял не там, где надо, — «уголок
    // пристрелки вообще не верный» (отзыв 22.11, №7).
    final g = TargetProjection.forCanvas(
      size,
      faceRadiusMm: face.faceRadiusMm,
      zoom: zoom,
      pan: pan,
    );
    final center = g.center;
    final radiusPx = g.radiusPx;
    final mmToPx = g.mmToPx;

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
          final o = g.mmToScreen(Offset(pts[i][0], pts[i][1]));
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
        _drawText(canvas, ['A', 'C', 'D'][i], g.mmToScreen(pos), Colors.brown.shade900, 14);
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

    // 1a. Загнутый уголок пристрелки рисуется ПОСЛЕДНИМ (см. пункт 8) — поверх
    // яблока и колец, иначе при зуме чёрное яблоко закрывает его целиком.


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
    _paintShots(canvas, g);

    // 8. Загнутый уголок пристрелки — маркер на РАМКЕ вокруг угла бланка.
    //
    // История: 16.11 уголок рисовался на бумаге и при зуме уезжал за экран
    // (19.11 — «не виден при зуме»), потом его заменили бейджем-треугольником
    // в углу холста, и 22.11 владелец сказал: «уголок пристрелки вообще не
    // верный». Причина: у бейджа была СВОЯ геометрия — он висел в углу
    // виджета, не был привязан ни к углу бланка, ни к преобразованию «мм →
    // пиксели», которым рисуются пробоины, и переворачивался вместе с иконкой.
    //
    // Теперь уголок считается той же проекцией, что и пробоины: вершина
    // прямого угла — ПРАВЫЙ ВЕРХНИЙ угол бланка (как загибают угол на
    // настоящем бланке и как рисует пульт SIUS), катеты уходят внутрь листа.
    // Если угол бланка уехал за край (зум/панорама) — уголок прижимается к
    // краю видимой области, но остаётся на той же стороне и того же размера,
    // поэтому его видно всегда и перевёрнутым он не бывает.
    //
    // Рисуется ПОСЛЕДНИМ, поверх яблока и колец: при 6,9× чёрное яблоко
    // занимает весь экран, и уголок, нарисованный раньше, исчезал под ним.
    if (sighting && face.zones.isEmpty && !face.isArchery) {
      _paintSightingCorner(canvas, size, g);
    }

    // 9. Индикаторы результата/угла (во время правки) — рисуются
    // виджетом поверх Canvas (Positioned), не здесь, см. target_canvas.dart.
  }

  /// Наименьший и наибольший катет сгиба, px.
  ///
  /// Катет — доля бланка (10%), но в этих пределах: при зуме 6,9× уголок
  /// иначе закрывал бы половину десятки, а на мишени, показанной мелко,
  /// пропадал бы совсем.
  static const double _foldMinPx = 8;
  static const double _foldMaxPx = 30;
  static const double _foldFraction = 0.10;

  /// Загнутый уголок пристрелки (отзыв 22.11, №7 — «уголок вообще не
  /// верный»). Геометрия — из [TargetProjection.sightingCorner], то есть из
  /// той же проекции «мм → пиксели», что и у пробоин; маркер стоит на правом
  /// верхнем углу бланка и никогда не переворачивается.
  void _paintSightingCorner(Canvas canvas, Size size, TargetProjection g) {
    final corner = g.sightingCorner(
      size,
      foldPx: (g.radiusPx * _foldFraction).clamp(_foldMinPx, _foldMaxPx).toDouble(),
    );
    // Цвет — не «против бумаги», как было раньше (отзыв 16.11).
    //
    // Причина: когда угол бланка уехал за край и уголок прижат к рамке, он
    // часто оказывается ПОВЕРХ чёрного яблока — при 6,9× яблоко занимает
    // весь экран, и чёрный уголок на нём просто исчезал. Золото читается и на
    // светлом бланке, и на чёрном яблоке, и на тёмной теме, а контур
    // авто-контраста отделяет его от любого фона той же палитры — тот же
    // приём, что у маркера пристрелки в финалах.
    const foldColor = Color(0xFFF2C14E);
    canvas.drawPath(corner.path, Paint()..color = foldColor.withValues(alpha: 0.95));
    canvas.drawPath(
      corner.path,
      Paint()
        ..color = autoContrastTextColor(foldColor).withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    // Сгиб: линия по гипотенузе, полупрозрачная — объём загнутого уголка.
    canvas.drawLine(
      corner.hypotenuseStart,
      corner.hypotenuseEnd,
      Paint()
        ..color = autoContrastTextColor(foldColor).withValues(alpha: 0.45)
        ..strokeWidth = math.max(1.0, corner.fold * 0.08),
    );
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

  void _paintShots(Canvas canvas, TargetProjection g) {
    final radiusPx = face.caliberRadiusMm * g.mmToPx;
    for (final shot in visibleShots) {
      final isSelected = shot.id == selectedShot?.id;
      final isCurrentSeries = shot.seriesNo == currentSeriesNo;
      final color = isSelected
          ? colors.shotSelected
          : (isCurrentSeries ? colors.shotCurrentSeries : colors.shotPastSeries);
      final pos = g.mmToScreen(Offset(shot.xMm, shot.yMm));
      if (!isSelected) {
        _drawShotCircle(canvas, pos, radiusPx, color, shot.shotNumber);
      }
    }
    // Жёлтый (выбранный) — всегда поверх остальных, рисуется последним.
    final sel = selectedShot;
    if (sel != null && visibleShots.any((s) => s.id == sel.id)) {
      final pos = g.mmToScreen(Offset(sel.xMm, sel.yMm));
      _drawShotCircle(canvas, pos, radiusPx, colors.shotSelected, sel.shotNumber);
    }

    // Черновик правки/добавления — рисуется поверх всего.
    if (isEditing && draftXMm != null && draftYMm != null) {
      final pos = g.mmToScreen(Offset(draftXMm!, draftYMm!));
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
        oldDelegate.pan != pan ||
        // Признак пристрелки переключается при переходе к следующей серии, и
        // без этой строки полотно не перерисовывалось: уголок оставался на
        // зачётной серии и пропадал на пристрелке (отзыв 22.11, №7).
        oldDelegate.sighting != sighting;
  }
}

/// Пиксельная геометрия мишени на холсте: пересчёт «мм от центра мишени» ↔
/// «пиксели холста».
///
/// Одна формула на всё, что рисуется на мишени: пробоины, черновик,
/// контур многоугольной мишени, подписи и маркер пристрелки. Пока пересчёт
/// был скопирован по местам, маркер пристрелки считался по своей формуле и
/// не совпадал с пробоинами — «уголок пристрелки вообще не верный»
/// (отзыв 22.11, №7). Общий знак Y тоже живёт только здесь: в мм ось Y
/// смотрит вверх, на экране — вниз.
class TargetProjection {
  /// Центр мишени в пикселях холста (с учётом панорамы).
  final Offset center;

  /// Пикселей в одном миллиметре бланка (с учётом зума).
  final double mmToPx;

  /// Радиус бланка в пикселях (с учётом зума).
  final double radiusPx;

  const TargetProjection({
    required this.center,
    required this.mmToPx,
    required this.radiusPx,
  });

  /// Проекция из состояния холста: размер, радиус бланка в мм, зум, панорама.
  factory TargetProjection.forCanvas(
    Size size, {
    required double faceRadiusMm,
    double zoom = 1.0,
    Offset pan = Offset.zero,
  }) {
    final center = Offset(size.width / 2, size.height / 2) + pan;
    final radiusPx = math.min(size.width, size.height) / 2 * zoom;
    return TargetProjection(
      center: center,
      mmToPx: radiusPx / faceRadiusMm,
      radiusPx: radiusPx,
    );
  }

  /// «мм от центра мишени» → «пиксели холста». Этой же функцией рисуются
  /// пробоины, поэтому маркер и пробоина с одинаковыми мм всегда совпадают.
  Offset mmToScreen(Offset mm) => center + Offset(mm.dx, -mm.dy) * mmToPx;

  /// Обратный пересчёт: «пиксели холста» → «мм от центра мишени».
  Offset screenToMm(Offset px) =>
      Offset((px.dx - center.dx) / mmToPx, -(px.dy - center.dy) / mmToPx);

  /// Квадрат бумаги мишени — тот же прямоугольник, что рисует холст.
  Rect get blankRect =>
      Rect.fromCenter(center: center, width: radiusPx * 2, height: radiusPx * 2);

  /// Куда ставится загнутый уголок пристрелки.
  ///
  /// Вершина прямого угла — ПРАВЫЙ ВЕРХНИЙ угол бланка, катеты уходят внутрь
  /// листа (влево и вниз). Именно так загибают угол на настоящем бланке и так
  /// рисует пульт SIUS, поэтому уголок не может быть перевёрнутым.
  ///
  /// При зуме и панораме угол бланка уезжает за край холста — тогда уголок
  /// прижимается к краю видимой области, оставаясь на той же стороне и того
  /// же размера. Так он виден при любом зуме (отзыв 19.11) и не улетает
  /// вслед за мишенью (отзыв 22.11).
  SightingCorner sightingCorner(Size canvas, {double? foldPx}) {
    final fold = (foldPx ?? radiusPx * 0.10).clamp(8.0, 30.0).toDouble();
    const margin = 2.0;
    final corner = blankRect.topRight;
    // Прямоугольник, в котором сгиб обязан поместиться целиком: катеты идут
    // влево (X) и вниз (Y) от вершины.
    final anchor = Offset(
      _clampToRange(corner.dx, fold + margin, canvas.width - margin),
      _clampToRange(corner.dy, margin, canvas.height - fold - margin),
    );
    return SightingCorner(
      anchor: anchor,
      fold: fold,
      blankCorner: corner,
      clamped: anchor.dx != corner.dx || anchor.dy != corner.dy,
    );
  }

  /// Зажимает [v] в [lo]..[hi]; если места меньше, чем нужно (крошечный
  /// холст), ставит по центру допустимого коридора, а не мимо него.
  static double _clampToRange(double v, double lo, double hi) =>
      hi < lo ? (lo + hi) / 2 : v.clamp(lo, hi).toDouble();
}

/// Загнутый уголок пристрелки: где он стоит, какого размера и куда смотрит.
///
/// Отдельный тип нужен, чтобы геометрию маркера можно было проверить тестом,
/// не растрируя полотно: тест сравнивает [anchor] с проекцией угла бланка и с
/// координатами пробоины в тех же мм.
class SightingCorner {
  /// Вершина прямого угла: правый верхний угол бланка, а если он уехал за
  /// край — ближайшая к нему точка внутри видимой области.
  final Offset anchor;

  /// Длина катета сгиба, пиксели.
  final double fold;

  /// Настоящий угол бланка в пикселях; может быть за краем холста.
  final Offset blankCorner;

  /// true — уголок прижат к краю видимой области.
  final bool clamped;

  const SightingCorner({
    required this.anchor,
    required this.fold,
    required this.blankCorner,
    required this.clamped,
  });

  /// Левый конец гипотенузы (линии сгиба) — по верхней кромке.
  Offset get hypotenuseStart => Offset(anchor.dx - fold, anchor.dy);

  /// Нижний конец гипотенузы (линии сгиба) — по правой кромке.
  Offset get hypotenuseEnd => Offset(anchor.dx, anchor.dy + fold);

  /// Контур сгиба: прямой угол в [anchor], катеты — влево и вниз, внутрь
  /// бланка.
  Path get path => Path()
    ..moveTo(hypotenuseStart.dx, hypotenuseStart.dy)
    ..lineTo(anchor.dx, anchor.dy)
    ..lineTo(hypotenuseEnd.dx, hypotenuseEnd.dy)
    ..close();
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
