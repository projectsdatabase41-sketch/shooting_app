import 'dart:math' as math;

import 'stats_blocks.dart';
import 'package:provider/provider.dart';
import '../state/app_data_store.dart';
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
import '../i18n/i18n.dart';

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

  /// Срез ограничен ОДНОЙ тренировкой (или одной её серией).
  ///
  /// Знает об этом только экран статистики: у панели нет id тренировки,
  /// выстрел её не хранит. Поэтому признак передаётся снаружи — так на
  /// срезе «Тренировка» из обзора убирается карточка «По месяцам»
  /// (отзыв владельца 22.11, пункт 2: «по месяцам график не нужно — тут
  /// же мы по этой тренировке смотрим»).
  ///
  /// Параметр необязательный: экраны, которые его ещё не передают,
  /// продолжают работать, а панель дополнительно распознаёт такой срез
  /// по динамике.
  final bool sessionScoped;

  const AnalyticsPanel({
    super.key,
    required this.shots,
    required this.face,
    this.dynamics,
    this.showSeries = true,
    this.mixedFacesNote,
    this.sessionScoped = false,
  });

  @override
  State<AnalyticsPanel> createState() => _AnalyticsPanelState();
}

class _AnalyticsPanelState extends State<AnalyticsPanel> {
  /// Текущий режим графика динамики. Живёт в состоянии панели, а не в
  /// родителе: это чисто способ посмотреть на те же данные, менять
  /// срез он не должен.
  int _mode = 0;

  /// Открытая (раскрытая под кнопками) серия. `null` — списка не видно.
  /// Одна за раз: два открытых списка отбрасывают кнопки далеко вниз и на
  /// телефоне уводят весь блок статистики за экран.
  int? _openSeries;

  void _toggleSeries(int seriesNo) {
    setState(() => _openSeries = _openSeries == seriesNo ? null : seriesNo);
  }

  List<Shot> get shots => widget.shots;
  TargetFace get face => widget.face;
  bool get showSeries => widget.showSeries;
  String? get mixedFacesNote => widget.mixedFacesNote;

  // Геттеры showMonths/_sessionScopedSlice удалены вместе с блоком «Обзор»
  // (отзыв владельца 23.11 №3) — нужны они были только ему.

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = AppTheme.accentFor(cs);

