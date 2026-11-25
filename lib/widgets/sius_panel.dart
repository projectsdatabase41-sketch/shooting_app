import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../logic/scoring.dart';
import '../models/target_face.dart';

/// Стрелка смещения выстрела от центра — как в списке на SIUS-мониторе
/// (фото владельца 24.11: «50 ↘ 10.1», «59 ↑ 9.6»). Восемь направлений;
/// в «мёртвой зоне» у центра — точка, чтобы стрелки не прыгали на
/// десятых долях миллиметра. [deadZoneMm] — радиус, внутри которого
/// направление считается незначимым.
String siusDirectionArrow(Offset pointMm, {double deadZoneMm = 1.0}) {
  if (pointMm.distance < deadZoneMm) return '·';
  final deg = (math.atan2(pointMm.dy, pointMm.dx) * 180 / math.pi + 360) % 360;
  final oct = (deg / 45).round() % 8;
  return const ['→', '↗', '↑', '↖', '←', '↙', '↓', '↘'][oct];
}

/// Один элемент списка выстрелов панели «как SIUS».
///
/// Значение [score] и точка [point] уже посчитаны вызывающим (финалы
/// хранят `RunShot`, тренировки — `Shot`, общего типа на оба нет).
/// [series] — номер серии с 1; 0 — выстрел вне серий (одиночные на
/// выбывание в финалах, выстрелы сверх описания упражнения).
class SiusShotRow {
  final int number; // сквозной номер выстрела, с 1
  final int series; // номер серии, с 1; 0 — вне серий
  final double score;
  final Offset point; // мм от центра мишени, y вверх
  final bool sighting; // пристрелочный — в зачёт не идёт

  const SiusShotRow({
    required this.number,
    required this.series,
    required this.score,
    required this.point,
    this.sighting = false,
  });
}

/// Информационная панель горизонтального режима «как SIUS» (запрос
/// владельца 24.11 по фото SIUS-дисплея, 50 м винтовка).
///
/// Состав: заголовок (название, «Серия N из M», общее время и обратный
/// отсчёт), список выстрелов строкой «№ · значение · отметка серии»
/// (последний выстрел подсвечен, автопрокрутка к нему), крупно справа —
/// результат последнего выстрела и «Σ 628.4 — 12» (сумма и число
/// центральных — inner ten по евклидову радиусу точки попадания,
/// владелец 24.11 — после тире), внизу — суммы завершённых серий.
///
/// Режим [lastFiveMode] (пристрелка): вместо сумм серий и Σ — сумма
/// «последних 5» и MPI пяти последних выстрелов в мм от центра, как в
/// нижней строке SIUS-монитора при пристрелке.
///
/// Стиль — панель как на SIUS, но цвета только из `colorScheme` темы:
/// тёмная в тёмной теме, светлая — в светлой. Цифры — tabular figures,
/// чтобы суммы не «плясали» при смене разрядов.
class SiusPanel extends StatefulWidget {
  final TargetFace face;

  /// Строки списка, по порядку стрельбы; новые добавляются снизу.
  final List<SiusShotRow> shots;

  /// Название упражнения/мишени для заголовка.
  final String title;

  /// Подпись текущей серии («Серия 2 из 6») — собирается снаружи, потому
  /// что в финалах бывают одиночные и перестрелка вне серий.
  final String? seriesLabel;

  /// Показания времени («12:30»), отформатированы снаружи: у финала это
  /// время упражнения, у истории — прошедшее время тренировки.
  final String? timeText;

  /// Обратный отсчёт («1:45»); `null` — не показывать (в истории его нет).
  final String? countdownText;

  /// Сколько выстрелов в каждой серии. `null` — границы серий считаются
  /// по смене номера серии в [shots] (упражнения без описания серий).
  final List<int>? seriesShots;

  /// Режим пристрелки: последние 5 выстрелов + MPI вместо сумм и Σ.
  /// В этом режиме подсчёт идёт по ПРИСТРЕЛОЧНЫМ строкам (на SIUS пробные
  /// выстрелы «P» и есть пристрелка: их 5 штук и по ним считается MPI);
  /// если пристрелочных нет — по зачётным, чтобы режим не молчал впустую.
  final bool lastFiveMode;

