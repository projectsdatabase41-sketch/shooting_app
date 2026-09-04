import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../logic/shot_analytics.dart';
import '../models/exercise.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../state/app_data_store.dart';
import '../widgets/analytics_panel.dart';
import '../widgets/empty_state.dart';

/// Вкладка "Статистика" — разбор стрельбы на четырёх срезах
/// (по запросу пользователя: «мало данных, лучше вывести по нескольким
/// графикам: общий, за все тренировки, за упражнения, за конкретную
/// тренировку, за конкретную серию»):
///
/// 1. **Все тренировки** — сводка по всей истории.
/// 2. **Упражнение** — только тренировки выбранного упражнения.
/// 3. **Тренировка** — одна тренировка.
/// 4. **Серия** — одна серия внутри выбранной тренировки.
///
/// Сами графики живут в `AnalyticsPanel` и на всех срезах одни и те же —
/// этот экран только выбирает СПИСОК ВЫСТРЕЛОВ и подписи. Тот же блок
/// открывается с экрана мишени по кнопке "График", поэтому "статистика
/// тренировки" в приложении ровно одна, а не две разные.
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

enum _Scope { all, exercise, session }

class _StatisticsScreenState extends State<StatisticsScreen> {
  _Scope _scope = _Scope.all;
  String? _exerciseId;
  String? _sessionId;

  /// `null` — все серии выбранной тренировки.
  int? _seriesNo;

  /// Окно по датам для срезов «Всё» и «Упражнение». `null` — без
  /// ограничения. Дни, а не «месяц/квартал»: у стрелка тренировки
  /// считаются днями, и «за 30 дней» понятнее, чем «за месяц», когда
  /// месяц начался вчера.
  int? _periodDays;

  static const List<int> _periods = [5, 15, 30, 90];

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();

    // В срезы берём тренировки, где есть хотя бы один выстрел: пустая
    // тренировка не даёт ни одного показателя, а в выпадающем списке
    // только мешает.
    final sessions = store.sessions.where((s) => s.shots.isNotEmpty).toList();

