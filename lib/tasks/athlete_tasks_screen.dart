import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/i18n.dart';
import '../services/push_service.dart';
import '../services/supabase_auth_service.dart';
import '../state/app_data_store.dart';
import '../widgets/glass_pill.dart';
import '../widgets/press_3d.dart';
import 'task_models.dart';
import 'task_run_screen.dart';
import 'task_service.dart';
import 'task_ui.dart';

/// Открыть задание по id (из push) — у спортсмена.
Future<void> openAthleteTask(BuildContext context, String taskId) async {
  final service = AthleteTaskService(SupabaseAuthService(context.read<AppDataStore>().db));
  if (!service.available) return;
  final task = await service.byId(taskId);
  if (task == null || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TaskRunScreen(task: task, service: service)));
}

/// «Задания» у спортсмена — что прислал тренер.
class AthleteTasksScreen extends StatefulWidget {
  const AthleteTasksScreen({super.key});

  @override
  State<AthleteTasksScreen> createState() => _AthleteTasksScreenState();
}

class _AthleteTasksScreenState extends State<AthleteTasksScreen> {
  late final AthleteTaskService _service = AthleteTaskService(SupabaseAuthService(context.read<AppDataStore>().db));
  List<TaskPlan>? _tasks;
  String? _error;

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
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TaskRunScreen(task: t, service: _service)));
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
          child: Text(tr('Задания приходят в вашу базу — войдите в неё: Настройки → Учётная запись.'),
              textAlign: TextAlign.center),
        ),
      );
    } else if (_tasks == null) {
      body = Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!));
    } else if (_tasks!.isEmpty) {
      body = Center(child: Text(tr('Заданий пока нет'), style: TextStyle(color: theme.hintColor)));
    } else {
      final sorted = [..._tasks!]..sort((a, b) {
          int rank(TaskPlan t) => t.removed ? 2 : (t.done && (t.repeatRule ?? '').isEmpty ? 1 : 0);
          return rank(a).compareTo(rank(b));
        });
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final t in sorted)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Press3D(
                  padding: EdgeInsets.zero,
                  accent: t.removed ? theme.colorScheme.error : (t.done ? Colors.green : theme.colorScheme.primary),
                  onTap: () => _open(t),
                  child: ListTile(
                    leading: Icon(
                      t.removed ? Icons.block : (t.done ? Icons.task_alt : Icons.assignment_outlined),
                      color: t.removed ? theme.colorScheme.error : (t.done ? Colors.green : theme.colorScheme.primary),
                    ),
                    title: Text(t.title),
                    subtitle: Text([
                      tr('{n} ступ., {m} этап.', {'n': t.stages.length, 'm': t.stepCount}),
                      if (t.removed) tr('снято тренером'),
                      if (t.done) tr('выполнено: {n}', {'n': t.runs.where((r) => r.status == 'done').length}),
                      if (t.dueAt != null)
                        tr('до {d}', {'d': '${t.dueAt!.day}.${t.dueAt!.month.toString().padLeft(2, '0')}'}),
                      if ((t.repeatRule ?? '').isNotEmpty) repeatLabel(t.repeatRule),
                    ].join(' · ')),
                    trailing: const Icon(Icons.chevron_right),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: GlassHeader(
        title: Text(tr('Задания'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        actions: [GlassCircleButton(icon: const Icon(Icons.refresh), tooltip: tr('Обновить'), onTap: _load)],
      ),
      body: body,
    );
  }
}
