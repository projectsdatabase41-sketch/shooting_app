import 'package:flutter/material.dart';

import '../logic/shot_analytics.dart';
import '../i18n/i18n.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../painters/bento_painters.dart';
import '../theme/app_theme.dart';
import 'analytics_panel.dart' show AnalyticsDynamics;

/// «Обзор» статистики четырьмя карточками — перенос промпта AnalyticsBento
/// (см. `docs/ui-prompts-map.md`).
///
/// Зачем отдельный блок, если графики уже есть: старые блоки отвечают на
/// «покажи динамику», а этот — на «как выглядит картина целиком за один
/// взгляд». Данные не выдумываются: всё считается из тех же выстрелов, что
/// и остальная панель, поэтому обзор не может разойтись с графиками.
///
/// Раскладка: одна колонка до 720 px, дальше 2×2 (5+7 / 7+5 из 12 колонок,
/// как в референсе). Внутри панели статистики блок обычно получает
/// половину ширины даже на десктопе, поэтому 2×2 включается только когда
/// места действительно много.
class AnalyticsBento extends StatefulWidget {
  final List<Shot> shots;

  /// Мишень среза — нужна аналитике для расчёта габаритов и средних.
  final TargetFace face;

  /// Динамика среза (первый режим — базовая линия для карточки «Итог»).
  final List<AnalyticsDynamics>? dynamics;

  /// Показывать карточку «По месяцам» (радар).
  ///
  /// Отзыв владельца 22.11, пункт 2: «по месяцам график не нужно — тут же
  /// мы по этой тренировке смотрим». На срезе одной тренировки радар
  /// вырождается в одну дату, поэтому `AnalyticsPanel` передаёт сюда
  /// `false`, когда срез ограничен одной тренировкой.
  final bool showMonths;

  const AnalyticsBento({
    super.key,
    required this.shots,
    required this.face,
    this.dynamics,
    this.showMonths = true,
  });

  @override
  State<AnalyticsBento> createState() => _AnalyticsBentoState();
}

class _AnalyticsBentoState extends State<AnalyticsBento> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void initState() {
    super.initState();
    _ctl.forward();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = AppTheme.accentFor(cs);
    final data = BentoData.from(
      shots: widget.shots,
      face: widget.face,
      dynamics: widget.dynamics,
      cs: cs,
      accent: accent,
    );

    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final child = LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final wide = w >= 720;
        final gap = wide ? 16.0 : 12.0;

        // Отзыв 22.11, пункт 6: «обзор график не работает». Пустое поле в
        // «Итоге» читалось ровно так. Поэтому при нуле точек — подсказка,
        // при одной — точка по центру (BentoTrendPainter это уже умеет),
        // и только от двух точек — линия.
        final trendChart = data.trend.isEmpty
            ? _placeholder(theme, tr('Мало данных'))
            : CustomPaint(
                painter: BentoTrendPainter(
                  values: data.trend,
                  lineColor: accent,
                  fillColor: accent.withValues(alpha: 0.30),
                  gridColor: cs.outlineVariant.withValues(alpha: 0.55),
                ),
                child: const SizedBox.expand(),
              );

        final trend = _Card(
          wide: wide,
          title: tr('Итог'),
          value: data.trendValue == null ? '—' : _num(data.trendValue!),
          delta: data.delta,
          caption: data.trendCaption,
          height: wide ? 132 : 112,
          child: trendChart,
        );

        final waves = _Card(
          wide: wide,
          title: tr('По сериям'),
          value: data.waveValue == null ? '—' : _num(data.waveValue!),
          caption: tr('средний выстрел · текущая и прошлая серия'),
          height: wide ? 132 : 112,
          child: data.waves.isEmpty
              ? _placeholder(theme, tr('Нужны хотя бы две серии'))
              : CustomPaint(
                  painter: BentoWavesPainter(
                    series: data.waves,
                    colors: [accent, cs.onSurfaceVariant.withValues(alpha: 0.55)],
                    gridColor: cs.outlineVariant.withValues(alpha: 0.55),
                    labels: data.waveLabels,
                    labelStyle: _small(theme, cs, 9),
                  ),
                  child: const SizedBox.expand(),
                ),
        );

