import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/series_spec.dart';
import '../models/target_face.dart';
import '../state/app_data_store.dart';
import '../widgets/weapon_icon.dart';

/// Создание упражнения со свободной структурой серий.
///
/// Прежний диалог умел ровно одно упражнение: «столько-то выстрелов, по
/// столько-то в серии». Реальное задание так не описывается — бывает
/// «пристрелка 15 минут, потом 10 лёжа, потом 10 стоя», где у каждой
/// части своя длина, своя граница (выстрелы или время) и свой ответ на
/// вопрос, идёт ли она в зачёт.
///
/// Это отдельный экран, а не диалог: серий может быть шесть, у каждой
/// три поля, и в диалоге такое не помещается.
class ExerciseEditorScreen extends StatefulWidget {
  const ExerciseEditorScreen({super.key});

  @override
  State<ExerciseEditorScreen> createState() => _ExerciseEditorScreenState();
}

class _ExerciseEditorScreenState extends State<ExerciseEditorScreen> {
  final _name = TextEditingController();
  String _faceCode = TargetFace.rifle10m.code;

  /// Простой режим — одинаковые серии, как было раньше. Он закрывает
  /// девять случаев из десяти, и заставлять расписывать шесть
  /// одинаковых серий руками было бы издевательством.
  bool _simple = true;
  final _totalShots = TextEditingController(text: '60');
  final _seriesSize = TextEditingController(text: '10');

  final List<SeriesSpec> _series = [
    const SeriesSpec(name: 'Пристрелка', timeLimit: Duration(minutes: 15), counts: false),
    const SeriesSpec(name: 'Лёжа', shotCount: 10),
  ];

  @override
  void dispose() {
    _name.dispose();
    _totalShots.dispose();
    _seriesSize.dispose();
    super.dispose();
  }

  int get _plannedShots {
    var total = 0;
    for (final s in _series) {
      total += s.shotCount ?? 0;
    }
    return total;
  }

  bool get _canSave {
    if (_name.text.trim().isEmpty) return false;
    if (_simple) return true;
    return _series.isNotEmpty;
  }

  void _save() {
    final store = context.read<AppDataStore>();
    if (_simple) {
      store.createExercise(
        name: _name.text.trim(),
        targetFaceCode: _faceCode,
        totalShots: int.tryParse(_totalShots.text) ?? 60,
        seriesSize: int.tryParse(_seriesSize.text) ?? 10,
      );
    } else {
      // totalShots и seriesSize остаются заполненными и в гибком
      // режиме: на них опирается старый код (нумерация серий у
      // упражнений без описания, подписи в списках). Считаем их по
      // фактическому набору серий.
      final counted = _plannedShots;
      final firstWithCount = _series.firstWhere(
        (s) => s.shotCount != null,
        orElse: () => const SeriesSpec(name: '', shotCount: 10),
      );
      store.createExercise(
        name: _name.text.trim(),
        targetFaceCode: _faceCode,
        totalShots: counted > 0 ? counted : 60,
        seriesSize: firstWithCount.shotCount ?? 10,
        series: List.of(_series),
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Новое упражнение'),
        actions: [
          TextButton(
            onPressed: _canSave ? _save : null,
            child: const Text('СОЗДАТЬ'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Название'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _faceCode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Мишень'),
            items: [
              for (final f in TargetFace.all)
                DropdownMenuItem(
                  value: f.code,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      WeaponIcon(face: f, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Flexible(child: Text(f.name, overflow: TextOverflow.ellipsis, maxLines: 1)),
                    ],
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _faceCode = v ?? _faceCode),
          ),
          const SizedBox(height: 20),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Одинаковые серии')),
              ButtonSegment(value: false, label: Text('Своя структура')),
            ],
            selected: {_simple},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _simple = v.first),
          ),
          const SizedBox(height: 16),
          if (_simple) ...[
            TextField(
              controller: _totalShots,
              decoration: const InputDecoration(labelText: 'Всего выстрелов'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _seriesSize,
              decoration: const InputDecoration(labelText: 'Выстрелов в серии'),
              keyboardType: TextInputType.number,
            ),
          ] else ...[
            Text(
              'Серии идут сверху вниз. Каждая заканчивается либо по числу '
              'выстрелов, либо по времени. Снятый зачёт означает, что серия '
              'записывается и видна на мишени, но в сумму и статистику не идёт.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _series.length; i++)
              _SeriesCard(
                index: i,
                spec: _series[i],
                onChanged: (s) => setState(() => _series[i] = s),
                onRemove: _series.length > 1
                    ? () => setState(() => _series.removeAt(i))
                    : null,
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _series.add(const SeriesSpec(name: 'Стоя', shotCount: 10));
              }),
              icon: const Icon(Icons.add),
              label: const Text('Добавить серию'),
            ),
            const SizedBox(height: 12),
            Text(
              'Всего в зачёт: ${_countingShots()} из $_plannedShots выстрелов',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }

  int _countingShots() {
    var total = 0;
    for (final s in _series) {
      if (s.counts) total += s.shotCount ?? 0;
    }
    return total;
  }
}

/// Одна серия в редакторе: название, граница, зачёт.
class _SeriesCard extends StatelessWidget {
  final int index;
  final SeriesSpec spec;
  final ValueChanged<SeriesSpec> onChanged;
  final VoidCallback? onRemove;

  const _SeriesCard({
    required this.index,
    required this.spec,
    required this.onChanged,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final byTime = spec.isTimed;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${index + 1}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    initialValue: spec.name,
                    decoration: const InputDecoration(
                      labelText: 'Название',
                      isDense: true,
                    ),
                    onChanged: (v) => onChanged(spec.copyWith(name: v)),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Убрать серию',
                    onPressed: onRemove,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Готовые названия — быстрый выбор, но поле выше остаётся
            // свободным: пользователь просил именно так.
            Wrap(
              spacing: 6,
              children: [
                for (final name in SeriesSpec.suggestedNames)
                  ActionChip(
                    label: Text(name),
                    onPressed: () => onChanged(spec.copyWith(name: name)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Выстрелы')),
                      ButtonSegment(value: true, label: Text('Время')),
                    ],
                    selected: {byTime},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => onChanged(
                      v.first
                          ? spec.copyWith(
                              clearShotCount: true,
                              timeLimit: spec.timeLimit ?? const Duration(minutes: 15),
                            )
                          : spec.copyWith(
                              clearTimeLimit: true,
                              shotCount: spec.shotCount ?? 10,
                            ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: ValueKey('limit_${index}_$byTime'),
              initialValue: byTime
                  ? '${spec.timeLimit?.inMinutes ?? 15}'
                  : '${spec.shotCount ?? 10}',
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: byTime ? 'Минут' : 'Выстрелов',
                isDense: true,
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n == null || n <= 0) return;
                onChanged(byTime
                    ? spec.copyWith(timeLimit: Duration(minutes: n))
                    : spec.copyWith(shotCount: n));
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Идёт в зачёт'),
              value: spec.counts,
              onChanged: (v) => onChanged(spec.copyWith(counts: v)),
            ),
          ],
        ),
      ),
    );
  }
}
