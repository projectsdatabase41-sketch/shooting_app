import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Рендер графика/таблицы по описанию от модели.
///
/// Модель возвращает НЕ код, а короткое JSON-описание — выполнить
/// присланный код в скомпилированном Flutter всё равно нельзя (нет
/// `eval`), да и не нужно: описание проверяемо, а ошибка в нём ломает
/// один график, а не приложение. Размеры модели тоже знать не нужно —
/// вёрсткой занимается приложение.
///
/// Ожидаемый формат:
/// ```json
/// {"type":"line|bar|table","title":"...",
///  "x":["1","2"],"series":[{"name":"...","values":[10.4,9.8]}],
///  "columns":["a","b"],"rows":[["1","2"]]}
/// ```
class AiChartView extends StatelessWidget {
  final Map<String, dynamic> spec;

  const AiChartView({super.key, required this.spec});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = '${spec['type'] ?? ''}'.toLowerCase();
    final title = '${spec['title'] ?? ''}'.trim();

    Widget body;
    if (type == 'table') {
      body = _buildTable(context);
    } else if (type == 'line' || type == 'bar') {
      body = _buildChart(context, bar: type == 'bar');
    } else {
      body = Text(
        'Не понял тип графика: «$type»',
        style: theme.textTheme.bodySmall,
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty) ...[
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 10),
            ],
            body,
          ],
        ),
      ),
    );
  }

  Widget _buildChart(BuildContext context, {required bool bar}) {
    final cs = Theme.of(context).colorScheme;
    final labels = [for (final e in (spec['x'] as List? ?? const [])) '$e'];
    final rawSeries = spec['series'] as List? ?? const [];

    final series = <_Series>[];
    for (final s in rawSeries) {
      if (s is! Map) continue;
      final values = <double>[];
      for (final v in (s['values'] as List? ?? const [])) {
        values.add(v is num ? v.toDouble() : (double.tryParse('$v') ?? 0));
      }
      if (values.isNotEmpty) {
        series.add(_Series('${s['name'] ?? ''}', values));
      }
    }
    if (series.isEmpty) {
      return Text('Нет данных для графика', style: Theme.of(context).textTheme.bodySmall);
    }

    final palette = [cs.primary, AppTheme.accentFor(cs), cs.tertiary];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 190,
          child: CustomPaint(
            painter: _SpecChartPainter(
              series: series,
              labels: labels,
              bar: bar,
              colors: palette,
              axisColor: cs.onSurfaceVariant,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        if (series.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (var i = 0; i < series.length; i++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: palette[i % palette.length],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(series[i].name, style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildTable(BuildContext context) {
    final theme = Theme.of(context);
    final columns = [for (final c in (spec['columns'] as List? ?? const [])) '$c'];
    final rows = <List<String>>[];
    for (final r in (spec['rows'] as List? ?? const [])) {
      if (r is List) rows.add([for (final c in r) '$c']);
    }
    if (columns.isEmpty && rows.isEmpty) {
      return Text('Пустая таблица', style: theme.textTheme.bodySmall);
    }
    // Широкие таблицы прокручиваются вбок, а не ломают вёрстку экрана.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 22,
        headingRowHeight: 34,
        dataRowMinHeight: 30,
        dataRowMaxHeight: 40,
        columns: [
          for (final c in columns) DataColumn(label: Text(c, style: theme.textTheme.labelMedium)),
        ],
        rows: [
          for (final r in rows)
            DataRow(cells: [
              for (var i = 0; i < columns.length; i++)
                DataCell(Text(i < r.length ? r[i] : '', style: theme.textTheme.bodySmall)),
            ]),
        ],
      ),
    );
  }
}

class _Series {
  final String name;
  final List<double> values;
  const _Series(this.name, this.values);
}

class _SpecChartPainter extends CustomPainter {
  final List<_Series> series;
  final List<String> labels;
  final bool bar;
  final List<Color> colors;
  final Color axisColor;

  _SpecChartPainter({
    required this.series,
    required this.labels,
    required this.bar,
    required this.colors,
    required this.axisColor,
  });

  static const double _left = 36;
  static const double _bottom = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final plotBottom = size.height - _bottom;
    final plotWidth = size.width - _left;
    if (plotWidth <= 0 || plotBottom <= 0) return;

    var minV = double.infinity;
    var maxV = -double.infinity;
    for (final s in series) {
      for (final v in s.values) {
        minV = math.min(minV, v);
        maxV = math.max(maxV, v);
      }
    }
    if (minV == double.infinity) return;
    // Столбики всегда считаем от нуля, иначе они врут о соотношениях.
    if (bar || minV > 0) minV = math.min(0, minV);
    if (maxV == minV) maxV = minV + 1;

    final grid = Paint()
      ..color = axisColor.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final t = i / 4;
      final v = minV + (maxV - minV) * t;
      final y = plotBottom - t * plotBottom;
      canvas.drawLine(Offset(_left, y), Offset(size.width, y), grid);
      _text(canvas, _fmt(v), Offset(_left - 5, y), axisColor, 9, right: true);
    }

    final count = series.map((s) => s.values.length).reduce(math.max);
    double xAt(int i) => count <= 1
        ? _left + plotWidth / 2
        : _left + plotWidth * i / (count - 1);
    double yAt(double v) => plotBottom - (v - minV) / (maxV - minV) * plotBottom;

    if (bar) {
      final slot = plotWidth / count;
      final groupWidth = slot * 0.7;
      final barWidth = groupWidth / series.length;
      for (var si = 0; si < series.length; si++) {
        final paint = Paint()..color = colors[si % colors.length];
        for (var i = 0; i < series[si].values.length; i++) {
          final cx = _left + slot * (i + 0.5) - groupWidth / 2 + barWidth * (si + 0.5);
          final y = yAt(series[si].values[i]);
          final zero = yAt(math.max(0, minV));
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTRB(cx - barWidth / 2 + 1, math.min(y, zero), cx + barWidth / 2 - 1, math.max(y, zero)),
              topLeft: const Radius.circular(2),
              topRight: const Radius.circular(2),
            ),
            paint,
          );
        }
      }
    } else {
      for (var si = 0; si < series.length; si++) {
        final path = Path();
        for (var i = 0; i < series[si].values.length; i++) {
          final p = Offset(xAt(i), yAt(series[si].values[i]));
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = colors[si % colors.length]
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    // Подписи по X — прореживаем, чтобы не слипались.
    if (labels.isNotEmpty) {
      final step = labels.length <= 8 ? 1 : (labels.length / 6).ceil();
      for (var i = 0; i < labels.length; i++) {
        if (i % step != 0 && i != labels.length - 1) continue;
        final x = bar ? _left + plotWidth / labels.length * (i + 0.5) : xAt(i);
        _text(canvas, labels[i], Offset(x, plotBottom + 3), axisColor, 9, center: true);
      }
    }
  }

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  void _text(Canvas canvas, String s, Offset pos, Color color, double size,
      {bool right = false, bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = right ? pos.dx - tp.width : (center ? pos.dx - tp.width / 2 : pos.dx);
    final dy = right ? pos.dy - tp.height / 2 : pos.dy;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _SpecChartPainter old) => true;
}
