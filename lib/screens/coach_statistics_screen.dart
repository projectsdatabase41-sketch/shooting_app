import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../logic/shot_analytics.dart';
import '../models/shot.dart';
import '../models/target_face.dart';
import '../models/training_session.dart';
import '../services/coach_access_service.dart';
import '../services/coach_data_mapper.dart';
import '../state/app_data_store.dart';
import '../widgets/analytics_panel.dart';
import '../widgets/empty_state.dart';

/// Вкладка "Статистика" тренера (раздел 8 ТЗ): то же самое, что у
/// спортсмена, только с выбором спортсмена сверху (решение пользователя:
/// "так же как у спортсменов, только с выбором спортсмена, как выбор
/// тренировки"). Упрощено до двух срезов — "Всё" и "Тренировка": у
/// тренера нет каталога упражнений спортсмена, чтобы группировать по
/// упражнению так же, как в `StatisticsScreen`.
class CoachStatisticsScreen extends StatefulWidget {
  const CoachStatisticsScreen({super.key});

  @override
  State<CoachStatisticsScreen> createState() => _CoachStatisticsScreenState();
}

enum _Scope { all, session }

class _CoachStatisticsScreenState extends State<CoachStatisticsScreen> {
  late final CoachAccessService _access;
  List<CoachAthlete> _athletes = [];
  CoachAthlete? _athlete;
  bool _loading = false;
  String? _error;
  List<TrainingSession> _sessions = [];
  String Function(TrainingSession) _nameOf = (_) => 'Упражнение';

  _Scope _scope = _Scope.all;
  String? _sessionId;
  int? _seriesNo;

  @override
  void initState() {
    super.initState();
    _access = CoachAccessService(context.read<AppDataStore>().db);
    _athletes = _access.listAthletes();
    if (_athletes.isNotEmpty) {
      _athlete = _athletes.first;
      _load();
    }
  }

  Future<void> _load() async {
    final athlete = _athlete;
    if (athlete == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final exercises = await _access.fetchExercises(athlete: athlete);
      final packages = await _access.fetchSessions(athlete: athlete);
      final shotsByPackageId = <String, List<Map<String, dynamic>>>{};
      for (final p in packages) {
        final id = '${p['id']}';
        shotsByPackageId[id] = await _access.fetchShots(id, athlete: athlete);
      }
      final sessions = mapCoachSessions(packages, exercises, shotsByPackageId)
          .where((s) => s.shots.isNotEmpty)
          .toList()
        ..sort((a, b) => (b.startedAt ?? DateTime(0)).compareTo(a.startedAt ?? DateTime(0)));
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _nameOf = coachExerciseNameOf(exercises);
        _sessionId = null;
        _seriesNo = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Статистика')),
      body: _athletes.isEmpty
          ? const EmptyState(icon: Icons.groups_outlined, text: 'Сначала добавьте спортсмена')
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                _athletePicker(),
                const SizedBox(height: 12),
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (!_loading && _error == null) ..._body(),
              ],
            ),
    );
  }

  Widget _athletePicker() {
    return DropdownButtonFormField<String>(
      initialValue: _athlete?.id,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Спортсмен'),
      items: [for (final a in _athletes) DropdownMenuItem(value: a.id, child: Text(a.name))],
      onChanged: (v) {
        setState(() => _athlete = _athletes.firstWhere((a) => a.id == v));
        _load();
      },
    );
  }

  List<Widget> _body() {
    if (_sessions.isEmpty) {
      return const [EmptyState(icon: Icons.insights_outlined, text: 'У спортсмена пока нет тренировок с выстрелами')];
    }

    final selection = _resolveSelection();
    return [
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<_Scope>(
          segments: const [
            ButtonSegment(value: _Scope.all, label: Text('Всё')),
            ButtonSegment(value: _Scope.session, label: Text('Тренировка')),
          ],
          selected: {_scope},
          showSelectedIcon: false,
          onSelectionChanged: (set) => setState(() {
            _scope = set.first;
            _seriesNo = null;
          }),
        ),
      ),
      const SizedBox(height: 12),
      if (_scope == _Scope.session) ..._sessionPickers(),
      const SizedBox(height: 4),
      AnalyticsPanel(
        shots: selection.shots,
        face: selection.face,
        dynamics: selection.dynamics,
        showSeries: selection.showSeries,
        mixedFacesNote: selection.mixedFacesNote,
      ),
    ];
  }

  List<Widget> _sessionPickers() {
    final df = DateFormat('dd.MM.yyyy HH:mm');
    final currentId = _currentSessionId();
    final current = _sessions.firstWhere((s) => s.id == currentId);
    final seriesNos = current.shots.map((s) => s.seriesNo).toSet().toList()..sort();
    return [
      DropdownButtonFormField<String>(
        initialValue: currentId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Тренировка'),
        items: [
          for (final s in _sessions)
            DropdownMenuItem(
              value: s.id,
              child: Text(
                '${_nameOf(s)} · ${s.startedAt == null ? '—' : df.format(s.startedAt!)}',
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

  String _currentSessionId() {
    final id = _sessionId;
    if (id != null && _sessions.any((s) => s.id == id)) return id;
    return _sessions.first.id;
  }

  _Selection _resolveSelection() {
    switch (_scope) {
      case _Scope.all:
        final shots = [for (final s in _sessions) ...s.countingShots];
        final faceCodes = _sessions.map((s) => s.targetFaceCode).toSet();
        final face = TargetFace.byCode(_sessions.first.targetFaceCode);
        final lastSessions = _sessions.length <= 20 ? _sessions.reversed.toList() : _sessions.reversed.toList().sublist(_sessions.length - 20);
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
        final maxTotal = totals.isEmpty ? 0.0 : totals.map((s) => s.score).reduce((a, b) => a > b ? a : b);
        final labelFormat = DateFormat('dd.MM.yy');
        final dateLabels = [for (final t in lastSessions) t.startedAt == null ? '—' : labelFormat.format(t.startedAt!)];
        return _Selection(
          shots: shots,
          face: face,
          showSeries: false,
          mixedFacesNote: faceCodes.length > 1
              ? 'В срез попали разные мишени (${faceCodes.length}), поэтому СТП, кучность и разброс не показаны.'
              : null,
          dynamics: totals.isEmpty
              ? null
              : [
                  AnalyticsDynamics(
                    title: 'Динамика тренировок',
                    subtitle: 'Сумма очков за тренировку',
                    points: totals,
                    maxY: niceMax(maxTotal),
                    xLabels: dateLabels,
                    verticalXLabels: true,
                  ),
                ],
        );

      case _Scope.session:
        final session = _sessions.firstWhere((s) => s.id == _currentSessionId());
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
                ],
        );
    }
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
