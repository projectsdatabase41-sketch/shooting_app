import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../logic/scoring.dart';
import '../logic/shot_photo_detection.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../painters/target_painter.dart';
import '../state/personalization_view_model.dart';
import '../i18n/i18n.dart';

/// Проверка выстрелов, найденных ИИ на фото, — сразу на схеме мишени, без
/// подгонки круга. Перетащить — поправить; выбранный — удалить. «ОК» возвращает точки (мм от центра), «Отмена» — null.
class ShotReviewScreen extends StatefulWidget {
  final TargetFace face;
  final List<PixelPoint> shotsMm;
  const ShotReviewScreen({super.key, required this.face, required this.shotsMm});

  @override
  State<ShotReviewScreen> createState() => _ShotReviewScreenState();
}

class _ShotReviewScreenState extends State<ShotReviewScreen> {
  late final List<Offset> _mm = [for (final p in widget.shotsMm) Offset(p.x, p.y)];
  int? _selected;
  int? _dragging;
  Size _size = Size.zero;

  double get _mmToPx => math.min(_size.width, _size.height) / 2 / widget.face.faceRadiusMm;
  Offset get _center => Offset(_size.width / 2, _size.height / 2);
  Offset _toPx(Offset mm) => _center + Offset(mm.dx * _mmToPx, -mm.dy * _mmToPx);
  Offset _toMm(Offset px) => Offset((px.dx - _center.dx) / _mmToPx, -(px.dy - _center.dy) / _mmToPx);

  /// Ближайший выстрел к точке касания, если попали (с запасом под палец).
  int? _hit(Offset px) {
    int? best;
    var bestD = 28.0;
    for (var i = 0; i < _mm.length; i++) {
      final d = (_toPx(_mm[i]) - px).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  double _score(Offset mm) => scoreForRadius(mm.distance, widget.face);

  @override
  Widget build(BuildContext context) {
    final colors = context.watch<PersonalizationViewModel>().scheme;
    final shots = [
      for (final (i, mm) in _mm.indexed)
        Shot(
          id: '$i',
          shotNumber: i + 1,
          seriesNo: 1,
          xMm: mm.dx,
          yMm: mm.dy,
          score: _score(mm),
          time: DateTime(2000),
        ),
    ];
    final total = _mm.fold<double>(0, (a, mm) => a + _score(mm));
    return Scaffold(
      appBar: AppBar(title: Text(tr('Найдено выстрелов: {length}', {'length': _mm.length}))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              tr('Проверьте: перетащите выстрел, если стоит не там; лишний — выберите и удалите. Сумма: {p}', {'p': total.toStringAsFixed(1)}),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                _size = Size(c.maxWidth, c.maxHeight);
                return GestureDetector(
                  // Тап — только выбрать/снять выбор. Добавлять тапом не надо
                  // (решение пользователя): число выстрелов задаётся на экране фото.
                  onTapUp: (d) => setState(() {
                    final hit = _hit(d.localPosition);
                    _selected = hit == _selected ? null : hit;
                  }),
                  onPanStart: (d) => setState(() {
                    _dragging = _hit(d.localPosition);
                    if (_dragging != null) _selected = _dragging;
                  }),
                  onPanUpdate: (d) {
                    final i = _dragging;
                    if (i != null) setState(() => _mm[i] = _toMm(d.localPosition));
                  },
                  onPanEnd: (_) => _dragging = null,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: TargetPainter(
                      face: widget.face,
                      colors: colors,
                      visibleShots: shots,
                      selectedShot: _selected == null ? null : shots[_selected!],
                      currentSeriesNo: 1,
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Отмена'))),
                  const SizedBox(width: 8),
                  if (_selected != null)
                    OutlinedButton.icon(
                      onPressed: () => setState(() {
                        _mm.removeAt(_selected!);
                        _selected = null;
                      }),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(tr('Удалить {p}', {'p': _score(_mm[_selected!]).toStringAsFixed(1)})),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _mm.isEmpty
                        ? null
                        : () => Navigator.of(context).pop([for (final mm in _mm) PixelPoint(mm.dx, mm.dy)]),
                    child: Text(tr('ОК')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