    if (shots.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: EmptyState(
          icon: Icons.query_stats,
          text: tr('В этом срезе пока нет выстрелов'),
        ),
      );
    }

    final a = ShotAnalytics(shots, face);
    final modes = widget.dynamics ?? const <AnalyticsDynamics>[];
    final series = a.seriesStats;
    // Режим мог «уехать» за границы, если срез сменился на такой, где
    // вариантов меньше (в одной серии нечего сравнивать по сериям).
    final mode = modes.isEmpty ? 0 : _mode % modes.length;

    final blocks = <(String, Widget)>[
      // Блок «Обзор» (bento: итог, серии, габариты, месяцы) удалён
      // (отзыв владельца 23.11 №3: «убрать из статистики … полностью,
      // они тут лишние»).
      if (modes.isNotEmpty)
        ('dynamics', _block(
          title: modes[mode].title,
          subtitle: modes.length > 1
              ? tr('{p} · нажмите, чтобы сменить', {'p': modes[mode].subtitle})
              : modes[mode].subtitle,
          child: GestureDetector(
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
        )),
      ('dist', _block(
        // У разбивки по десятым подписи нет намеренно: заголовок
        // «Распределение внутри десятки» и сами подписи 10.9…10.0
        // говорят всё сами.
        title: a.allInTen ? tr('Распределение внутри десятки') : tr('Распределение по габаритам'),
        subtitle: '',
        child: _chartCard(
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
      )),
      if (mixedFacesNote != null)
        ('group', _noteCard(context, mixedFacesNote!))
      else
        ('group', _block(
          title: tr('СТП и кучность'),
          subtitle: _groupSubtitle(a),
          child: _chartCard(
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
        )),
      if (showSeries && series.length > 1)
        ('series', _block(
          // Отзыв владельца 22.11, пункт 3: вместо столбчатой диаграммы —
          // ряд кнопок «номер серии · сумма с десятыми»; по нажатию
          // раскрывается список выстрелов этой серии. Средний результат
          // серии больше не пишем: по отзыву он смысла не несёт.
          title: tr('Результат по сериям'),
          subtitle: tr('Нажмите на серию — откроются её выстрелы'),
          child: _SeriesButtons(shots: shots, openSeries: _openSeries, onToggle: _toggleSeries),
        )),
    ];
    blocks.insert(0, ('tiles', _tiles(context, a, accent)));
    final ordered = _ordered(blocks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Горизонтальная ориентация — карточки в два столбца вместо
        // одной длинной ленты (решение пользователя): на развёрнутом
        // экране лента графиков уходила далеко за пределы видимого.
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = MediaQuery.orientationOf(context) == Orientation.landscape && constraints.maxWidth > 600;
            if (!wide) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final b in ordered) Padding(padding: const EdgeInsets.only(bottom: 24), child: b.$2)],
              );
            }
            const gap = 16.0;
            final colWidth = (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final b in ordered) SizedBox(width: colWidth, child: b.$2)],
            );
          },
        ),
      ],
    );
  }

  // ---- Порядок и включённость блоков: настраиваются кнопкой в шапке (stats_blocks.dart) ----
  @override
  void initState() {
    super.initState();
    StatsBlocks.revision.addListener(_onBlocksChanged);
  }

  @override
  void dispose() {
    StatsBlocks.revision.removeListener(_onBlocksChanged);
    super.dispose();
  }

  void _onBlocksChanged() {
    if (mounted) setState(() {});
  }

  List<(String, Widget)> _ordered(List<(String, Widget)> blocks) {
    final db = context.read<AppDataStore>().db;
    final pref = StatsBlocks.order(db);
    final out = [for (final b in blocks) if (StatsBlocks.visible(db, b.$1)) b];
    out.sort((x, y) => pref.indexOf(x.$1).compareTo(pref.indexOf(y.$1)));
    return out;
  }

  /// Заголовок + подпись + карточка одним блоком — единица раскладки:
  /// в альбомной ориентации такие блоки идут по два в ряд (см. build()).
  Widget _block({required String title, required String subtitle, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title, subtitle: subtitle),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _tiles(BuildContext context, ShotAnalytics a, Color accent) {
    // Отзыв владельца 22.11, пункт 5: плитки «Выстрелов» больше нет — она
    // повторяла размер среза, который и так виден по графикам. Три
    // оставшиеся плитки идут 2 + 1: три в ряд на телефоне не помещаются
    // (значение «27.3 / 273» уже переносилось).
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.functions,
                label: tr('Сумма'),
                value: '${a.total.toStringAsFixed(1)} / ${a.totalWhole}',
                hint: tr('с десятыми / целыми'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatTile(
                icon: Icons.speed_outlined,
                label: tr('Средний'),
                value: a.average.toStringAsFixed(2),
                hint: tr('мин {p} · макс {p2}', {'p': a.worst.toStringAsFixed(1), 'p2': a.best.toStringAsFixed(1)}),
                accent: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              // Счётчик десяток заменён на отклонение СТП по осям: у
              // стрелка, который кладёт всё в десятку, счётчик всегда
              // равен числу выстрелов и не говорит ни о чём. А X и Y —
              // это прямо поправка, которую надо ввести прицелом.
              child: StatTile(
                icon: Icons.control_camera_outlined,
                label: tr('Отклонение СТП'),
                value: mixedFacesNote != null ? '—' : _meanXyText(a),
                // Под цифрами — «X / Y», а не словами: порядок величин
                // важнее их пересказа, а сторону показывает стрелка
                // рядом с числами.
                hint: mixedFacesNote != null ? tr('мишени разные') : 'X / Y',
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
        row(tr('Смещение СТП'), _offsetText(a), color: accent),
        // «Средний разброс» был размытым термином: под разбросом
        // понимают и это, и поперечник. Радиус СТП (Mean Radius) —
        // общепринятое название именно этой величины.
        row(tr('Радиус СТП'), tr('{p} мм', {'p': a.meanRadiusMm.toStringAsFixed(1)})),
        if (cep50 != null) row(tr('Половина в'), tr('{p} мм', {'p': cep50.toStringAsFixed(1)})),
        row(
          tr('Поперечник'),
          spread == null
              ? tr('— (>{extremeSpreadLimit} выстр.)', {'extremeSpreadLimit': ShotAnalytics.extremeSpreadLimit})
              : tr('{p} мм', {'p': spread.toStringAsFixed(1)}),
        ),
      ],
    );
  }

  String _offsetText(ShotAnalytics a) {
    final mm = a.meanOffsetMm.toStringAsFixed(1);
    final dir = directionArrow(a.meanPoint);
    return dir == null ? tr('{mm} мм', {'mm': mm}) : tr('{mm} мм {dir}', {'mm': mm, 'dir': dir});
  }

  String _groupSubtitle(ShotAnalytics a) {
    final spread = a.extremeSpreadMm;
    final base = spread == null
        ? tr('Кольца: радиус СТП и половина попаданий')
        : tr('Пунктир — поперечник {p} мм', {'p': spread.toStringAsFixed(1)});
    final dir = directionArrow(a.meanPoint);
    return dir == null ? base : tr('{base} · снос {dir}', {'base': base, 'dir': dir});
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

/// Ряд кнопок «номер серии · сумма» с раскрывающимся списком выстрелов.
///
/// Заменил столбчатую диаграмму среднего по сериям (отзыв владельца 22.11,
/// пункт 3: «серии — лучше делать кнопочками результатом с десятыми, а при
/// нажатии откроется список по выстрелам (среднее нет смысла писать),
/// кнопки в строчку друг за другом»). Сумма подписана прямо на кнопке
/// (пункт 4 отзыва): столбцов, над которыми раньше стояли значения, больше
/// нет, поэтому подпись переехала на кнопку.
class _SeriesButtons extends StatelessWidget {
  final List<Shot> shots;

  /// Номер открытой серии; `null` — список выстрелов не показан.
  final int? openSeries;

  /// Переключение открытой серии — состоянием владеет панель, чтобы
  /// перерисовки блока не сбрасывали выбор при смене среза.
  final ValueChanged<int> onToggle;

  const _SeriesButtons({
    required this.shots,
    required this.openSeries,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // Группировка та же, что в `ShotAnalytics.seriesStats`, но здесь нужны
    // сами выстрелы: серия выводится списком по номеру выстрела.
    final bySeries = <int, List<Shot>>{};
    for (final s in shots) {
      bySeries.putIfAbsent(s.seriesNo, () => []).add(s);
    }
    final nos = bySeries.keys.toList()..sort();
    if (nos.isEmpty) return const SizedBox.shrink();

    // Открытая серия может исчезнуть вместе со сменой среза — тогда
    // показываем только кнопки, а не падаем на null.
    final openRow = openSeries == null ? null : bySeries[openSeries];
    final opened = openRow == null ? const <Shot>[] : ([...openRow]..sort((x, y) => x.shotNumber.compareTo(y.shotNumber)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Кнопки идут друг за другом с переносом: серий бывает и шесть,
            // и десять, а `Row` на телефоне даёт переполнение.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final n in nos) _seriesButton(context, n, bySeries[n]!),
              ],
            ),
            if (opened.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                tr('Выстрелы серии {n}', {'n': openSeries}),
                style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              for (final s in opened) _shotRow(context, s),
            ],
          ],
        ),
      ),
    );
  }

  /// Кнопка серии: номер и сумма с десятыми. Нажатая подсвечивается
  /// акцентом темы — иначе непонятно, к какой кнопке относится список ниже.
  Widget _seriesButton(BuildContext context, int seriesNo, List<Shot> row) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sum = row.fold<double>(0, (acc, s) => acc + s.score);
    final active = openSeries == seriesNo;

    return OutlinedButton(
      onPressed: () => onToggle(seriesNo),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        foregroundColor: active ? cs.primary : cs.onSurface,
        backgroundColor: active ? cs.primary.withValues(alpha: 0.14) : null,
        side: BorderSide(
          color: active ? cs.primary : cs.outlineVariant.withValues(alpha: 0.6),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusMedium)),
      ),
      child: Text(
        // Номер серии и сумма с десятыми — «1 · 105.2» (пункт 3 отзыва).
        '$seriesNo · ${sum.toStringAsFixed(1)}',
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  /// Строка списка: номер выстрела, результат и — если координаты реально
  /// есть — X/Y в мм. У синтетических точек координат нет, поэтому нули
  /// не печатаем: «0.0 / 0.0 мм» читалось бы как настоящая пробоина в
  /// центре.
  Widget _shotRow(BuildContext context, Shot s) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final base = theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final hasMm = s.xMm != 0 || s.yMm != 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text('${s.shotNumber}', style: base?.copyWith(color: cs.onSurfaceVariant)),
          ),
          SizedBox(
            width: 46,
            child: Text(
              s.score.toStringAsFixed(1),
              style: base?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              hasMm ? tr('{x} / {y} мм', {'x': _signed(s.xMm), 'y': _signed(s.yMm)}) : '',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: base?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// Знак координаты: плюс показываем явно, минус — типографский (в столбце
  /// цифр дефис читается как перенос). Порог 0.05 — как в `_meanXyText`.
  static String _signed(double v) {
    final s = v.abs().toStringAsFixed(1);
    if (v > 0.05) return '+$s';
    if (v < -0.05) return '−$s';
    return '0.0';
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
