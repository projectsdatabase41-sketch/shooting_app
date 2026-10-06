import '../logic/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../i18n/i18n.dart';
import '../models/target_face.dart';
import '../services/ai_settings.dart';
import '../services/coach_access_service.dart';
import '../services/push_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import '../widgets/press_3d.dart';
import '../widgets/raised_3d_button.dart';
import '../widgets/swipe_to_delete.dart';
import 'task_ai.dart';
import 'task_models.dart';
import 'task_run_screen.dart';
import 'task_service.dart';
import 'task_ui.dart';

/// Одно задание у одного спортсмена (у каждого — своя копия в его базе).
typedef _Copy = ({CoachAthlete athlete, TaskPlan task});

/// «Задания» у тренера: задания сгруппированы — одно задание нескольким
/// спортсменам — одна карточка. [openTaskId] — открыть группу с этим
/// заданием (тап по push «выполнено»).
class CoachTasksScreen extends StatefulWidget {
  final String? openTaskId;
  const CoachTasksScreen({super.key, this.openTaskId});

  @override
  State<CoachTasksScreen> createState() => _CoachTasksScreenState();
}

class _CoachTasksScreenState extends State<CoachTasksScreen> {
  late final CoachAccessService _access =
      CoachAccessService(context.read<AppDataStore>().db);
  late final CoachTaskService _service = CoachTaskService(_access);
  late final List<CoachAthlete> _athletes = _access.listAthletes();
  Map<String, List<_Copy>>? _groups;
  bool _openedFromPush = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Адрес устройства тренера — в базу каждого спортсмена: push «выполнено».
    PushService.deviceToken().then((t) {
      if (t == null) return;
      for (final a in _athletes) {
        _service.registerDevice(a, t);
      }
    });
  }

  Future<void> _load() async {
    final copies = <_Copy>[];
    await Future.wait([
      for (final a in _athletes)
        _service
            .list(a)
            .then((list) =>
                copies.addAll([for (final t in list) (athlete: a, task: t)]))
            .catchError((_) {}),
    ]);
    final groups = <String, List<_Copy>>{};
    for (final c in copies) {
      (groups[c.task.groupKey ?? c.task.id ?? ''] ??= []).add(c);
    }
    if (!mounted) return;
    setState(() => _groups = groups);
    final open = widget.openTaskId;
    if (open != null && !_openedFromPush) {
      _openedFromPush = true;
      final g = groups.entries
          .where((e) => e.value.any((c) => c.task.id == open))
          .firstOrNull;
      if (g != null) _openGroup(g.value);
    }
  }

  Future<void> _openGroup(List<_Copy> copies) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _CoachTaskGroupScreen(
          service: _service, athletes: _athletes, copies: copies),
    ));
    _load();
  }

  /// Снимает задание у ВСЕХ спортсменов группы разом — отправлено сразу
  /// нескольким, свайп на экране тренера относится ко всей группе, не к
  /// одной копии. Тот же статус 'removed', что уже понимает
  /// `TaskPlan.removed` (сортировка в конец, иконка "снято тренером" на
  /// экране спортсмена) — только раньше его некому было выставить.
  Future<void> _removeGroup(List<_Copy> copies) async {
    try {
      await Future.wait([
        for (final c in copies)
          if (c.task.id != null)
            _service.setStatus(c.athlete, c.task.id!, 'removed'),
      ]);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
    _load();
  }

  /// Удаляет задание совсем у всех спортсменов группы.
  Future<void> _deleteGroup(List<_Copy> copies) async {
    try {
      await Future.wait([
        for (final c in copies)
          if (c.task.id != null) _service.deleteForever(c.athlete, c.task.id!),
      ]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(
                'Не удалось удалить: {e}. Нужен sql/task-delete.sql в базе спортсмена.',
                {'e': friendlyError(e)}))));
      }
    }
    _load();
  }

  Future<void> _create() async {
    final sent = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) =>
          _CoachTaskEditorScreen(service: _service, athletes: _athletes),
    ));
    if (sent == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = _groups;
    return Scaffold(
      appBar: GlassHeader(
        title: Text(tr('Задания'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      floatingActionButton: _athletes.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: Text(tr('Задание'))),
      body: _athletes.isEmpty
          ? Center(
              child: Text(tr('Сначала добавьте спортсмена'),
                  style: TextStyle(color: theme.hintColor)))
          : groups == null
              ? const Center(child: CircularProgressIndicator())
              : groups.isEmpty
                  ? Center(
                      child: Text(tr('Заданий пока нет'),
                          style: TextStyle(color: theme.hintColor)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                        children: [
                          for (final g in (groups.values.toList()
                            ..sort((a, b) => (b.first.task.createdAt ??
                                    DateTime(0))
                                .compareTo(
                                    a.first.task.createdAt ?? DateTime(0)))))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: SwipeToDelete(
                                itemKey: g.first.task.id ?? g.first.task.title,
                                title: tr('Удалить задание?'),
                                message: tr(
                                  '«{title}» ({names}). Удалить совсем — вместе с результатами, или только снять: останется в списке спортсмена как снятое.',
                                  {
                                    'title': g.first.task.title,
                                    'names':
                                        g.map((c) => c.athlete.name).join(', ')
                                  },
                                ),
                                confirmLabel: tr('Удалить совсем'),
                                onConfirmed: () => _deleteGroup(g),
                                localOnlyLabel: tr('Только снять'),
                                onConfirmedLocalOnly: () => _removeGroup(g),
                                child: Press3D(
                                  padding: EdgeInsets.zero,
                                  accent: theme.colorScheme.primary,
                                  onTap: () => _openGroup(g),
                                  child: ListTile(
                                    leading:
                                        const Icon(Icons.assignment_outlined),
                                    title: Text(g.first.task.title),
                                    subtitle: Text([
                                      g.map((c) => c.athlete.name).join(', '),
                                      tr('выполнили: {n} из {m}', {
                                        'n': g.where((c) => c.task.done).length,
                                        'm': g
                                            .where((c) => !c.task.removed)
                                            .length,
                                      }),
                                    ].join(' · ')),
                                    trailing: const Icon(Icons.chevron_right),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
    );
  }
}

// ---------------- Создание ----------------

class _CoachTaskEditorScreen extends StatefulWidget {
  final CoachTaskService service;
  final List<CoachAthlete> athletes;
  const _CoachTaskEditorScreen({required this.service, required this.athletes});

  @override
  State<_CoachTaskEditorScreen> createState() => _CoachTaskEditorScreenState();
}

class _CoachTaskEditorScreenState extends State<_CoachTaskEditorScreen> {
  final Set<String> _to = {};
  final _text = TextEditingController();
  final _title = TextEditingController();
  DateTime? _due;

  /// Дни недели повтора — свободный набор вместо трёх жёстких пресетов
  /// (решение пользователя: "выбор дней недели"). Пусто — без повтора,
  /// все семь — то же самое, что 'daily'.
  final Set<String> _repeatDays = {};
  static const _weekdayOrder = [
    'mon',
    'tue',
    'wed',
    'thu',
    'fri',
    'sat',
    'sun'
  ];
  static const _weekdayLabels = {
    'mon': /*tr*/ 'Пн',
    'tue': /*tr*/ 'Вт',
    'wed': /*tr*/ 'Ср',
    'thu': /*tr*/ 'Чт',
    'fri': /*tr*/ 'Пт',
    'sat': /*tr*/ 'Сб',
    'sun': /*tr*/ 'Вс',
  };
  String? get _repeat => _repeatDays.isEmpty
      ? null
      : (_repeatDays.length == 7
          ? 'daily'
          : _weekdayOrder.where(_repeatDays.contains).join(','));
  TaskPlan? _plan;
  final List<({String question, String answer})> _answers = [];
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _buildWithAi() async {
    if (_text.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final ai = TaskAi(AiSettings(context.read<AppDataStore>().db));
      while (true) {
        final r = await ai.build(
          coachText: _text.text.trim(),
          answers: _answers,
          athletesInfo: widget.athletes
              .where((a) => _to.contains(a.id))
              .map((a) => a.name)
              .join(', '),
        );
        if (r.plan != null) {
          setState(() {
            _plan = r.plan;
            if (_title.text.trim().isEmpty) _title.text = r.plan!.title;
          });
          break;
        }
        if (!mounted) return;
        final answers = await _askQuestions(r.questions);
        if (answers == null) break;
        _answers.addAll(answers);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('ИИ не ответил: {e}', {'e': friendlyError(e)}))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Уточняющие вопросы ИИ — тренер отвечает текстом, по одному вопросу
  /// за раз со счётчиком (N/M) и стрелкой назад — жалоба пользователя:
  /// все вопросы сразу одним списком было толком не прочитать.
  Future<List<({String question, String answer})>?> _askQuestions(
      List<String> questions) async {
    final ctrls = [for (final _ in questions) TextEditingController()];
    var index = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final last = index == questions.length - 1;
          return AlertDialog(
            title: Row(
              children: [
                if (index > 0)
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: tr('Назад'),
                    onPressed: () => setDialogState(() => index--),
                  ),
                Expanded(
                  child: Text(
                    tr('ИИ уточняет ({i}/{n})',
                        {'i': index + 1, 'n': questions.length}),
                    textAlign: index > 0 ? TextAlign.center : TextAlign.start,
                  ),
                ),
                if (index > 0)
                  const SizedBox(width: 48), // баланс под стрелку слева
              ],
            ),
            content: TextField(
              key: ValueKey(index),
              controller: ctrls[index],
              decoration: InputDecoration(labelText: questions[index]),
              maxLines: 4,
              minLines: 1,
              autofocus: true,
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(tr('Отмена'))),
              FilledButton(
                onPressed: () {
                  if (last) {
                    Navigator.of(ctx).pop(true);
                  } else {
                    setDialogState(() => index++);
                  }
                },
                child: Text(last ? tr('Ответить') : tr('Далее')),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return null;
    return [
      for (final (i, q) in questions.indexed)
        (question: q, answer: ctrls[i].text.trim())
    ];
  }

  Future<void> _send() async {
    final plan = _plan;
    if (plan == null || _to.isEmpty || plan.stages.isEmpty) return;
    plan
      ..title = _title.text.trim().isEmpty ? tr('Задание') : _title.text.trim()
      ..coachText = _text.text.trim()
      ..dueAt = _due
      ..repeatRule = _repeat
      ..groupKey = const Uuid().v4();
    setState(() => _busy = true);
    final failed = <String>[];
    for (final a in widget.athletes.where((a) => _to.contains(a.id))) {
      try {
        final id = (await widget.service.create(a, plan)).replaceAll('"', '');
        await widget.service.push(a, 'new', id, plan.title);
      } catch (e) {
        failed.add(a.name);
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed.isEmpty) {
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(
            'Не отправлено: {names}. Проверьте связь и что в базе спортсмена выполнен sql/tasks.sql.',
            {'names': failed.join(', ')})),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Новое задание'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding:
            EdgeInsets.fromLTRB(16, topInset + GlassHeader.height + 4, 16, 100),
        children: [
          Text(tr('1. Кому'), style: theme.textTheme.titleMedium),
          Wrap(
            spacing: 6,
            children: [
              for (final a in widget.athletes)
                FilterChip(
                  label: Text(a.name),
                  selected: _to.contains(a.id),
                  onSelected: (v) =>
                      setState(() => v ? _to.add(a.id) : _to.remove(a.id)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(tr('2. Описание'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          TextField(
            controller: _text,
            minLines: 4,
            maxLines: 12,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: tr(
                  'Например: сначала 20 лёжа с отметками по сериям, одновременно следить за дыханием; '
                  'потом смена на стоя с пристрелкой; затем стоя и с колена по 20 — в любом порядке.'),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.event),
            label: Text(_due == null
                ? tr('Срок')
                : '${_due!.day}.${_due!.month.toString().padLeft(2, '0')}'),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365)),
                initialDate:
                    _due ?? DateTime.now().add(const Duration(days: 3)),
              );
              setState(() => _due =
                  d == null ? null : DateTime(d.year, d.month, d.day, 23, 59));
            },
          ),
          const SizedBox(height: 8),
          Text(tr('Повторять по дням недели'),
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in _weekdayOrder)
                FilterChip(
                  label: Text(tr(_weekdayLabels[d]!)),
                  selected: _repeatDays.contains(d),
                  onSelected: (v) => setState(
                      () => v ? _repeatDays.add(d) : _repeatDays.remove(d)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _buildWithAi,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome),
                  label: Text(tr('Собрать с ИИ')),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(
                    () => _plan ??= TaskPlan(title: _title.text, stages: [
                          TaskStage(steps: [TaskStep(title: tr('Этап 1'))])
                        ])),
                child: Text(tr('Вручную')),
              ),
            ],
          ),
          if (_plan != null) ...[
            const SizedBox(height: 20),
            Text(tr('3. Ступени и этапы'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            TextField(
                controller: _title,
                decoration: InputDecoration(labelText: tr('Название'))),
            const SizedBox(height: 8),
            _PlanEditor(plan: _plan!, onChanged: () => setState(() {})),
          ],
        ],
      ),
      bottomNavigationBar: _plan == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Raised3DButton(
                  icon: Icons.send,
                  label: _to.isEmpty
                      ? tr('Выберите спортсменов')
                      : tr('Отправить ({n})', {'n': _to.length}),
                  baseColor: theme.colorScheme.primary,
                  onTap: _busy || _to.isEmpty ? null : _send,
                ),
              ),
            ),
    );
  }
}

/// Редактор ступеней: режим, порядок, этапы (тап — правка).
class _PlanEditor extends StatelessWidget {
  final TaskPlan plan;
  final VoidCallback onChanged;
  const _PlanEditor({required this.plan, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, stage) in plan.stages.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Press3D(
              accent: stageModeColor(context, stage.mode),
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(tr('Ступень {n}', {'n': i + 1}),
                          style: theme.textTheme.labelLarge),
                      const SizedBox(width: 8),
                      DropdownButton<StageMode>(
                        value: stage.mode,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final m in StageMode.values)
                            DropdownMenuItem(
                                value: m, child: Text(stageModeLabel(m))),
                        ],
                        onChanged: (m) {
                          stage.mode = m ?? stage.mode;
                          onChanged();
                        },
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        onPressed: i == 0
                            ? null
                            : () {
                                plan.stages
                                    .insert(i - 1, plan.stages.removeAt(i));
                                onChanged();
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () {
                          plan.stages.removeAt(i);
                          onChanged();
                        },
                      ),
                    ],
                  ),
                  for (final (j, step) in stage.steps.indexed)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(step.isShooting
                          ? Icons.gps_fixed
                          : Icons.self_improvement),
                      title: Text(step.title),
                      subtitle: Text(
                        [
                          if (step.isShooting)
                            tr('{n} выстр.', {'n': step.plannedShots}),
                          if (step.timeLimitSec != null)
                            tr('{m} мин',
                                {'m': (step.timeLimitSec! / 60).round()}),
                          noteModeLabel(step.noteMode),
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          stage.steps.removeAt(j);
                          onChanged();
                        },
                      ),
                      onTap: () async {
                        await showDialog(
                            context: context,
                            builder: (_) => _StepDialog(step: step));
                        onChanged();
                      },
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      final s = TaskStep(
                          title: tr('Этап {n}', {'n': stage.steps.length + 1}));
                      stage.steps.add(s);
                      await showDialog(
                          context: context,
                          builder: (_) => _StepDialog(step: s));
                      onChanged();
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(tr('Этап')),
                  ),
                ],
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: () {
            plan.stages.add(TaskStage(steps: [TaskStep(title: tr('Этап 1'))]));
            onChanged();
          },
          icon: const Icon(Icons.add),
          label: Text(tr('Ступень')),
        ),
      ],
    );
  }
}

class _StepDialog extends StatefulWidget {
  final TaskStep step;
  const _StepDialog({required this.step});

  @override
  State<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends State<_StepDialog> {
  TaskStep get s => widget.step;
  late final _title = TextEditingController(text: s.title);
  late final _instr = TextEditingController(text: s.instructions);
  late final _shots =
      TextEditingController(text: s.isShooting ? '${s.plannedShots}' : '');
  late final _series =
      TextEditingController(text: '${s.exercise?['series_size'] ?? 10}');
  late final _position =
      TextEditingController(text: '${s.exercise?['position'] ?? ''}');
  late final _minutes = TextEditingController(
      text: s.timeLimitSec == null ? '' : '${(s.timeLimitSec! / 60).round()}');
  late final _sightMax =
      TextEditingController(text: '${s.sighting?['max_shots'] ?? ''}');
  late bool _shooting = s.isShooting;
  late String _face = s.faceCode;
  late bool _sighting = s.sighting?['required'] == true;
  late String _note = s.noteMode;
  late bool _keep = s.keepStats;

  void _save() {
    s
      ..title = _title.text.trim().isEmpty ? s.title : _title.text.trim()
      ..instructions = _instr.text.trim()
      ..exercise = _shooting
          ? {
              'target_face_code': _face,
              'shots': int.tryParse(_shots.text) ?? 10,
              'series_size': int.tryParse(_series.text) ?? 10,
              if (_position.text.trim().isNotEmpty)
                'position': _position.text.trim(),
            }
          : null
      ..timeLimitSec = int.tryParse(_minutes.text) == null
          ? null
          : int.parse(_minutes.text) * 60
      ..sighting = _sighting
          ? {
              'required': true,
              if (int.tryParse(_sightMax.text) != null)
                'max_shots': int.parse(_sightMax.text)
            }
          : null
      ..noteMode = _note
      ..keepStats = _keep;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Этап')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: _title,
                decoration: InputDecoration(labelText: tr('Название'))),
            TextField(
              controller: _instr,
              minLines: 2,
              maxLines: 8,
              decoration: InputDecoration(
                  labelText: tr('Что делать (текст для спортсмена)')),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Стрельба')),
              value: _shooting,
              onChanged: (v) => setState(() => _shooting = v),
            ),
            if (_shooting) ...[
              DropdownButtonFormField<String>(
                initialValue: TargetFace.selectable(keep: _face)
                        .any((f) => f.code == _face)
                    ? _face
                    : TargetFace.all.first.code,
                items: [
                  for (final f in TargetFace.selectable(keep: _face))
                    DropdownMenuItem(value: f.code, child: Text(f.name))
                ],
                onChanged: (v) => setState(() => _face = v ?? _face),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                        controller: _shots,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: tr('Выстрелов'))),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                        controller: _series,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: tr('В серии'))),
                  ),
                ],
              ),
              TextField(
                  controller: _position,
                  decoration: InputDecoration(labelText: tr('Изготовка'))),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Пристрелка')),
                value: _sighting,
                onChanged: (v) => setState(() => _sighting = v),
              ),
              if (_sighting)
                TextField(
                  controller: _sightMax,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: tr('Пробных не больше (необязательно)')),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Общая статистика с прошлым этапом')),
                value: _keep,
                onChanged: (v) => setState(() => _keep = v),
              ),
            ],
            TextField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: tr('Ограничение, мин (необязательно)')),
            ),
            DropdownButtonFormField<String>(
              initialValue: _note,
              decoration: InputDecoration(labelText: tr('Отметки спортсмена')),
              items: [
                for (final m in ['step', 'shot', 'series', 'none'])
                  DropdownMenuItem(value: m, child: Text(noteModeLabel(m))),
              ],
              onChanged: (v) => setState(() => _note = v ?? _note),
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: _save, child: Text(tr('Готово')))],
    );
  }
}