  const SiusPanel({
    super.key,
    required this.face,
    required this.shots,
    required this.title,
    this.seriesLabel,
    this.timeText,
    this.countdownText,
    this.seriesShots,
    this.lastFiveMode = false,
  });

  @override
  State<SiusPanel> createState() => _SiusPanelState();
}

class _SiusPanelState extends State<SiusPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Новые выстрелы приходят снизу: как только список вырос, едем к
  /// последней строке — SIUS-монитор всегда показывает текущий выстрел.
  void _scrollToLast() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || !mounted) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  // ---- Подсчёты ----------------------------------------------------------

  List<SiusShotRow> get _counting =>
      [for (final s in widget.shots) if (!s.sighting) s];

  List<SiusShotRow> get _sighting =>
      [for (final s in widget.shots) if (s.sighting) s];

  /// Данные «последних пяти»: в режиме пристрелки — пристрелочные
  /// выстрелы, иначе зачётные (см. комментарий к [SiusPanel.lastFiveMode]).
  List<SiusShotRow> get _lastFiveBase {
    final sight = _sighting;
    if (widget.lastFiveMode && sight.isNotEmpty) return sight;
    return _counting;
  }

  /// Ключ группировки строк списка: пристрелочные — отдельная группа,
  /// чтобы их метки 'P' не рвали нумерацию серий (как на SIUS, где
  /// пробные выстрелы помечены «P», а серия начинается после них).
  int _groupOf(SiusShotRow s) => s.sighting ? -1 : s.series;

  /// Серия «завершена»: набран лимит выстрелов (если он известен) или
  /// началась следующая серия. Пристрелка ни в каком виде не считается.
  bool _seriesComplete(int series, int countInSeries) {
    if (widget.shots.any((s) => !s.sighting && s.series > series)) return true;
    final limits = widget.seriesShots;
    if (limits == null || series < 1 || series > limits.length) return false;
    return countInSeries >= limits[series - 1];
  }

  /// Сумма по каждой завершённой серии: «S1 104.5 · S2 105.2 …».
  String get _seriesSumsText {
    final sumBySeries = <int, double>{};
    final countBySeries = <int, int>{};
    for (final s in _counting) {
      sumBySeries[s.series] = (sumBySeries[s.series] ?? 0) + s.score;
      countBySeries[s.series] = (countBySeries[s.series] ?? 0) + 1;
    }
    final parts = <String>[];
    for (final series in sumBySeries.keys.toList()..sort()) {
      if (series > 0 &&
          _seriesComplete(series, countBySeries[series] ?? 0)) {
        parts.add('S$series ${sumBySeries[series]!.toStringAsFixed(1)}');
      }
    }
    return parts.join(' · ');
  }

  /// Итог под последним выстрелом: «Σ 628.4 — 12», число после тире —
  /// количество центральных выстрелов (геометрический критерий inner ten
  /// по точкам попадания, владелец 24.11 — см. `logic/scoring.dart`).
  String? get _sigmaText {
    final all = _counting;
    if (all.isEmpty) return null;
    final total = 0.0 + all.fold(0.0, (a, s) => a + s.score);
    final central = countInnerTenPoints(
        [for (final s in all) (s.point.dx, s.point.dy)], widget.face);
    return 'Σ ${total.toStringAsFixed(1)} — $central';
  }

  /// Пристрелочный блок: сумма и MPI последних пяти выстрелов в мм от
  /// центра (владелец 24.11: вместо суммы серий и общего результата).
  ({String sum, String mpi})? get _lastFive {
    final all = _lastFiveBase;
    if (all.isEmpty) return null;
    final last = all.length > 5 ? all.sublist(all.length - 5) : all;
    final sum = last.fold(0.0, (a, s) => a + s.score);
    // MPI — центр масс последних выстрелов по осям, мм; y вверх, поэтому
    // «вниз» на дисплее — отрицательный dy, стрелки ставятся по знаку.
    // На фото владельца 24.11 пара выглядит как «↔0.9 ↓1.6»; стрелки
    // направления («→», «↓») читаются однозначнее, формат сохранён.
    final meanX = last.fold(0.0, (a, s) => a + s.point.dx) / last.length;
    final meanY = last.fold(0.0, (a, s) => a + s.point.dy) / last.length;
    final h = meanX.abs() < 0.05
        ? '↔'
        : meanX > 0 ? '→' : '←';
    final v = meanY.abs() < 0.05
        ? '↕'
        : meanY > 0 ? '↑' : '↓';
    final hText = '${meanX.abs() < 0.05 ? '' : h}${meanX.abs().toStringAsFixed(1)}';
    final vText = '${meanY.abs() < 0.05 ? '' : v}${meanY.abs().toStringAsFixed(1)}';
    return (
      sum: tr('Последние {n}: {sum}',
          {'n': last.length, 'sum': sum.toStringAsFixed(1)}),
      mpi: tr('MPI ({n}): {h} {v}', {'n': last.length, 'h': hText, 'v': vText}),
    );
  }

  int countIn(int series) {
    var n = 0;
    for (final s in widget.shots) {
      if (!s.sighting && s.series == series) n++;
    }
    return n;
  }

  // ---- Отрисовка ---------------------------------------------------------

  List<Widget> _listChildren(ThemeData theme, ColorScheme cs) {
    final children = <Widget>[];
    if (widget.shots.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Text(
          tr('Выстрелов ещё нет'),
          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ));
      return children;
    }
    for (var i = 0; i < widget.shots.length; i++) {
      final s = widget.shots[i];
      // Смена серии — разделитель «Серия N» (владелец 24.11: «номер серии
      // меняется — разделитель»). Пристрелочные — группа «Пристрелка».
      final prev = i == 0 ? null : widget.shots[i - 1];
      if (i == 0 || _groupOf(s) != _groupOf(prev!)) {
        children.add(_SeriesDivider(
          label: s.sighting
              ? tr('Пристрелка')
              : s.series <= 0
                  ? tr('Одиночные')
                  : tr('Серия {n}', {'n': s.series}),
        ));
      }
      // Отметка серии как на SIUS: 'P' — пристрелочный выстрел; на
      // последнем выстреле ЗАВЕРШЁННОЙ серии — метка «S10»-вида с числом
      // выстрелов в неё (владелец 24.11: «номер, значение, отметка серии
      // P/S10»). У незакрытой серии отметки нет — она ещё не «S».
      final next = i + 1 < widget.shots.length ? widget.shots[i + 1] : null;
      String? mark;
      if (s.sighting) {
        mark = 'P';
      } else if (s.series > 0 &&
          (next == null || _groupOf(next) != s.series) &&
          _seriesComplete(s.series, countIn(s.series))) {
        mark = 'S${countIn(s.series)}';
      }
      final isLast = i == widget.shots.length - 1;
      children.add(_ShotLine(
        row: s,
        mark: mark,
        face: widget.face,
        highlighted: isLast,
      ));
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    TextStyle mono(TextStyle style) =>
        style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

    final last = _counting.isEmpty ? null : _counting.last;
    final sigma = _sigmaText;
    final five = _lastFive;

    _scrollToLast();

    // Цвета — всегда из темы: в тёмной теме панель тёмная, в светлой —
    // светлая (запрос владельца 24.11: «цвета из colorScheme темы»).
    final bg = cs.surfaceContainerHighest;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Заголовок: название, «Серия N из M» и время справа.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(theme.textTheme.titleSmall!
                            .copyWith(fontWeight: FontWeight.w700))),
                    if (widget.seriesLabel != null)
                      Text(widget.seriesLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: mono(theme.textTheme.labelMedium!
                              .copyWith(color: cs.onSurfaceVariant))),
                  ],
                ),
              ),
              if (widget.timeText != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.timer_outlined, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 2),
                Text(widget.timeText!,
                    style: mono(theme.textTheme.labelLarge!
                        .copyWith(fontWeight: FontWeight.w700))),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Обратный отсчёт — крупно (в истории не передаётся).
          if (widget.countdownText != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                widget.countdownText!,
                style: mono(theme.textTheme.headlineSmall!
                    .copyWith(fontWeight: FontWeight.w800, color: cs.primary)),
              ),
            ),
          const SizedBox(height: 6),
          // Список + результат последнего выстрела крупно справа.
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    controller: _scroll,
                    children: _listChildren(theme, cs),
                  ),
                ),
                const SizedBox(width: 10),
                // Правая колонка: результат ПОСЛЕДНЕГО выстрела крупно,
                // под ним «Σ 628.4 — 12»: число после тире — центральные.
                SizedBox(
                  width: 104,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Номер последнего выстрела и его направление — как на
                      // SIUS, где над крупной оценкой стоит «60» (фото 24.11).
                      if (last != null)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '#${last.number} '
                            '${siusDirectionArrow(last.point, deadZoneMm: math.max(0.6, widget.face.caliberRadiusMm * 0.5))}',
                            maxLines: 1,
                            style: mono(theme.textTheme.labelMedium!.copyWith(
                                color: cs.onSurfaceVariant)),
                          ),
                        ),
                      Expanded(
                        child: Center(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              last == null
                                  ? '—'
                                  : formatScore(last.score, widget.face),
                              style: mono(theme.textTheme.displaySmall!
                                  .copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: cs.primary)),
                            ),
                          ),
                        ),
                      ),
                      if (sigma != null && !widget.lastFiveMode)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(sigma,
                              maxLines: 1,
                              style: mono(theme.textTheme.titleMedium!
                                  .copyWith(fontWeight: FontWeight.w700))),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Divider(height: 1, color: cs.outlineVariant),
          const SizedBox(height: 6),
          // Низ: суммы завершённых серий, в пристрелке — последние 5 и MPI.
          SizedBox(
            height: 34,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 2,
              children: [
                if (widget.lastFiveMode) ...[
                  if (five != null)
                    Text(five.sum,
                        style: mono(theme.textTheme.titleMedium!
                            .copyWith(fontWeight: FontWeight.w800))),
                  if (five != null)
                    Text(five.mpi,
                        style: mono(theme.textTheme.bodyMedium!
                            .copyWith(color: cs.onSurfaceVariant))),
                ] else
                  Text(
                    _seriesSumsText.isEmpty ? ' ' : _seriesSumsText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(theme.textTheme.titleMedium!
                        .copyWith(fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Разделитель «Серия N» внутри списка выстрелов.
class _SeriesDivider extends StatelessWidget {
  final String label;
  const _SeriesDivider({required this.label});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2, left: 2),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Строка списка «как SIUS»: № · значение · отметка серии (P/S10).
class _ShotLine extends StatelessWidget {
  final SiusShotRow row;
  final String? mark;
  final TargetFace face;
  final bool highlighted; // текущий (последний) выстрел
  const _ShotLine({
    required this.row,
    required this.mark,
    required this.face,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    TextStyle mono(TextStyle? style) => (style ?? const TextStyle())
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Container(
      color: highlighted ? cs.primary.withValues(alpha: 0.12) : null,
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text('${row.number}',
                maxLines: 1,
                style: mono(theme.textTheme.bodySmall)
                    .copyWith(color: cs.onSurfaceVariant)),
          ),
          SizedBox(
            width: 56,
            child: Text(
              formatScore(row.score, face),
              maxLines: 1,
              style: mono(theme.textTheme.bodyMedium)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          // Смещение от центра — как на SIUS (фото 24.11, отзыв f6cc163e):
          // стрелка стоит между номером и отметкой серии.
          SizedBox(
            width: 16,
            child: Text(
              siusDirectionArrow(row.point, deadZoneMm: math.max(0.6, face.caliberRadiusMm * 0.5)),
              maxLines: 1,
              textAlign: TextAlign.center,
              style: mono(theme.textTheme.bodyMedium)
                  .copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          if (mark != null)
            Text(
              mark!,
              maxLines: 1,
              style: mono(theme.textTheme.labelMedium)
                  .copyWith(fontWeight: FontWeight.w700, color: cs.primary),
            ),
        ],
      ),
    );
  }
}
