import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../logic/shot_analytics.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../painters/analytics_painters.dart';
import '../painters/score_graph_painter.dart';
import '../theme/app_theme.dart';
import 'empty_state.dart';
import 'section_header.dart';
import 'stat_tile.dart';

/// Единый блок разбора стрельбы по ЛЮБОМУ набору выстрелов.
///
/// Ключевая идея (по замечанию пользователя «мало данных, лучше вывести
/// по нескольким графикам… за все тренировки, за упражнения, за
/// конкретную тренировку, за конкретную серию»): срез задаётся снаружи,
/// а панель везде одна и та же. Экран статистики подставляет сюда
/// выстрелы выбранного среза, экран мишени — выстрелы текущей
/// тренировки или одной её серии. Никакой отдельной «статистики
/// тренировки» и «статистики серии» в коде нет — есть один блок и
/// разные списки выстрелов.
///
/// `dynamics` — график динамики, который у каждого среза свой по смыслу:
/// на срезе «все тренировки» это сумма за тренировку, внутри одной
/// тренировки — результат каждого выстрела. Панель не пытается угадать
/// его сама, а получает готовым.
class AnalyticsPanel extends StatefulWidget {
  final List<Shot> shots;
  final TargetFace face;

  /// Заголовок и точки графика динамики. `null` — не показывать блок
  /// динамики (например, когда в срезе одна серия из 10 выстрелов и
  /// динамика дублировала бы разбор по выстрелам).
  ///
  /// Список: по нажатию на график панель переключает режим — сумма,
  /// средний выстрел, лучшая и худшая серия. Один элемент — переключать
  /// нечего, подсказка о нажатии не показывается.
  final List<AnalyticsDynamics>? dynamics;

  /// Показывать ли блок «по сериям». На срезе одной серии он не нужен.
  final bool showSeries;

  /// Непустой текст = в срез попали выстрелы по РАЗНЫМ мишеням.
  ///
  /// Тогда геометрические показатели (СТП, кучность, разброс по часам)
  /// не выводятся вовсе: координаты в мм на мишени 10 м и на мишени
  /// 50 м несопоставимы, и «средняя точка попадания» по ним — просто
  /// неверное число. Габариты и очки при этом сопоставимы (десятка есть
  /// у всех мишеней), поэтому они остаются.
  final String? mixedFacesNote;

  const AnalyticsPanel({
    super.key,
    required this.shots,
    required this.face,
    this.dynamics,
    this.showSeries = true,
    this.mixedFacesNote,
  });

  @override
  State<AnalyticsPanel> createState() => _AnalyticsPanelState();
}

class _AnalyticsPanelState extends State<AnalyticsPanel> {
  /// Текущий режим графика динамики. Живёт в состоянии панели, а не в
  /// родителе: это чисто способ посмотреть на те же данные, менять
  /// срез он не должен.
  int _mode = 0;

  List<Shot> get shots => widget.shots;
  TargetFace get face => widget.face;
  bool get showSeries => widget.showSeries;
  String? get mixedFacesNote => widget.mixedFacesNote;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = AppTheme.accentFor(cs);

