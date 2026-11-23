import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/models/target_color_scheme.dart';
import 'package:shooting_app/models/target_face.dart';
import 'package:shooting_app/painters/target_painter.dart';

/// Тесты геометрии мишени — прежде всего маркера пристрелки.
///
/// Повод: отзыв 22.11 №7 «уголок пристрелки вообще не верный». Маркер жил по
/// своей формуле, не привязанной ни к углу бланка, ни к той проекции «мм →
/// пиксели», которой рисуются пробоины. Здесь проверяется, что пересчёт один
/// и тот же и что уголок стоит там, где нужно, при любом зуме и сдвиге.
void main() {
  const face = TargetFace.rifle10m; // бланк 80×80 мм → faceRadiusMm = 40
  const size = Size(400, 320);

  /// Три контрольных выстрела из постановки задачи: центр, правый верх, левый низ.
  final controlShots = <String, Offset>{
    'центр': const Offset(0, 0),
    'правый верх': Offset(face.faceRadiusMm * 0.8, face.faceRadiusMm * 0.8),
    'левый низ': Offset(-face.faceRadiusMm * 0.8, -face.faceRadiusMm * 0.8),
  };

  const zooms = [1.0, 2.0, 4.0, 6.9];
  const pans = [Offset.zero, Offset(37, -21), Offset(-300, 180)];

  test('«мм → пиксели» одна формула для пробоин, маркера и обратного пересчёта', () {
    for (final zoom in zooms) {
      for (final pan in pans) {
        final g = TargetProjection.forCanvas(
          size,
          faceRadiusMm: face.faceRadiusMm,
          zoom: zoom,
          pan: pan,
        );
        // Центр мишени в пикселях — ровно центр холста плюс панорама.
        expect(g.mmToScreen(Offset.zero), g.center);

        for (final entry in controlShots.entries) {
          final mm = entry.value;
          // Та же формула, что стояла в отрисовке пробоин до рефакторинга:
          // center + (x, −y) * mmToPx. Знак Y — один раз, здесь.
          final expected = g.center + Offset(mm.dx, -mm.dy) * g.mmToPx;
          _expectClose(g.mmToScreen(mm), expected, reason: '${entry.key}, зум $zoom, панорама $pan');

          // Обратный пересчёт возвращает те же мм — то есть экранная точка
          // пробоины читается обратно без сдвигов и без переворота по Y.
          final back = g.screenToMm(g.mmToScreen(mm));
          expect(back.dx, closeTo(mm.dx, 1e-9));
          expect(back.dy, closeTo(mm.dy, 1e-9));
        }
      }
    }
  });

  test('уголок пристрелки стоит на правом верхнем углу бланка — как у пробоины с теми же мм', () {
    for (final zoom in zooms) {
      for (final pan in pans) {
        final g = TargetProjection.forCanvas(
          size,
          faceRadiusMm: face.faceRadiusMm,
          zoom: zoom,
          pan: pan,
        );
        final corner = g.sightingCorner(size);
        // Вершина угла — та же точка, куда легла бы пробоина в мм (+R, +R):
        // угол бланка в координатах мишени.
        final cornerMm = g.mmToScreen(Offset(face.faceRadiusMm, face.faceRadiusMm));
        _expectClose(corner.blankCorner, cornerMm, reason: 'зум $zoom, панорама $pan');
        expect(corner.blankCorner, g.blankRect.topRight);
        // Сам маркер либо ровно там, либо прижат к краю видимой области.
        if (!corner.clamped) {
          _expectClose(corner.anchor, cornerMm, reason: 'зум $zoom, панорама $pan');
        }
      }
    }
  });

  test('уголок виден при любом зуме и сдвиге: сгиб целиком внутри холста', () {
    final canvas = Offset.zero & size;
    for (final zoom in zooms) {
      for (final pan in pans) {
        final g = TargetProjection.forCanvas(
          size,
          faceRadiusMm: face.faceRadiusMm,
          zoom: zoom,
          pan: pan,
        );
        final corner = g.sightingCorner(size);
        final bounds = corner.path.getBounds();
        expect(bounds.left, greaterThanOrEqualTo(canvas.left - 1e-9));
        expect(bounds.top, greaterThanOrEqualTo(canvas.top - 1e-9));
        expect(bounds.right, lessThanOrEqualTo(canvas.right + 1e-9));
        expect(bounds.bottom, lessThanOrEqualTo(canvas.bottom + 1e-9));
        // Катет сгиба — в разумных пределах, а не во весь экран: при 6,9×
        // уголок не должен закрывать десятку. Границы 12…40.px — новые
        // значения после увеличения катета на 30% (отзыв 23.11 №4),
        // прежние были 8…30.
        expect(corner.fold, inInclusiveRange(12, 40));
      }
    }
  });

  test('уголок не перевёрнут: катеты сгиба идут внутрь бланка, а не наружу', () {
    final g = TargetProjection.forCanvas(
      const Size(400, 400),
      faceRadiusMm: face.faceRadiusMm,
    );
    final corner = g.sightingCorner(const Size(400, 400));
    // Прямой угол — в вершине; гипотенуза смотрит в сторону центра мишени.
    expect(corner.hypotenuseStart, Offset(corner.anchor.dx - corner.fold, corner.anchor.dy));
    expect(corner.hypotenuseEnd, Offset(corner.anchor.dx, corner.anchor.dy + corner.fold));

    // Без зума катет — ровно 13% радиуса бланка (после увеличения на 30%,
    // отзыв 23.11 №4), и кламп 12…40 его не трогает: 200 × 0.13 = 26.
    expect(corner.fold, closeTo(200 * 0.13, 1e-6));

    final inside = corner.anchor + Offset(-corner.fold * 0.25, corner.fold * 0.25);
    final outside = corner.anchor + Offset(corner.fold * 0.25, -corner.fold * 0.25);
    expect(corner.path.contains(inside), true, reason: 'внутри сгиба (внутрь бланка)');
    expect(corner.path.contains(outside), false, reason: 'снаружи угла (за бланком)');

    // Яблоко и центр — вниз-влево от вершины, то есть сгиб смотрит на мишень.
    expect(g.center.dx, lessThan(corner.anchor.dx));
    expect(g.center.dy, greaterThan(corner.anchor.dy));
  });

  test('уголок появляется и исчезает вместе с пристрелкой (перерисовка)', () {
    final base = TargetPainter(
      face: face,
      colors: TargetColorScheme.classic,
      visibleShots: const [],
      selectedShot: null,
      currentSeriesNo: 1,
    );
    final sighting = TargetPainter(
      face: face,
      colors: TargetColorScheme.classic,
      visibleShots: const [],
      selectedShot: null,
      currentSeriesNo: 1,
      sighting: true,
    );
    // Без этой проверки при переходе к зачётной серии уголок оставался на
    // полотне (отзыв 22.11, №7).
    expect(sighting.shouldRepaint(base), true);
    expect(base.shouldRepaint(sighting), true);
    expect(base.shouldRepaint(base), false);
  });

  testWidgets('уголок реально рисуется на полотне — пиксель в сгибе меняется', (tester) async {
    const canvasSize = Size(200, 200);
    final g = TargetProjection.forCanvas(canvasSize, faceRadiusMm: face.faceRadiusMm);
    final corner = g.sightingCorner(canvasSize);
    final probe = corner.anchor + Offset(-corner.fold * 0.25, corner.fold * 0.25);

    final without = await tester.runAsync(() => _pixels(canvasSize, sighting: false));
    final withMarker = await tester.runAsync(() => _pixels(canvasSize, sighting: true));
    expect(without, isNotNull);
    expect(withMarker, isNotNull);

    final paper = _pixelAt(without!, canvasSize, probe);
    final mark = _pixelAt(withMarker!, canvasSize, probe);
    expect(mark, isNot(paper), reason: 'в точке сгиба должен появиться маркер');
  });
}