    if (sessions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Статистика')),
        body: const EmptyState(
          icon: Icons.insights_outlined,
          text: 'Статистика появится после первых записанных выстрелов',
        ),
      );
    }

    final selection = _resolveSelection(store, sessions);

    return Scaffold(
      appBar: AppBar(title: const Text('Статистика')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          _scopeSelector(),
          const SizedBox(height: 12),
          ..._scopePickers(store, sessions),
          const SizedBox(height: 4),
          AnalyticsPanel(
            shots: selection.shots,
            face: selection.face,
            dynamics: selection.dynamics,
            showSeries: selection.showSeries,
            mixedFacesNote: selection.mixedFacesNote,
          ),
        ],
      ),
    );
  }

  Widget _scopeSelector() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<_Scope>(
        segments: const [
          ButtonSegment(value: _Scope.all, label: Text('Всё')),
          ButtonSegment(value: _Scope.exercise, label: Text('Упражнение')),
          ButtonSegment(value: _Scope.session, label: Text('Тренировка')),
        ],
        selected: {_scope},
        showSelectedIcon: false,
        onSelectionChanged: (set) => setState(() {
          _scope = set.first;
          _seriesNo = null;
        }),
      ),
    );
  }

  List<Widget> _scopePickers(AppDataStore store, List<TrainingSession> sessions) {
    final df = DateFormat('dd.MM.yyyy HH:mm');

    switch (_scope) {
      case _Scope.all:
        return [_periodSelector(), const SizedBox(height: 12)];

      case _Scope.exercise:
        final ids = sessions.map((s) => s.exerciseId).toSet();
        final exercises = store.exercises.where((e) => ids.contains(e.id)).toList();
        if (exercises.isEmpty) return [_periodSelector(), const SizedBox(height: 12)];
        return [
          DropdownButtonFormField<String>(
            initialValue: _currentExerciseId(exercises),
            // isExpanded — иначе длинное название упражнения не
            // укладывается в ширину поля и Flutter рисует полосатую
            // плашку переполнения поверх макета.
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Упражнение'),
            items: [
              for (final e in exercises)
                DropdownMenuItem(value: e.id, child: Text(e.label, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _exerciseId = v),
          ),
          const SizedBox(height: 12),
          _periodSelector(),
          const SizedBox(height: 12),
        ];

      case _Scope.session:
        final currentId = _currentSessionId(sessions);
        final current = sessions.firstWhere((s) => s.id == currentId);
        final seriesNos = current.shots.map((s) => s.seriesNo).toSet().toList()..sort();
        return [
          DropdownButtonFormField<String>(
            initialValue: currentId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Тренировка'),
            items: [
              for (final s in sessions)
                DropdownMenuItem(
                  value: s.id,
                  child: Text(
                    '${store.exerciseFor(s)?.label ?? 'Без упражнения'} · '
                    '${s.startedAt == null ? '—' : df.format(s.startedAt!)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() {
              _sessionId = v;
              _seriesNo = null;
            }),
          ),
          const SizedBox(height: 12),
          if (seriesNos.length > 1) ...[
            DropdownButtonFormField<int>(
              initialValue: seriesNos.contains(_seriesNo) ? _seriesNo : null,
              decoration: const InputDecoration(labelText: 'Серия'),
              items: [
                const DropdownMenuItem<int>(value: null, child: Text('Все серии')),
                for (final n in seriesNos) DropdownMenuItem(value: n, child: Text('Серия $n')),
              ],
              onChanged: (v) => setState(() => _seriesNo = v),
            ),
            const SizedBox(height: 12),
          ],
        ];
    }
  }

  /// Кнопки периода: 5 / 15 / 30 / 90 дней и «всё».
  Widget _periodSelector() {
    return Wrap(
      spacing: 8,
      children: [
        ChoiceChip(
          label: const Text('Всё время'),
          selected: _periodDays == null,
          onSelected: (_) => setState(() => _periodDays = null),
        ),
        for (final d in _periods)
          ChoiceChip(
            label: Text('$d дн.'),
            selected: _periodDays == d,
            onSelected: (_) => setState(() => _periodDays = d),
          ),
      ],
    );
  }

  /// Отсекает тренировки старше выбранного периода.
  ///
  /// Тренировки без даты старта не выбрасываем: у них нет времени, по
  /// которому судить, а молча терять записи хуже, чем показать лишнюю.
  List<TrainingSession> _inPeriod(List<TrainingSession> sessions) {
    final days = _periodDays;
    if (days == null) return sessions;
    final from = DateTime.now().subtract(Duration(days: days));
    return sessions.where((s) => s.startedAt == null || s.startedAt!.isAfter(from)).toList();
  }

  String? _currentExerciseId(List<Exercise> available) {
    if (available.isEmpty) return null;
    final id = _exerciseId;
    if (id != null && available.any((e) => e.id == id)) return id;
    return available.first.id;
  }

  String _currentSessionId(List<TrainingSession> sessions) {
    final id = _sessionId;
    if (id != null && sessions.any((s) => s.id == id)) return id;
    return sessions.last.id;
  }

  /// Собирает выстрелы и подписи выбранного среза.
  _Selection _resolveSelection(AppDataStore store, List<TrainingSession> sessions) {
    switch (_scope) {
      case _Scope.all:
        return _sessionsSelection(
          _inPeriod(sessions),
          title: 'Динамика тренировок',
          subtitle: 'Сумма очков за тренировку',
        );

      case _Scope.exercise:
        final ids = sessions.map((s) => s.exerciseId).toSet();
        final exercises = store.exercises.where((e) => ids.contains(e.id)).toList();
        final exId = _currentExerciseId(exercises);
        final filtered = sessions.where((s) => s.exerciseId == exId).toList();
        return _sessionsSelection(
          _inPeriod(filtered.isEmpty ? sessions : filtered),
          title: 'Динамика по упражнению',
          subtitle: 'Сумма очков за тренировку',
        );

      case _Scope.session:
        final session = sessions.firstWhere((s) => s.id == _currentSessionId(sessions));
        final face = TargetFace.byCode(session.targetFaceCode);
        final all = session.countingShots;
        final shots = _seriesNo == null ? all : all.where((s) => s.seriesNo == _seriesNo).toList();
        return _Selection(
          shots: shots,
          face: face,
          showSeries: _seriesNo == null,
          dynamics: shots.isEmpty
              ? null
              : [
                  AnalyticsDynamics(
                    title: _seriesNo == null ? 'Динамика выстрелов' : 'Динамика серии $_seriesNo',
                    subtitle: '',
                    points: shots,
                    maxY: 10.9,
                  ),
                  // Накопленная сумма для мастера всегда уверенно
                  // ползёт вверх, и провал в ней не виден вовсе.
                  // Скользящее среднее по пяти выстрелам проседает
                  // сразу — ради этого график и нужен.
                  _movingAverage(shots),
                ],
        );
    }
  }

  /// Срез из нескольких тренировок: выстрелы всех тренировок вместе,
  /// динамика — сумма за каждую тренировку.
  _Selection _sessionsSelection(
    List<TrainingSession> sessions, {
    required String title,
    required String subtitle,
  }) {
    // В статистику идут ТОЛЬКО зачётные выстрелы: пристрелка
    // записывается и видна на мишени, но результатом не является.
    final shots = [for (final s in sessions) ...s.countingShots];
    final faceCodes = sessions.map((s) => s.targetFaceCode).toSet();
    final face = TargetFace.byCode(sessions.isEmpty ? '' : sessions.last.targetFaceCode);

    // Последние 20 тренировок — на большем числе точек подписи по оси X
    // всё равно сливаются, а прокрутка графика в текущем painter'е не
    // предусмотрена.
    final lastSessions = sessions.length <= 20 ? sessions : sessions.sublist(sessions.length - 20);
    final totals = [
      for (var i = 0; i < lastSessions.length; i++)
        Shot(
          id: 'stat_$i',
          shotNumber: i + 1,
          seriesNo: 1,
          xMm: 0,
          yMm: 0,
          score: lastSessions[i].totalScore,
          time: lastSessions[i].startedAt ?? DateTime.now(),
        ),
    ];
    final maxTotal = totals.isEmpty
        ? 0.0
        : totals.map((s) => s.score).reduce((a, b) => a > b ? a : b);

    // Подписи по X — даты тренировок. Порядковый номер под точкой
    // («1», «2»…) не говорит ничего: точка здесь не выстрел, а целая
    // тренировка, и важно, КОГДА она была.
    final labelFormat = DateFormat('dd.MM.yy');
    final dateLabels = [
      for (final t in lastSessions)
        t.startedAt == null ? '—' : labelFormat.format(t.startedAt!),
    ];

    return _Selection(
      shots: shots,
      face: face,
      showSeries: false,
      mixedFacesNote: faceCodes.length > 1
          ? 'В срез попали разные мишени (${faceCodes.length}), поэтому СТП, '
              'кучность и разброс по часам не показаны: миллиметры на мишени '
              '10 м и 50 м несопоставимы. Выберите одно упражнение или одну '
              'тренировку — там эти графики будут.'
          : null,
      dynamics: totals.isEmpty
          ? null
          : [
              AnalyticsDynamics(
                title: title,
                subtitle: subtitle,
                points: totals,
                maxY: niceMax(maxTotal),
                xLabels: dateLabels,
                verticalXLabels: true,
              ),
              ..._sessionModes(lastSessions, dateLabels),
            ],
    );
  }

  /// Дополнительные режимы графика по тренировкам.
  ///
  /// Пользователь просил переключать по нажатию «сумма, общий результат,
  /// средний выстрел, минимальная серия и что-нибудь ещё». Сумма — это
  /// первый режим, он собран выше; здесь остальные.
  ///
  /// Все точки — синтетические `Shot`: `ScoreGraphPainter` принимает
  /// список выстрелов, а координаты ему не нужны, он рисует только
  /// `score`.
  List<AnalyticsDynamics> _sessionModes(List<TrainingSession> sessions, List<String> labels) {
    Shot point(int i, double value, DateTime? when) => Shot(
          id: 'mode_$i',
          shotNumber: i + 1,
          seriesNo: 1,
          xMm: 0,
          yMm: 0,
          score: value,
          time: when ?? DateTime.now(),
        );

    final averages = <Shot>[];
    final worstSeries = <Shot>[];
    final bestSeries = <Shot>[];

    // Тренировки без выстрелов в ряд не попадают, поэтому подписи
    // нельзя взять целиком: они бы разъехались с точками. Индекс
    // тренировки хранится в shotNumber (см. point()).
    List<String> labelsFor(List<Shot> row) => [
          for (final p in row)
            p.shotNumber - 1 < labels.length ? labels[p.shotNumber - 1] : '—',
        ];

    for (var i = 0; i < sessions.length; i++) {
      final s = sessions[i];
      if (s.shots.isEmpty) continue;
      averages.add(point(i, s.totalScore / s.shots.length, s.startedAt));

      final stats = ShotAnalytics(s.shots, TargetFace.byCode(s.targetFaceCode)).seriesStats;
      if (stats.isEmpty) continue;
      // Сравниваем серии по СУММЕ, но рисуем средний выстрел: серии
      // бывают неполными (тренировку прервали), и неполная серия по
      // сумме всегда «худшая», хотя стреляли в ней хорошо.
      var lo = stats.first;
      var hi = stats.first;
      for (final st in stats) {
        if (st.average < lo.average) lo = st;
        if (st.average > hi.average) hi = st;
      }
      worstSeries.add(point(i, lo.average, s.startedAt));
      bestSeries.add(point(i, hi.average, s.startedAt));
    }

    return [
      if (averages.isNotEmpty)
        AnalyticsDynamics(
          title: 'Средний выстрел',
          subtitle: 'Средний результат за тренировку',
          points: averages,
          maxY: 10.9,
          xLabels: labelsFor(averages),
          verticalXLabels: true,
        ),
      if (worstSeries.isNotEmpty)
        AnalyticsDynamics(
          title: 'Худшая серия',
          subtitle: 'Средний выстрел в самой слабой серии тренировки',
          points: worstSeries,
          maxY: 10.9,
          xLabels: labelsFor(worstSeries),
          verticalXLabels: true,
        ),
      if (bestSeries.isNotEmpty)
        AnalyticsDynamics(
          title: 'Лучшая серия',
          subtitle: 'Средний выстрел в лучшей серии тренировки',
          points: bestSeries,
          maxY: 10.9,
          xLabels: labelsFor(bestSeries),
          verticalXLabels: true,
        ),
    ];
  }

  /// Скользящее среднее по окну из [_window] выстрелов.
  ///
  /// Раньше здесь была сумма нарастающим итогом. Для стрелка уровня
  /// мастера она бесполезна: линия монотонно лезет вверх, и провал в
  /// ней различить нельзя — сумма после плохого выстрела всё равно
  /// больше, чем до него. Скользящее среднее отвечает на другой вопрос:
  /// «как я стрелял ВОТ СЕЙЧАС», и один разрыв роняет его сразу и
  /// заметно.
  ///
  /// Окно в пять выстрелов — компромисс: по трём линия дёргается почти
  /// как сами выстрелы, по десяти сглаживает так, что провал
  /// размазывается на всю серию.
  static const int _window = 5;

  static AnalyticsDynamics _movingAverage(List<Shot> shots) {
    final points = <Shot>[];
    for (var i = 0; i < shots.length; i++) {
      final from = i - _window + 1 < 0 ? 0 : i - _window + 1;
      var sum = 0.0;
      for (var j = from; j <= i; j++) {
        sum += shots[j].score;
      }
      points.add(Shot(
        id: 'avg_$i',
        shotNumber: shots[i].shotNumber,
        seriesNo: shots[i].seriesNo,
        xMm: 0,
        yMm: 0,
        score: sum / (i - from + 1),
        time: shots[i].time,
      ));
    }
    return AnalyticsDynamics(
      title: 'Средний по последним $_window',
      subtitle: 'Скользящее среднее — провал виден сразу',
      points: points,
      maxY: 10.9,
    );
  }
}

class _Selection {
  final List<Shot> shots;
  final TargetFace face;
  final List<AnalyticsDynamics>? dynamics;
  final bool showSeries;
  final String? mixedFacesNote;

  const _Selection({
    required this.shots,
    required this.face,
    this.dynamics,
    this.showSeries = true,
    this.mixedFacesNote,
  });
}