    if (shots.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: EmptyState(
          icon: Icons.query_stats,
          text: 'В этом срезе пока нет выстрелов',
        ),
      );
    }

    final a = ShotAnalytics(shots, face);
    final modes = widget.dynamics ?? const <AnalyticsDynamics>[];
    final series = a.seriesStats;
    // Режим мог «уехать» за границы, если срез сменился на такой, где
    // вариантов меньше (в одной серии нечего сравнивать по сериям).
    final mode = modes.isEmpty ? 0 : _mode % modes.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tiles(context, a, accent),
        if (modes.isNotEmpty) ...[
          const SizedBox(height: 24),
          SectionHeader(
            title: modes[mode].title,
            subtitle: modes.length > 1
                ? '${modes[mode].subtitle} · нажмите, чтобы сменить'
                : modes[mode].subtitle,
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: modes.length > 1 ? () => setState(() => _mode = mode + 1) : null,
            child: _chartCard(
              height: modes[mode].verticalXLabels ? 220 : 190,
              child: CustomPaint(
                painter: ScoreGraphPainter(
                  shots: modes[mode].points,
                  lineColor: accent,
                  axisColor: cs.onSurfaceVariant,
                  maxY: modes[mode].maxY,
                  minY: modes[mode].effectiveMinY,
                  yTickStep: (modes[mode].maxY - modes[mode].effectiveMinY) / 5,
                  xLabels: modes[mode].xLabels,
                  verticalXLabels: modes[mode].verticalXLabels,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        SectionHeader(
          title: a.allInTen ? 'Распределение внутри десятки' : 'Распределение по габаритам',
          // У разбивки по десятым подписи нет намеренно: заголовок
          // «Распределение внутри десятки» и сами подписи 10.9…10.0
          // говорят всё сами.
          subtitle: '',
        ),
        const SizedBox(height: 12),
        _chartCard(
          height: _ringChartHeight(a),
          child: CustomPaint(
            painter: RingDistributionPainter(
              rows: _distributionRows(a),
              barColor: cs.primary,
              axisColor: cs.onSurfaceVariant,
              labelWidth: a.allInTen ? 32 : 22,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        if (mixedFacesNote != null) ...[
          const SizedBox(height: 16),
          _noteCard(context, mixedFacesNote!),
        ] else ...[
          const SizedBox(height: 24),
          SectionHeader(
            title: 'СТП и кучность',
            subtitle: _groupSubtitle(a),
          ),
          const SizedBox(height: 12),
          _chartCard(
            height: 240,
            child: Row(
              children: [
                Expanded(
                  child: CustomPaint(
                    painter: GroupScatterPainter(
                      shots: shots,
                      face: face,
                      meanPointMm: a.meanPoint,
                      meanRadiusMm: a.meanRadiusMm,
                      spreadCenterMm: a.spreadCircleCenterMm,
                      spreadRadiusMm: a.extremeSpreadMm == null ? null : a.extremeSpreadMm! / 2,
                      cep50Mm: a.cepRadiusMm(0.5),
                      cep90Mm: a.cepRadiusMm(0.9),
                      // Номера — только когда выстрелов немного: на
                      // тысяче цифры превращаются в серую кашу.
                      showNumbers: shots.length <= 30,
                      shotColor: cs.primary,
                      meanColor: accent,
                      ringColor: cs.onSurfaceVariant,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(width: 140, child: _groupLegend(context, a, accent)),
              ],
            ),
          ),
        ],
        if (showSeries && series.length > 1) ...[
          const SizedBox(height: 24),
          const SectionHeader(
            title: 'Средний результат по сериям',
            subtitle: 'Видно, где результат садится к концу',
          ),
          const SizedBox(height: 12),
          _chartCard(
            height: 180,
            child: CustomPaint(
              painter: SeriesBarsPainter(
                series: series,
                barColor: cs.primary,
                axisColor: cs.onSurfaceVariant,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tiles(BuildContext context, ShotAnalytics a, Color accent) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: StatTile(icon: Icons.adjust, label: 'Выстрелов', value: '${a.count}')),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                icon: Icons.functions,
                label: 'Сумма',
                value: '${a.total.toStringAsFixed(1)} / ${a.totalWhole}',
                hint: 'с десятыми / целыми',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.speed_outlined,
                label: 'Средний',
                value: a.average.toStringAsFixed(2),
                hint: 'мин ${a.worst.toStringAsFixed(1)} · макс ${a.best.toStringAsFixed(1)}',
                accent: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              // Счётчик десяток заменён на отклонение СТП по осям: у
              // стрелка, который кладёт всё в десятку, счётчик всегда
              // равен числу выстрелов и не говорит ни о чём. А X и Y —
              // это прямо поправка, которую надо ввести прицелом.
              child: StatTile(
                icon: Icons.control_camera_outlined,
                label: 'Отклонение СТП',
                value: mixedFacesNote != null ? '—' : _meanXyText(a),
                // Под цифрами — «X / Y», а не словами: порядок величин
                // важнее их пересказа, а сторону показывает стрелка
                // рядом с числами.
                hint: mixedFacesNote != null ? 'мишени разные' : 'X / Y',
                accent: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Отклонение СТП по осям со знаком: «X +0.4  Y −1.2».
  ///
  /// Минус — типографский, а не дефис: в столбце цифр дефис читается
  /// как перенос.
  static String _meanXyText(ShotAnalytics a) {
    String v(double x) {
      final s = x.abs().toStringAsFixed(1);
      if (x > 0.05) return '+$s';
      if (x < -0.05) return '−$s';
      return '0.0';
    }

    final arrow = directionArrow(a.meanPoint);
    final xy = '${v(a.meanPoint.dx)} / ${v(a.meanPoint.dy)}';
    return arrow == null ? xy : '$xy $arrow';
  }

  /// Строки гистограммы: обычно по габаритам, а если все выстрелы легли
  /// в десятку — по десятым внутри неё.
  List<({String label, int count})> _distributionRows(ShotAnalytics a) {
    if (a.allInTen) {
      final counts = a.tenDecimalCounts;
      return [
        for (var d = 9; d >= 0; d--)
          (label: (10 + d / 10).toStringAsFixed(1), count: counts[d] ?? 0),
      ];
    }
    final min = _minRing(a);
    return [
      for (var r = 10; r >= min; r--) (label: '$r', count: a.ringCounts[r] ?? 0),
    ];
  }

  Widget _groupLegend(BuildContext context, ShotAnalytics a, Color accent) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final spread = a.extremeSpreadMm;

    Widget row(String label, String value, {Color? color}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            Text(value, style: theme.textTheme.titleSmall?.copyWith(color: color ?? cs.onSurface)),
          ],
        ),
      );
    }

    final cep50 = a.cepRadiusMm(0.5);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('Смещение СТП', _offsetText(a), color: accent),
        // «Средний разброс» был размытым термином: под разбросом
        // понимают и это, и поперечник. Радиус СТП (Mean Radius) —
        // общепринятое название именно этой величины.
        row('Радиус СТП', '${a.meanRadiusMm.toStringAsFixed(1)} мм'),
        if (cep50 != null) row('Половина в', '${cep50.toStringAsFixed(1)} мм'),
        row(
          'Поперечник',
          spread == null
              ? '— (>${ShotAnalytics.extremeSpreadLimit} выстр.)'
              : '${spread.toStringAsFixed(1)} мм',
        ),
      ],
    );
  }

  String _offsetText(ShotAnalytics a) {
    final mm = a.meanOffsetMm.toStringAsFixed(1);
    final dir = directionName(a.meanPoint);
    return dir == null ? '$mm мм' : '$mm мм $dir';
  }

  String _groupSubtitle(ShotAnalytics a) {
    final spread = a.extremeSpreadMm;
    final base = spread == null
        ? 'Кольца: радиус СТП и половина попаданий'
        : 'Пунктир — поперечник ${spread.toStringAsFixed(1)} мм';
    final dir = directionName(a.meanPoint);
    return dir == null ? base : '$base · снос $dir';
  }

  /// Нижняя граница гистограммы: показываем до самого низкого габарита,
  /// в который реально попадали, но не меньше пяти строк — иначе на
  /// хорошей серии график из двух полос выглядит обрубком.
  int _minRing(ShotAnalytics a) {
    var min = 10;
    for (final e in a.ringCounts.entries) {
      if (e.value > 0 && e.key < min) min = e.key;
    }
    return math.min(min, 6);
  }

  double _ringChartHeight(ShotAnalytics a) {
    final rows = a.allInTen ? 10 : 10 - _minRing(a) + 1;
    return rows * 22.0 + 8;
  }

  Widget _noteCard(BuildContext context, String text) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      color: cs.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }

  Widget _chartCard({required double height, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 14, 10),
        child: SizedBox(height: height, child: child),
      ),
    );
  }
}

/// Описание графика динамики для конкретного среза.
class AnalyticsDynamics {
  final String title;
  final String subtitle;

  /// Подписи по оси X — по одной на точку. `null` — порядковый номер.
  final List<String>? xLabels;

  /// Рисовать подписи X вертикально: даты в строку не помещаются.
  final bool verticalXLabels;

  /// Точки графика. `ScoreGraphPainter` принимает `List<Shot>`, поэтому
  /// для срезов «по тренировкам» сюда кладутся синтетические выстрелы,
  /// у которых `score` — сумма за тренировку (координаты painter'ом не
  /// используются).
  final List<Shot> points;

  final double maxY;

  /// Низ шкалы. `null` — посчитать по точкам (на балл ниже худшей).
  final double? minY;

  const AnalyticsDynamics({
    required this.title,
    required this.subtitle,
    required this.points,
    required this.maxY,
    this.minY,
    this.xLabels,
    this.verticalXLabels = false,
  });

  /// Низ шкалы: заданный явно или вычисленный по точкам.
  ///
  /// Шаг берётся от масштаба ряда: у результатов выстрелов (до 10.9) —
  /// один балл, у сумм за тренировку (сотни) — десять, иначе подрезка
  /// была бы незаметной.
  double get effectiveMinY =>
      minY ?? axisMin(points.map((p) => p.score), step: maxY > 30 ? 10 : 1);
}
