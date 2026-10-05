import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/push_service.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import '../widgets/press_3d.dart';
import '../widgets/swipe_to_delete.dart';
import 'task_models.dart';
import 'task_run_screen.dart';
import 'task_service.dart';
import 'task_ui.dart';

/// Открыть задание по id (из push) — у спортсмена.
Future<void> openAthleteTask(BuildContext context, String taskId) async {
  final service =
      AthleteTaskService(SupabaseAuthService(context.read<AppDataStore>().db));
  if (!service.available) return;
  final task = await service.byId(taskId);
  if (task == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TaskRunScreen(task: task, service: service)));
}

enum _DoneSort { date, title }

/// «Задания» у спортсмена — что прислал тренер. Две вкладки: активные
/// (можно выполнить/выполнить ещё раз) и выполненные — отдельная вкладка
/// с сортировкой, чтобы не искать итоги среди активных (решение
/// пользователя: "итоги выполненного задания можно хранить во вкладке
/// выполненные, сортировка по дате и названию").
class AthleteTasksScreen extends StatefulWidget {
  const AthleteTasksScreen({super.key});

  @override
  State<AthleteTasksScreen> createState() => _AthleteTasksScreenState();
}

class _AthleteTasksScreenState extends State<AthleteTasksScreen> {
  late final AthleteTaskService _service =
      AthleteTaskService(SupabaseAuthService(context.read<AppDataStore>().db));
  List<TaskPlan>? _tasks;
  String? _error;
  _DoneSort _doneSort = _DoneSort.date;

  @override
  void initState() {
    super.initState();
    _load();
    // Адрес устройства — чтобы тренер мог прислать push о новом задании.
    PushService.deviceToken().then((t) {
      if (t != null && _service.available) _service.registerDevice(t);
    });
  }

  Future<void> _load() async {
    if (!_service.available) return;
    try {
      final list = await _service.list();
      if (mounted) setState(() => (_tasks = list, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _open(TaskPlan t) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TaskRunScreen(task: t, service: _service)));
    _load();
  }

  Future<void> _remove(TaskPlan t) async {
    final id = t.id;
    if (id == null) return;
    try {
      await _service.deleteForever(id);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget body;
    if (!_service.available) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              tr('Задания приходят в вашу базу — войдите в неё: Настройки → Учётная запись.'),
              textAlign: TextAlign.center),
        ),
      );
    } else if (_tasks == null) {
      body = Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Text(_error!));
    } else if (_tasks!.isEmpty) {
      body = Center(
          child: Text(tr('Заданий пока нет'),
              style: TextStyle(color: theme.hintColor)));
    } else {
      final active = [..._tasks!]..sort((a, b) {
          int rank(TaskPlan t) =>
              t.removed ? 2 : (t.done && (t.repeatRule ?? '').isEmpty ? 1 : 0);
          return rank(a).compareTo(rank(b));
        });
      final done = _tasks!.where((t) => t.done).toList()
        ..sort((a, b) => _doneSort == _DoneSort.title
            ? a.title.compareTo(b.title)
            : (_lastDoneAt(b) ?? DateTime(0))
                .compareTo(_lastDoneAt(a) ?? DateTime(0)));

      body = DefaultTabController(
        length: 2,
        child: Column(
          children: [
            TabBar(
              tabs: [
                Tab(text: tr('Активные')),
                Tab(text: tr('Выполненные ({n})', {'n': done.length}))
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  RefreshIndicator(
                    onRefresh: _load,
                    child: _list(theme, active, showDoneBadge: false),
                  ),
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: SegmentedButton<_DoneSort>(
                            segments: [
                              ButtonSegment(
                                  value: _DoneSort.date,
                                  label: Text(tr('По дате'))),
                              ButtonSegment(
                                  value: _DoneSort.title,
                                  label: Text(tr('По названию'))),
                            ],
                            selected: {_doneSort},
                            showSelectedIcon: false,
                            onSelectionChanged: (s) =>
                                setState(() => _doneSort = s.first),
                          ),
                        ),
                      ),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _load,
                          child: done.isEmpty
                              ? ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(32),
                                      child: Center(
                                        child: Text(
                                            tr('Выполненных заданий пока нет'),
                                            style: TextStyle(
                                                color: theme.hintColor)),
                                      ),
                                    ),
                                  ],
                                )
                              : _list(theme, done, showDoneBadge: true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: GlassHeader(
        title: Text(tr('Задания'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          GlassCircleButton(
              icon: const Icon(Icons.refresh),
              tooltip: tr('Обновить'),
              onTap: _load)
        ],
      ),
      body: body,
    );
  }

  /// Дата последнего завершённого прохождения — для сортировки
  /// вкладки "Выполненные" по дате.
  DateTime? _lastDoneAt(TaskPlan t) {
    final finished = [
      for (final r in t.runs)
        if (r.status == 'done' && r.finishedAt != null) r.finishedAt!
    ];
    if (finished.isEmpty) return null;
    return finished.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Widget _list(ThemeData theme, List<TaskPlan> items,
      {required bool showDoneBadge}) {
    return ListView(
      padding: const EdgeInsets.all(12),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final t in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SwipeToDelete(
              itemKey: '${showDoneBadge ? 'done-' : ''}${t.id ?? t.title}',
              title: tr('Удалить задание?'),
              message: tr(
                  '«{title}» будет удалено вместе с результатами. Отменить нельзя.',
                  {'title': t.title}),
              confirmLabel: tr('Удалить'),
              onConfirmed: () => _remove(t),
              child: Press3D(
                padding: EdgeInsets.zero,
                accent: t.removed
                    ? theme.colorScheme.error
                    : (t.done ? Colors.green : theme.colorScheme.primary),
                onTap: () => _open(t),
                child: ListTile(
                  leading: Icon(
                    t.removed
                        ? Icons.block
                        : (t.done ? Icons.task_alt : Icons.assignment_outlined),
                    color: t.removed
                        ? theme.colorScheme.error
                        : (t.done ? Colors.green : theme.colorScheme.primary),
                  ),
                  title: Text(t.title),
                  subtitle: Text([
                    tr('{n} ступ., {m} этап.',
                        {'n': t.stages.length, 'm': t.stepCount}),
                    if (t.removed) tr('снято тренером'),
                    if (showDoneBadge && _lastDoneAt(t) != null)
                      tr('выполнено {d}', {'d': _shortDate(_lastDoneAt(t)!)})
                    else if (t.done)
                      tr('выполнено: {n}', {
                        'n': t.runs.where((r) => r.status == 'done').length
                      }),
                    if (t.dueAt != null)
                      tr('до {d}', {
                        'd':
                            '${t.dueAt!.day}.${t.dueAt!.month.toString().padLeft(2, '0')}'
                      }),
                    if ((t.repeatRule ?? '').isNotEmpty)
                      repeatLabel(t.repeatRule),
                  ].join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static String _shortDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}