        final treemap = _Card(
          wide: wide,
          title: data.allInTen ? tr('Внутри десятки') : tr('Габариты'),
          caption: tr('площадь — доля выстрелов'),
          height: wide ? 168 : 148,
          child: data.slices.isEmpty
              ? _placeholder(theme, tr('Нет выстрелов'))
              : CustomPaint(
                  painter: BentoTreemapPainter(
                    items: data.slices,
                    emptyColor: cs.surfaceContainerHigh,
                    labelStyle: _small(theme, cs, 10),
                    valueStyle: _small(theme, cs, 16, weight: FontWeight.w700),
                  ),
                  child: const SizedBox.expand(),
                ),
        );

        final radar = _Card(
          wide: wide,
          title: tr('По месяцам'),
          value: data.monthAverage == null ? '—' : _num(data.monthAverage!),
          caption: tr('средний выстрел за месяц'),
          height: wide ? 200 : 190,
          child: data.months.length < 3
              ? _placeholder(theme, tr('Мало данных по месяцам'))
              : CustomPaint(
                  painter: BentoRadarPainter(
                    values: data.months,
                    labels: data.monthLabels,
                    lineColor: accent,
                    fillColor: accent.withValues(alpha: 0.22),
                    gridColor: cs.outlineVariant.withValues(alpha: 0.6),
                    labelStyle: _small(theme, cs, 9),
                  ),
                  child: const SizedBox.expand(),
                ),
        );

        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              trend,
              SizedBox(height: gap),
              waves,
              SizedBox(height: gap),
              treemap,
              if (widget.showMonths) ...[
                SizedBox(height: gap),
                radar,
              ],
            ],
          );
        }

        // 12 колонок: 5+7 в первом ряду, 7+5 во втором — как в промпте.
        // Без карточки месяцев второй ряд занимает вся ширина: одна
        // карточка на 7 из 12 колонок оставляла бы пустую дырку.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 5, child: trend),
              SizedBox(width: gap),
              Expanded(flex: 7, child: waves),
            ]),
            SizedBox(height: gap),
            if (!widget.showMonths)
              treemap
            else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 7, child: treemap),
                SizedBox(width: gap),
                Expanded(flex: 5, child: radar),
              ]),
          ],
        );
      },
    );

    if (reduceMotion) return child;
    // Одна анимация на весь блок: на вебе (CanvasKit) анимации по карточкам
    // дают несколько одновременных слоёв, а тут двигается один контейнер.
    return FadeTransition(
      opacity: CurvedAnimation(parent: _ctl, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.012), end: Offset.zero)
            .animate(CurvedAnimation(parent: _ctl, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  Widget _placeholder(ThemeData theme, String text) {
    return Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// Мелкий текст графиков. `labelSmall` в теме может быть не задан —
  /// берём его с запасным значением, а не через `!`.
  static TextStyle _small(ThemeData theme, ColorScheme cs, double size, {FontWeight? weight, Color? color}) {
    return (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
      color: color ?? cs.onSurfaceVariant,
      fontSize: size,
      fontWeight: weight,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  /// Число без хвостового нуля: «287», а не «287.0».
  static String _num(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }
}

/// Карточка обзора: заголовок, крупное число, необязательная дельта,
/// подпись и график. График — всегда `CustomPaint`, без сторонних библиотек.
class _Card extends StatelessWidget {
  final bool wide;
  final String title;
  final String? value;
  final double? delta;
  final String caption;
  final double height;
  final Widget child;

  /// Порог показа дельты: половина десятой. Всё, что меньше, при
  /// округлении до одного знака даёт «0» (отзыв 22.11, пункт 1).
  static const double _deltaMin = 0.05;

  const _Card({
    required this.wide,
    required this.title,
    this.value,
    this.delta,
    required this.caption,
    required this.height,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final gap = wide ? 18.0 : 14.0;

    return Container(
      padding: EdgeInsets.all(gap),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Отзыв владельца 22.11, пункт 1: рядом с числом рисовался
              // лишний «0». Дельта меньше половины десятой при
              // округлении до одного знака даёт именно «0», а нулевая
              // дельта не говорит ни о росте, ни о падении — чип не
              // показываем вовсе.
              if (delta != null && delta!.abs() >= _deltaMin) _deltaChip(context, delta!),
            ],
          ),
          if (value != null) ...[
            const SizedBox(height: 6),
            Text(
              value!,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: cs.onSurface,
              ),
            ),
          ],
          const SizedBox(height: 2),
          Text(
            caption,
            style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: wide ? 12 : 8),
          SizedBox(height: height, child: child),
        ],
      ),
    );
  }

  /// Дельта: знак и цвет — по направлению. «Рост» и «падение» в стрельбе
  /// означают очки, а не деньги, поэтому цвета берём из темы: рост —
  /// tertiary (зелёный), падение — error.
  Widget _deltaChip(BuildContext context, double d) {
    final cs = Theme.of(context).colorScheme;
    final up = d > 0.0001;
    final down = d < -0.0001;
    final color = up ? cs.tertiary : (down ? cs.error : cs.onSurfaceVariant);
    final text = (up ? '+' : down ? '−' : '') + _AnalyticsBentoState._num(d.abs());
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}

/// Данные обзора, посчитанные из выстрелов среза.
class BentoData {
  /// Ряд динамики (очки по точкам среза).
  final List<double> trend;
  final double? trendValue;
  final double? delta;
  final String trendCaption;

  /// [текущая, предыдущая] серии — по ним рисуются «волны».
  final List<List<double>> waves;
  final List<String> waveLabels;
  final double? waveValue;

  final List<BentoSlice> slices;
  final bool allInTen;

  /// Средние по месяцам, только месяцы, где были выстрелы.
  final List<double> months;
  final List<String> monthLabels;
  final double? monthAverage;

  const BentoData({
    required this.trend,
    required this.trendValue,
    required this.delta,
    required this.trendCaption,
    required this.waves,
    required this.waveLabels,
    required this.waveValue,
    required this.slices,
    required this.allInTen,
    required this.months,
    required this.monthLabels,
    required this.monthAverage,
  });

  factory BentoData.from({
    required List<Shot> shots,
    required TargetFace face,
    required List<AnalyticsDynamics>? dynamics,
    required ColorScheme cs,
    required Color accent,
  }) {
    final a = ShotAnalytics(shots, face);
    final allInTen = a.allInTen;

    // --- Динамика ---
    final modes = dynamics ?? const <AnalyticsDynamics>[];
    final trend = <double>[
      if (modes.isNotEmpty) for (final p in modes.first.points) p.score,
    ];
    final trendValue = trend.isEmpty ? null : trend.last;
    final delta = trend.length >= 2 ? trend.last - trend[trend.length - 2] : null;
    // Подпись повторяет то, что видно на графике: пустой ряд — «мало
    // данных», одна точка — «пока одна точка» (отзыв 22.11, пункт 6).
    final trendCaption = trend.isEmpty
        ? tr('мало данных')
        : (trend.length < 2 ? tr('пока одна точка') : tr('к предыдущей точке'));

    // --- Серии ---
    final bySeries = <int, List<Shot>>{};
    for (final s in shots) {
      bySeries.putIfAbsent(s.seriesNo, () => []).add(s);
    }
    final seriesNos = bySeries.keys.toList()..sort();
    final waves = <List<double>>[];
    var waveLabels = <String>[];
    double? waveValue;
    if (seriesNos.isNotEmpty) {
      final last = bySeries[seriesNos.last]!..sort((x, y) => x.shotNumber.compareTo(y.shotNumber));
      final lastValues = [for (final s in last) s.score];
      waves.add(lastValues);
      waveLabels = [for (final s in last) '${s.shotNumber}'];
      waveValue = lastValues.isEmpty ? null : lastValues.reduce((x, y) => x + y) / lastValues.length;
      if (seriesNos.length >= 2) {
        final prev = bySeries[seriesNos[seriesNos.length - 2]]!
          ..sort((x, y) => x.shotNumber.compareTo(y.shotNumber));
        waves.add([for (final s in prev) s.score]);
      }
    }

    // --- Габариты ---
    //
    // Если все выстрелы легли в десятку, разбивка по габаритам выродилась
    // бы в один прямоугольник — раскладываем десятку на десятые, как это
    // уже делает гистограмма в панели.
    final List<BentoSlice> slices;
    if (allInTen) {
      final dec = a.tenDecimalCounts;
      final keys = dec.keys.where((d) => (dec[d] ?? 0) > 0).toList()..sort((x, y) => y.compareTo(x));
      slices = [
        for (final d in keys)
          BentoSlice(
            label: (10 + d / 10).toStringAsFixed(1),
            value: dec[d]!,
            color: _sliceColor(cs, accent, keys.indexOf(d), keys.length),
          ),
      ];
    } else {
      final counts = a.ringCounts;
      final rings = counts.keys.where((r) => (counts[r] ?? 0) > 0).toList()..sort((x, y) => y.compareTo(x));
      slices = [
        for (var i = 0; i < rings.length; i++)
          BentoSlice(
            label: '${rings[i]}',
            value: counts[rings[i]]!,
            color: _sliceColor(cs, accent, i, rings.length),
          ),
      ];
    }

    // --- Месяцы ---
    final monthsMap = <int, List<double>>{};
    for (final s in shots) {
      final key = s.time.year * 12 + s.time.month;
      monthsMap.putIfAbsent(key, () => []).add(s.score);
    }
    final keys = monthsMap.keys.toList()..sort();
    final recent = keys.length > 12 ? keys.sublist(keys.length - 12) : keys;
    final months = [for (final k in recent) _avg(monthsMap[k]!)];
    final monthLabels = [for (final k in recent) _monthShort(k % 12 == 0 ? 12 : k % 12)];
    final monthAverage = months.isEmpty ? null : _avgWeighted(monthsMap, recent);

    return BentoData(
      trend: trend,
      trendValue: trendValue,
      delta: delta,
      trendCaption: trendCaption,
      waves: waves,
      waveLabels: waveLabels,
      waveValue: waveValue,
      slices: slices,
      allInTen: allInTen,
      months: months,
      monthLabels: monthLabels,
      monthAverage: monthAverage,
    );
  }

  /// Цвет плитки: первая (лучшая) — янтарь, дальше плавно к цвету
  /// поверхности. В референсе у каждой категории был свой кислотный цвет;
  /// в приложении палитра из четырёх цветов темы, и «радуга» выглядела бы
  /// чужой.
  static Color _sliceColor(ColorScheme cs, Color accent, int index, int total) {
    if (total <= 1) return Color.lerp(cs.surfaceContainerHighest, accent, 0.7)!;
    final t = 1 - index / (total - 1); // 1 — лучшая плитка
    return Color.lerp(cs.surfaceContainerHighest, accent, 0.25 + t * 0.6)!;
  }

  static double _avg(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  /// Средний выстрел по месяцам — по всем выстрелам, а не по средним
  /// значений месяцев: месяц с одним выстрелом не должен весить столько
  /// же, сколько месяц с сотней.
  static double _avgWeighted(Map<int, List<double>> map, List<int> keys) {
    var sum = 0.0;
    var n = 0;
    for (final k in keys) {
      for (final v in map[k]!) {
        sum += v;
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  static String _monthShort(int m) {
    const ru = ['янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
    return tr(ru[(m - 1).clamp(0, 11)]);
  }
}
