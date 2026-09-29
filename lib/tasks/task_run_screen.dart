import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../i18n/i18n.dart';
import '../models/series_spec.dart';
import '../models/shot.dart';
import '../models/training_session.dart';
import '../screens/target_screen.dart';
import '../services/ai_settings.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import '../widgets/press_3d.dart';
import '../widgets/raised_3d_button.dart';
import 'task_ai.dart';
import 'task_models.dart';
import 'task_service.dart';
import 'task_ui.dart';

/// Что спортсмен сделал на этапе — всё дословно, уходит в базу целиком.
class _StepResult {
  DateTime? start;
  DateTime? end;
  int? orderDone;
  TrainingSession? session;

  /// Выстрелы этапа — начиная с этого номера в сессии (общая статистика
  /// с прошлым этапом продолжает ту же сессию).
  int shotOffset = 0;
  final Map<int, String> shotNotes = {};
  final Map<int, String> seriesNotes = {};
  String report = '';
  final List<Map<String, dynamic>> events = [];

  bool get done => end != null;
  List<Shot> get shots => session == null ? const [] : session!.shots.skip(shotOffset).toList();
}

/// Выполнение задания — всё внутри одного окна: обзор → ступени → итог →
/// отчёты. Страницы листаются кнопками (свайп занят мишенью).
class TaskRunScreen extends StatefulWidget {
  final TaskPlan task;
  final AthleteTaskService service;
  final String athleteName;
  const TaskRunScreen({super.key, required this.task, required this.service, this.athleteName = ''});

  @override
  State<TaskRunScreen> createState() => _TaskRunScreenState();
}

class _TaskRunScreenState extends State<TaskRunScreen> {
  static const _uuid = Uuid();
  final _pages = PageController();
  int _page = 0;
  DateTime? _startedAt;
  final Map<String, _StepResult> _results = {};
  int _order = 0;
  final _finalNote = TextEditingController();
  bool _submitting = false;
  String? _runId;
  String? _status;

  TaskPlan get task => widget.task;
  int get _stageCount => task.stages.length;

  _StepResult _result(int stage, int step) => _results.putIfAbsent('$stage-$step', _StepResult.new);

  @override
  void dispose() {
    _pages.dispose();
    _finalNote.dispose();
    super.dispose();
  }