// ---------------- Группа: получатели и результаты ----------------

class _CoachTaskGroupScreen extends StatefulWidget {
  final CoachTaskService service;
  final List<CoachAthlete> athletes;
  final List<_Copy> copies;
  const _CoachTaskGroupScreen(
      {required this.service, required this.athletes, required this.copies});

  @override
  State<_CoachTaskGroupScreen> createState() => _CoachTaskGroupScreenState();
}

class _CoachTaskGroupScreenState extends State<_CoachTaskGroupScreen> {
  late final List<_Copy> _copies = [...widget.copies];
  bool _busy = false;

  TaskPlan get _plan => _copies.first.task;

  Future<void> _setRemoved(_Copy c, bool removed) async {
    setState(() => _busy = true);
    try {
      await widget.service
          .setStatus(c.athlete, c.task.id!, removed ? 'removed' : 'active');
      await widget.service.push(
          c.athlete, removed ? 'removed' : 'new', c.task.id!, c.task.title);
      c.task.status = removed ? 'removed' : 'active';
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addAthletes() async {
    final have = _copies.map((c) => c.athlete.id).toSet();
    final free = widget.athletes.where((a) => !have.contains(a.id)).toList();
    if (free.isEmpty) return;
    final chosen = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(tr('Добавить спортсменов')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final a in free)
                CheckboxListTile(
                  value: chosen.contains(a.id),
                  title: Text(a.name),
                  onChanged: (v) => set(
                      () => v == true ? chosen.add(a.id) : chosen.remove(a.id)),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(tr('Отмена'))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(tr('Добавить'))),
          ],
        ),
      ),
    );
    if (ok != true || chosen.isEmpty) return;
    setState(() => _busy = true);
    for (final a in free.where((a) => chosen.contains(a.id))) {
      try {
        final plan = TaskPlan(
          title: _plan.title,
          coachText: _plan.coachText,
          dueAt: _plan.dueAt,
          repeatRule: _plan.repeatRule,
          groupKey: _plan.groupKey,
          stages: _plan.stages,
          clarifications: _plan.clarifications,
        );
        final id = (await widget.service.create(a, plan)).replaceAll('"', '');
        await widget.service.push(a, 'new', id, plan.title);
        final fresh = await widget.service.list(a, taskId: id);
        if (fresh.isNotEmpty) _copies.add((athlete: a, task: fresh.first));
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('${a.name}: $e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _openRuns(_Copy c) async {
    final full = await widget.service.list(c.athlete, taskId: c.task.id);
    if (!mounted || full.isEmpty) return;
    final runs = full.first.runsRaw;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: GlassHeader(
          title: Text('${c.athlete.name} · ${c.task.title}',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        body: runs.isEmpty
            ? Center(child: Text(tr('Ещё не выполнял')))
            : PageView(
                children: [
                  for (final r in runs.reversed)
                    TaskReportsView(
                      runId: '${r['id']}',
                      reports: [
                        for (final x in (r['reports'] as List? ?? const []))
                          (x as Map).cast<String, dynamic>()
                      ],
                      status: tr('Выполнено {d} · заметка: {n}', {
                        'd':
                            '${DateTime.tryParse('${r['finished_at']}')?.toLocal() ?? ''}'
                                .split('.')
                                .first,
                        'n': '${r['final_note'] ?? ''}'.isEmpty
                            ? '—'
                            : '${r['final_note']}',
                      }),
                    ),
                ],
              ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(_plan.title,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding:
            EdgeInsets.fromLTRB(16, topInset + GlassHeader.height + 8, 16, 16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          Row(
            children: [
              Text(tr('Получатели'), style: theme.textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                  onPressed: _busy ? null : _addAthletes,
                  icon: const Icon(Icons.person_add),
                  label: Text(tr('Добавить'))),
            ],
          ),
          for (final c in _copies)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Press3D(
                padding: EdgeInsets.zero,
                accent: c.task.removed
                    ? theme.colorScheme.error
                    : (c.task.done ? Colors.green : null),
                onTap: c.task.runs.isEmpty ? null : () => _openRuns(c),
                child: ListTile(
                  leading: Icon(
                    c.task.removed
                        ? Icons.block
                        : (c.task.done
                            ? Icons.task_alt
                            : Icons.hourglass_empty),
                    color: c.task.removed
                        ? theme.colorScheme.error
                        : (c.task.done ? Colors.green : null),
                  ),
                  title: Text(c.athlete.name),
                  subtitle: Text(c.task.removed
                      ? tr('снято')
                      : (c.task.done
                          ? tr('выполнено: {n}', {'n': c.task.runs.length})
                          : tr('ещё не выполнял'))),
                  trailing: IconButton(
                    tooltip: c.task.removed ? tr('Вернуть') : tr('Снять'),
                    icon: Icon(c.task.removed
                        ? Icons.undo
                        : Icons.remove_circle_outline),
                    onPressed:
                        _busy ? null : () => _setRemoved(c, !c.task.removed),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (_plan.coachText.isNotEmpty) ...[
            Text(tr('Описание'), style: theme.textTheme.titleMedium),
            Text(_plan.coachText),
            const SizedBox(height: 12),
          ],
          TaskPlanView(plan: _plan),
        ],
      ),
    );
  }
}
