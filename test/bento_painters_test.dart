import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/painters/bento_painters.dart';

/// Treemap из промпта AnalyticsBento: проверяем математику раскладки, а не
/// пиксели. Ошибка в squarify не падает — она даёт плитки поверх друг друга
/// или вылезающие за карточку, что глазами замечается не сразу.
void main() {
  group('squarify', () {
    test('плиток столько же, сколько значений', () {
      final rects = BentoTreemapPainter.squarify([5, 3, 2, 1, 1], const Rect.fromLTWH(0, 0, 300, 200));
      expect(rects.length, 5);
    });

    test('все плитки внутри карточки', () {
      const bounds = Rect.fromLTWH(10, 20, 320, 180);
      final rects = BentoTreemapPainter.squarify([10, 6, 4, 3, 2, 1], bounds);
      for (final r in rects) {
        expect(r.left, greaterThanOrEqualTo(bounds.left - 0.001));
        expect(r.top, greaterThanOrEqualTo(bounds.top - 0.001));
        expect(r.right, lessThanOrEqualTo(bounds.right + 0.001));
        expect(r.bottom, lessThanOrEqualTo(bounds.bottom + 0.001));
      }
    });

    test('площадь плитки пропорциональна значению', () {
      final rects = BentoTreemapPainter.squarify([6, 3, 1], const Rect.fromLTWH(0, 0, 400, 200));
      const total = 6 + 3 + 1;
      for (var i = 0; i < rects.length; i++) {
        final share = rects[i].width * rects[i].height / (400 * 200);
        final expected = [6, 3, 1][i] / total;
        expect(share, closeTo(expected, 0.02), reason: 'плитка $i');
      }
    });

    test('плитки не перекрываются', () {
      final rects = BentoTreemapPainter.squarify([9, 7, 5, 4, 3, 2, 1], const Rect.fromLTWH(0, 0, 280, 220));
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          final overlap = rects[i].intersect(rects[j]);
          final area = overlap.width <= 0 || overlap.height <= 0 ? 0.0 : overlap.width * overlap.height;
          expect(area, lessThan(0.5), reason: 'плитки $i и $j накладываются');
        }
      }
    });

    test('пустой и нулевой вход не падает', () {
      expect(BentoTreemapPainter.squarify(const [], const Rect.fromLTWH(0, 0, 100, 100)), isEmpty);
      expect(BentoTreemapPainter.squarify([0, 0], const Rect.fromLTWH(0, 0, 100, 100)), isEmpty);
    });
  });

  group('BentoTrendPainter', () {
    /// Отзыв 22.11, пункт 6 («обзор график не работает»): пустой ряд,
    /// одна точка и плоский ряд не должны ни падать, ни молча ничего не
    /// нарисовать. Проверяем именно вызов отрисовки — пиксели здесь не
    /// сравниваем.
    test('пустой, одиночный и плоский ряд рисуются без падений', () {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const size = Size(220, 100);
      BentoTrendPainter painter(List<double> values) => BentoTrendPainter(
            values: values,
            lineColor: const Color(0xFFE8A33D),
            fillColor: const Color(0x4DE8A33D),
            gridColor: const Color(0x33000000),
          );

      painter(const []).paint(canvas, size);
      painter(const [9.5]).paint(canvas, size);
      painter(const [9.5, 9.5, 9.5]).paint(canvas, size);
      painter(const [9.1, 9.8, 9.3]).paint(canvas, size);

      expect(recorder.endRecording(), isNotNull);
    });
  });

  group('smoothThrough', () {
    test('пустой список — пустой путь', () {
      expect(smoothThrough(const []).computeMetrics().isEmpty, isTrue);
    });

    test('одна точка не роняет построение', () {
      final path = smoothThrough(const [Offset(1, 2)]);
      expect(path.getBounds().left, 1);
    });

    test('путь проходит через все точки по X', () {
      const pts = [Offset(0, 10), Offset(50, 0), Offset(100, 10)];
      final bounds = smoothThrough(pts).getBounds();
      expect(bounds.left, 0);
      expect(bounds.right, 100);
    });
  });
}