  void _go(int page) {
    setState(() => _page = page);
    _pages.animateToPage(page, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  void _start() {
    _startedAt ??= DateTime.now();
    _go(1);
  }

  /// Сессия мишени для этапа: новая (мишень чистая) или продолжение прошлой
  /// стрелковой, если тренер попросил общую статистику.
  void _ensureSession(int stage, int step) {
    final r = _result(stage, step);
    if (r.session != null) return;
    final s = task.stages[stage].steps[step];
    r.start ??= DateTime.now();
    r.orderDone ??= ++_order;
    if (!s.isShooting) return;
    if (s.keepStats) {
      final prev = _results.values.where((x) => x.session != null && x != r).lastOrNull;
      if (prev != null) {
        r.session = prev.session;
        r.shotOffset = prev.session!.shots.length;
        return;
      }
    }
    r.session = TrainingSession(id: _uuid.v4(), exerciseId: 'task', targetFaceCode: s.faceCode);
  }

  /// Этап закончен: время и факты отклонений (не блокируют, только пометка).
  void _finishStep(int stage, int step) {
    final r = _result(stage, step);
    final s = task.stages[stage].steps[step];
    r.end = DateTime.now();
    r.events.clear();
    final took = r.end!.difference(r.start ?? r.end!).inSeconds;
    if (s.timeLimitSec != null && took > s.timeLimitSec!) {
      r.events.add({
        'type': 'time_over',
        'details': {'limit_sec': s.timeLimitSec, 'actual_sec': took, 'note_mode': s.noteMode},
      });
    }
    final counted = r.shots.where((x) => x.counts).length;
    if (s.isShooting && counted > s.plannedShots) {
      r.events.add({
        'type': 'extra_shots',
        'details': {'planned': s.plannedShots, 'actual': counted}
      });
    }
    if (s.isShooting && counted < s.plannedShots) {
      r.events.add({
        'type': 'fewer_shots',
        'details': {'planned': s.plannedShots, 'actual': counted}
      });
    }
    if (s.sighting?['required'] == true && !r.shots.any((x) => !x.counts)) {
      r.events.add({'type': 'no_sighting', 'details': const {}});
    }
    setState(() {});
  }

  bool _stageDone(int stage) {
    final st = task.stages[stage];
    final done = [for (var i = 0; i < st.steps.length; i++) _result(stage, i).done];
    return st.mode == StageMode.pickOne ? done.contains(true) : !done.contains(false);
  }

  Map<String, dynamic> _runJson() => {
        'task_id': task.id,
        'started_at': _startedAt?.toUtc().toIso8601String(),
        'finished_at': DateTime.now().toUtc().toIso8601String(),
        'final_note': _finalNote.text,
        'steps': [
          for (final (si, stage) in task.stages.indexed)
            for (final (pi, step) in stage.steps.indexed)
              if (_results['$si-$pi']?.start != null)
                () {
                  final r = _results['$si-$pi']!;
                  return {
                    'step_id': step.id,
                    'title': step.title,
                    'order_done': r.orderDone,
                    'started_at': r.start?.toUtc().toIso8601String(),
                    'finished_at': r.end?.toUtc().toIso8601String(),
                    'report': r.report,
                    'shots': [
                      for (final sh in r.shots)
                        {
                          'shot_no': sh.shotNumber,
                          'series_no': sh.seriesNo,
                          'x_mm': sh.xMm,
                          'y_mm': sh.yMm,
                          'score': sh.score,
                          'shot_at': sh.time.toUtc().toIso8601String(),
                          'sighting': !sh.counts,
                          'note': r.shotNotes[sh.shotNumber] ?? '',
                        },
                    ],
                    'series_notes': [
                      for (final e in r.seriesNotes.entries)
                        if (e.value.trim().isNotEmpty) {'series_no': e.key, 'note': e.value},
                    ],
                    'events': r.events,
                  };
                }(),
        ],
      };

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _status = tr('Сохраняю…');
    });
    final run = _runJson();
    final aiSettings = AiSettings(context.read<AppDataStore>().db);
    try {
      _runId = (await widget.service.submitRun(run)).replaceAll('"', '');
      unawaited(widget.service.notifyDone(task, widget.athleteName));
      setState(() => _status = tr('Готово. ИИ составляет отчёты…'));
      _go(_stageCount + 2);
      try {
        final rep = await TaskAi(aiSettings).reports(task, run);
        await widget.service.saveReport(_runId!, 'structured', rep.structured, model: rep.model);
        await widget.service.saveReport(_runId!, 'visual', rep.visual, model: rep.model);
        if (mounted) setState(() => _status = null);
      } catch (e) {
        if (mounted) setState(() => _status = tr('Задание сохранено, но отчёт ИИ не получился: {e}', {'e': e}));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = tr('Не удалось сохранить: {e}. Данные на экране — попробуйте ещё раз.', {'e': e}));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Во время выполнения назад — к обзору, а не потеря результата.
      canPop: _page == 0 || _runId != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(0);
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassHeader(
          title: Text(task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ),
        body: Column(
          children: [
            SizedBox(height: MediaQuery.paddingOf(context).top + GlassHeader.height),
            StageProgressPills(
              count: _stageCount,
              current: _page >= 1 && _page <= _stageCount ? _page - 1 : null,
              isDone: _stageDone,
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _overview(),
                  for (var i = 0; i < _stageCount; i++) _StagePage(key: ValueKey('stage$i'), state: this, stage: i),
                  _finalPage(),
                  _reportsPage(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _overview() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (task.removed)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(tr('Задание снято тренером — выполнить всё равно можно.')),
            ),
          ),
        if (task.dueAt != null || (task.repeatRule ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              [
                if (task.dueAt != null) tr('Срок: {d}', {'d': _date(task.dueAt!)}),
                if ((task.repeatRule ?? '').isNotEmpty) tr('Повтор: {r}', {'r': repeatLabel(task.repeatRule)}),
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (task.coachText.isNotEmpty) ...[
          Text(tr('От тренера'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(task.coachText),
          const SizedBox(height: 16),
        ],
        Text(tr('Порядок действий'), style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        TaskPlanView(plan: task),
        const SizedBox(height: 20),
        Raised3DButton(
          icon: Icons.play_arrow,
          label: task.done ? tr('Выполнить ещё раз') : tr('Начать'),
          baseColor: theme.colorScheme.primary,
          onTap: task.stages.isEmpty ? null : _start,
        ),
        const SizedBox(height: 6),
        Text(tr('Начать можно когда удобно — сейчас можно просто ознакомиться.'),
            textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _finalPage() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(tr('Задание выполнено'), style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final (si, stage) in task.stages.indexed)
          for (final (pi, step) in stage.steps.indexed)
            if (_results['$si-$pi']?.done == true)
              ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle_outline, color: Colors.green),
                title: Text(step.title),
                subtitle: Text([
                  if (step.isShooting)
                    tr('{n} выстр., сумма {s}', {
                      'n': _results['$si-$pi']!.shots.where((x) => x.counts).length,
                      's': _results['$si-$pi']!
                          .shots
                          .where((x) => x.counts)
                          .fold<double>(0, (a, x) => a + x.score)
                          .toStringAsFixed(1),
                    }),
                  for (final e in _results['$si-$pi']!.events) _eventLabel(e),
                ].join(' · ')),
              ),
        const SizedBox(height: 12),
        TextField(
          controller: _finalNote,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(labelText: tr('Заметка по заданию'), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        if (_submitting)
          const Center(child: CircularProgressIndicator())
        else
          Raised3DButton(
            icon: Icons.send,
            label: tr('Отправить тренеру'),
            baseColor: theme.colorScheme.primary,
            onTap: _submit,
          ),
        if (_status != null) ...[const SizedBox(height: 8), Text(_status!, textAlign: TextAlign.center)],
      ],
    );
  }

  Widget _reportsPage() {
    if (_runId == null) return const SizedBox.shrink();
    return TaskReportsView(
      service: widget.service,
      runId: _runId!,
      status: _status,
      onClose: () => Navigator.of(context).pop(),
    );
  }

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String _eventLabel(Map<String, dynamic> e) {
    final d = (e['details'] as Map?) ?? const {};
    return switch (e['type']) {
      'time_over' => tr('время: {a} из {l} мин', {
          'a': ((d['actual_sec'] as num? ?? 0) / 60).toStringAsFixed(1),
          'l': ((d['limit_sec'] as num? ?? 0) / 60).toStringAsFixed(1),
        }),
      'extra_shots' => tr('лишние выстрелы: {a} из {p}', {'a': d['actual'], 'p': d['planned']}),
      'fewer_shots' => tr('выстрелов меньше плана: {a} из {p}', {'a': d['actual'], 'p': d['planned']}),
      'no_sighting' => tr('без пристрелки'),
      _ => '${e['type']}',
    };
  }
}

/// Страница ступени: по режиму — сразу этап, несколько вместе, выбор порядка
/// или выбор одного.
class _StagePage extends StatefulWidget {
  final _TaskRunScreenState state;
  final int stage;
  const _StagePage({super.key, required this.state, required this.stage});

  @override
  State<_StagePage> createState() => _StagePageState();
}

class _StagePageState extends State<_StagePage> {
  int? _active;

  _TaskRunScreenState get run => widget.state;
  TaskStage get stage => run.task.stages[widget.stage];

  void _next() => run._go(widget.stage + 2);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Text(tr('Ступень {n} из {m}', {'n': widget.stage + 1, 'm': run._stageCount}),
              style: theme.textTheme.labelLarge),
          const Spacer(),
          Text(stageModeLabel(stage.mode),
              style: theme.textTheme.labelMedium?.copyWith(color: stageModeColor(context, stage.mode))),
        ],
      ),
    );
    final choosing = (stage.mode == StageMode.anyOrder || stage.mode == StageMode.pickOne) && _active == null;
    if (choosing) {
      final done = run._stageDone(widget.stage);
      return ListView(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
        children: [
          header,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              stage.mode == StageMode.pickOne
                  ? tr('Выберите один этап')
                  : tr('Выберите, с чего начать — сделать нужно все'),
              style: theme.textTheme.titleMedium,
            ),
          ),
          for (final (i, s) in stage.steps.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Press3D(
                padding: EdgeInsets.zero,
                accent: run._result(widget.stage, i).done ? Colors.green : stageModeColor(context, stage.mode),
                onTap: run._result(widget.stage, i).done || (stage.mode == StageMode.pickOne && done)
                    ? null
                    : () => setState(() {
                          run._ensureSession(widget.stage, i);
                          _active = i;
                        }),
                child: ListTile(
                  leading: Icon(run._result(widget.stage, i).done
                      ? Icons.check_circle
                      : (s.isShooting ? Icons.gps_fixed : Icons.self_improvement)),
                  title: Text(s.title),
                  subtitle: s.instructions.isEmpty
                      ? null
                      : Text(s.instructions, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: run._result(widget.stage, i).done ? Text(tr('готово')) : const Icon(Icons.chevron_right),
                ),
              ),
            ),
          if (done)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Raised3DButton(
                  icon: Icons.arrow_forward, label: tr('Дальше'), baseColor: theme.colorScheme.primary, onTap: _next),
            ),
        ],
      );
    }
    // single / together — все этапы ступени сразу; выбор — активный этап.
    final indices = switch (stage.mode) {
      StageMode.anyOrder || StageMode.pickOne => [_active!],
      _ => [for (var i = 0; i < stage.steps.length; i++) i],
    };
    for (final i in indices) {
      run._ensureSession(widget.stage, i);
    }
    return _StepView(
      header: header,
      run: run,
      stage: widget.stage,
      steps: indices,
      onDone: () {
        for (final i in indices) {
          run._finishStep(widget.stage, i);
        }
        if (stage.mode == StageMode.anyOrder && !run._stageDone(widget.stage)) {
          setState(() => _active = null);
        } else {
          _next();
        }
      },
    );
  }
}

/// Один или несколько этапов вместе: указания, таймер, мишень (если стрельба),
/// отметки по режиму тренера и отчёт за этап.
class _StepView extends StatefulWidget {
  final Widget header;
  final _TaskRunScreenState run;
  final int stage;
  final List<int> steps;
  final VoidCallback onDone;
  const _StepView(
      {required this.header, required this.run, required this.stage, required this.steps, required this.onDone});

  @override
  State<_StepView> createState() => _StepViewState();
}

class _StepViewState extends State<_StepView> {
  Timer? _tick;
  bool _showInstructions = true;

  List<TaskStep> get _steps => [for (final i in widget.steps) widget.run.task.stages[widget.stage].steps[i]];
  _StepResult _r(int i) => widget.run._result(widget.stage, i);

  /// Стрелковый этап страницы (при «вместе» — первый стрелковый).
  int? get _shootingIndex {
    for (final i in widget.steps) {
      if (widget.run.task.stages[widget.stage].steps[i].isShooting) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = _r(widget.steps.first);
    final elapsed = DateTime.now().difference(first.start ?? DateTime.now());
    final limit = _steps.map((s) => s.timeLimitSec).whereType<int>().fold<int?>(null, (a, b) => a == null ? b : a + b);
    final over = limit != null && elapsed.inSeconds > limit;
    final shootIdx = _shootingIndex;
    final noteModes = {for (final s in _steps) s.noteMode};

    final instructions = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Press3D(
        onTap: () => setState(() => _showInstructions = !_showInstructions),
        accent: over ? Colors.orange : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_steps.map((s) => s.title).join(' + '), style: theme.textTheme.titleMedium),
                ),
                Icon(Icons.timer_outlined, size: 16, color: over ? Colors.orange : theme.hintColor),
                const SizedBox(width: 4),
                Text(
                  '${_mmss(elapsed)}${limit == null ? '' : ' / ${_mmss(Duration(seconds: limit))}'}',
                  style: theme.textTheme.labelLarge?.copyWith(color: over ? Colors.orange : null),
                ),
                Icon(_showInstructions ? Icons.expand_less : Icons.expand_more),
              ],
            ),
            if (over)
              Text(tr('Время вышло — это не мешает, просто будет отмечено'),
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange)),
            if (_showInstructions)
              for (final s in _steps) ...[
                const SizedBox(height: 6),
                if (_steps.length > 1) Text(s.title, style: theme.textTheme.labelLarge),
                if (s.instructions.isNotEmpty) Text(s.instructions),
                Text(
                  [
                    if (s.isShooting) tr('{n} выстр.', {'n': s.plannedShots}),
                    if (s.exercise?['position'] != null) '${s.exercise!['position']}',
                    if (s.sighting?['required'] == true) tr('с пристрелкой'),
                    noteModeLabel(s.noteMode),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
          ],
        ),
      ),
    );

    final notes = _notesPanel(shootIdx, noteModes);
    final finish = Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Raised3DButton(
        icon: Icons.check,
        label: tr('Этап выполнен'),
        baseColor: Colors.green.shade700,
        onTap: widget.onDone,
      ),
    );

    if (shootIdx == null) {
      return ListView(children: [widget.header, instructions, ...notes, finish]);
    }
    final r = _r(shootIdx);
    final step = widget.run.task.stages[widget.stage].steps[shootIdx];
    final base = step.toExercise();
    final sightingShots = (step.sighting?['max_shots'] as num?)?.toInt();
    final exercise = step.sighting?['required'] == true
        ? base.copyWith(series: [
            SeriesSpec(name: 'Пристрелка', shotCount: sightingShots, counts: false),
            SeriesSpec(name: 'Зачёт', shotCount: step.plannedShots),
          ])
        : base;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          widget.header,
          instructions,
          Expanded(
            child: TaskTargetPanel(
              key: ValueKey('target-${widget.stage}-$shootIdx'),
              session: r.session!,
              exercise: exercise,
              onChanged: (s) {
                r.session = s;
                if (mounted) setState(() {});
              },
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.28),
            child: ListView(shrinkWrap: true, children: [...notes, finish]),
          ),
        ],
      ),
    );
  }

  /// Поля отметок — как попросил тренер (по выстрелу / по серии / в конце этапа).
  List<Widget> _notesPanel(int? shootIdx, Set<String> modes) {
    final out = <Widget>[];
    if (shootIdx != null) {
      final r = _r(shootIdx);
      final shots = r.shots;
      if (modes.contains('shot') && shots.isNotEmpty) {
        final last = shots.last;
        out.add(_NoteField(
          key: ValueKey('shot-${last.shotNumber}'),
          label: tr('Отметка к выстрелу {n} ({s})', {'n': last.shotNumber, 's': last.score.toStringAsFixed(1)}),
          initial: r.shotNotes[last.shotNumber] ?? '',
          onChanged: (v) => r.shotNotes[last.shotNumber] = v,
        ));
      }
      if (modes.contains('series') && shots.isNotEmpty) {
        final series = shots.last.seriesNo;
        out.add(_NoteField(
          key: ValueKey('series-$series'),
          label: tr('Отметка к серии {n}', {'n': series}),
          initial: r.seriesNotes[series] ?? '',
          onChanged: (v) => r.seriesNotes[series] = v,
        ));
      }
    }
    for (final i in widget.steps) {
      final r = _r(i);
      out.add(_NoteField(
        key: ValueKey('report-${widget.stage}-$i'),
        label: widget.steps.length > 1
            ? tr('Отчёт: {t}', {'t': widget.run.task.stages[widget.stage].steps[i].title})
            : tr('Отчёт за этап'),
        initial: r.report,
        onChanged: (v) => r.report = v,
      ));
    }
    return out;
  }

  static String _mmss(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _NoteField extends StatefulWidget {
  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  const _NoteField({super.key, required this.label, required this.initial, required this.onChanged});

  @override
  State<_NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<_NoteField> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: TextField(
          controller: _c,
          minLines: 1,
          maxLines: 4,
          onChanged: widget.onChanged,
          decoration: InputDecoration(labelText: widget.label, isDense: true, border: const OutlineInputBorder()),
        ),
      );
}

