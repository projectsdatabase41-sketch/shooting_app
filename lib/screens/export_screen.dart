import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/training_session.dart';
import '../services/session_import.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';

enum _Scope { all, exercise, session }

/// Экспорт тренировок — в формате, который приложение и само понимает
/// (`SessionImport.formatId`): резервная копия и перенос на другое
/// устройство без придумывания отдельного формата под каждую задачу.
///
/// Срезы и фильтр по датам — те же самые виджеты, что и на вкладке
/// "Статистика" (решение пользователя: "фильтр как в статистике"), а не
/// новый набор элементов управления ради одного экрана.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  _Scope _scope = _Scope.all;
  String? _exerciseId;
  String? _sessionId;
  int? _periodDays;
  bool _busy = false;
  String? _message;

  static const List<int> _periods = [5, 15, 30, 90];

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    // Сессии без даты начала экспортировать нечем — импорт такую
    // тренировку и сам не примет обратно (SessionImport требует
    // started_at), так что честнее не предлагать их вовсе.
    final sessions = store.sessions.where((s) => s.shots.isNotEmpty && s.startedAt != null).toList();

    if (sessions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Экспорт тренировок')),
        body: const EmptyState(
          icon: Icons.ios_share_outlined,
          text: 'Экспортировать пока нечего — нет ни одной записанной тренировки.',
        ),
      );
    }

    final selected = _selectSessions(store, sessions);
    final shotCount = selected.fold<int>(0, (a, s) => a + s.shots.length);

    return Scaffold(
      appBar: AppBar(title: const Text('Экспорт тренировок')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'Файл в формате приложения — тот же, что понимает импорт: '
            'подходит для резервной копии и переноса на другое устройство.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Scope>(
              segments: const [
                ButtonSegment(value: _Scope.all, label: Text('Всё')),
                ButtonSegment(value: _Scope.exercise, label: Text('Упражнение')),
                ButtonSegment(value: _Scope.session, label: Text('Тренировка')),
              ],
              selected: {_scope},
              showSelectedIcon: false,
              onSelectionChanged: (set) => setState(() => _scope = set.first),
            ),
          ),
          const SizedBox(height: 12),
          ..._scopePickers(store, sessions),
          _periodSelector(),
          const SizedBox(height: 16),
          Text(
            selected.isEmpty
                ? 'Под условия ничего не подходит'
                : 'К экспорту: ${selected.length} ${_sessionsWord(selected.length)}, '
                    '$shotCount ${_shotsWord(shotCount)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: selected.isEmpty || _busy ? null : () => _export(store, selected),
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            label: const Text('Экспортировать'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  List<Widget> _scopePickers(AppDataStore store, List<TrainingSession> sessions) {
    final df = DateFormat('dd.MM.yyyy HH:mm');
    switch (_scope) {
      case _Scope.all:
        return const [];
      case _Scope.exercise:
        final ids = sessions.map((s) => s.exerciseId).toSet();
        final exercises = store.exercises.where((e) => ids.contains(e.id)).toList();
        final current = exercises.any((e) => e.id == _exerciseId) ? _exerciseId : exercises.firstOrNull?.id;
        return [
          DropdownButtonFormField<String>(
            initialValue: current,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Упражнение'),
            items: [
              for (final e in exercises) DropdownMenuItem(value: e.id, child: Text(e.label, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _exerciseId = v),
          ),
          const SizedBox(height: 12),
        ];
      case _Scope.session:
        final current = sessions.any((s) => s.id == _sessionId) ? _sessionId : sessions.first.id;
        return [
          DropdownButtonFormField<String>(
            initialValue: current,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Тренировка'),
            items: [
              for (final s in sessions)
                DropdownMenuItem(
                  value: s.id,
                  child: Text(
                    '${store.exerciseFor(s)?.label ?? 'Без упражнения'} · ${df.format(s.startedAt!)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _sessionId = v),
          ),
          const SizedBox(height: 12),
        ];
    }
  }

  Widget _periodSelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
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

  List<TrainingSession> _selectSessions(AppDataStore store, List<TrainingSession> sessions) {
    Iterable<TrainingSession> list = sessions;
    switch (_scope) {
      case _Scope.all:
        break;
      case _Scope.exercise:
        final ids = sessions.map((s) => s.exerciseId).toSet();
        final id = ids.contains(_exerciseId) ? _exerciseId : ids.firstOrNull;
        list = list.where((s) => s.exerciseId == id);
      case _Scope.session:
        final id = sessions.any((s) => s.id == _sessionId) ? _sessionId : sessions.first.id;
        list = list.where((s) => s.id == id);
    }
    if (_periodDays != null) {
      final cutoff = DateTime.now().subtract(Duration(days: _periodDays!));
      list = list.where((s) => s.startedAt!.isAfter(cutoff));
    }
    return list.toList();
  }

  Future<void> _export(AppDataStore store, List<TrainingSession> sessions) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bundle = <String, dynamic>{
        'format': SessionImport.formatId,
        'version': SessionImport.supportedVersion,
        'source': 'Shooting App',
        'sessions': [
          for (final s in sessions) _sessionJson(store, s),
        ],
      };
      final jsonText = const JsonEncoder.withIndent('  ').convert(bundle);
      final bytes = Uint8List.fromList(utf8.encode(jsonText));
      final name = 'shooting_export_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.json';

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'application/json', name: name)],
          subject: 'Экспорт тренировок',
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _sessionJson(AppDataStore store, TrainingSession s) {
    final exercise = store.exerciseFor(s);
    return {
      'exercise': {
        'target_face_code': s.targetFaceCode,
        'name': exercise?.name ?? 'Без названия',
        'total_shots': exercise?.totalShots ?? s.shots.length,
        'series_size': exercise?.seriesSize ?? s.shots.length,
      },
      'started_at': s.startedAt!.toIso8601String(),
      'finished_at': s.finishedAt?.toIso8601String(),
      if (s.extra != null && s.extra!.isNotEmpty) 'extra': s.extra,
      'shots': [
        for (final sh in s.shots)
          {
            'n': sh.shotNumber,
            'series': sh.seriesNo,
            'x_mm': sh.xMm,
            'y_mm': sh.yMm,
            'score': sh.score,
            'time': sh.time.toIso8601String(),
            'counts': sh.counts,
            if (sh.extra != null && sh.extra!.isNotEmpty) 'extra': sh.extra,
          },
      ],
    };
  }

  static String _sessionsWord(int n) {
    final n100 = n % 100;
    if (n100 >= 11 && n100 <= 14) return 'тренировок';
    return switch (n % 10) {
      1 => 'тренировка',
      2 || 3 || 4 => 'тренировки',
      _ => 'тренировок',
    };
  }

  static String _shotsWord(int n) {
    final n100 = n % 100;
    if (n100 >= 11 && n100 <= 14) return 'выстрелов';
    return switch (n % 10) {
      1 => 'выстрел',
      2 || 3 || 4 => 'выстрела',
      _ => 'выстрелов',
    };
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