/// Сравнивает точки с допуском: произведение мм на «пикселей на мм» даёт
/// последние биты отличными от радиуса, посчитанного напрямую, и точное
/// равенство тут ложно-отрицательно при зуме 6.9.
void _expectClose(Offset actual, Offset expected, {String? reason}) {
  expect(actual.dx, closeTo(expected.dx, 1e-6), reason: reason);
  expect(actual.dy, closeTo(expected.dy, 1e-6), reason: reason);
}

/// Растрирует полотно мишени и отдаёт байты пикселей RGBA.
Future<ByteData> _pixels(Size size, {required bool sighting}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  TargetPainter(
    face: TargetFace.rifle10m,
    colors: TargetColorScheme.classic,
    visibleShots: const [],
    selectedShot: null,
    currentSeriesNo: 1,
    sighting: sighting,
  ).paint(canvas, size);
  final image = await recorder.endRecording().toImage(size.width.round(), size.height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!;
}

/// Цвет пикселя в точке [pos] из буфера RGBA.
int _pixelAt(ByteData data, Size size, Offset pos) {
  final w = size.width.round();
  final x = pos.dx.round().clamp(0, w - 1);
  final y = pos.dy.round().clamp(0, size.height.round() - 1);
  final i = (y * w + x) * 4;
  return data.getUint32(i, Endian.little);
}