/// Отчёты ИИ по прохождению: наглядный и текстовый; наглядный можно переделать.
class TaskReportsView extends StatefulWidget {
  final AthleteTaskService? service;
  final String runId;
  final String? status;
  final VoidCallback? onClose;

  /// Готовые отчёты (у тренера — пришли вместе с заданием).
  final List<Map<String, dynamic>>? reports;
  const TaskReportsView({super.key, this.service, required this.runId, this.status, this.onClose, this.reports});

  @override
  State<TaskReportsView> createState() => _TaskReportsViewState();
}

class _TaskReportsViewState extends State<TaskReportsView> {
  List<Map<String, dynamic>>? _reports;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _reports = widget.reports;
    if (_reports == null) {
      _load();
      // Отчёт ИИ приходит через несколько секунд после сохранения.
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final s = widget.service;
    if (s == null) return;
    try {
      final r = await s.reports(widget.runId);
      if (!mounted) return;
      setState(() => _reports = r);
      if (r.any((x) => x['kind'] == 'visual')) _poll?.cancel();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reports = _reports ?? const [];
    final visual = reports.where((r) => r['kind'] == 'visual').lastOrNull;
    final structured = reports.where((r) => r['kind'] == 'structured').lastOrNull;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(tr('Отчёт'), style: theme.textTheme.titleLarge),
        if (widget.status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(widget.status!)),
        if (visual == null && widget.status == null)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (visual != null) TaskVisualReport(content: '${visual['content']}'),
        if (structured != null)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(tr('Подробный текстовый отчёт')),
            children: [SelectableText('${structured['content']}')],
          ),
        if (widget.onClose != null) ...[
          const SizedBox(height: 16),
          OutlinedButton(onPressed: widget.onClose, child: Text(tr('Закрыть'))),
        ],
      ],
    );
  }
}
