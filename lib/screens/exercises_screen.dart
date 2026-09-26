import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/exercise.dart';
import '../models/series_spec.dart';
import '../models/target_face.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import '../widgets/raised_3d_button.dart';
import '../widgets/swipe_to_delete.dart';
import 'exercise_editor_screen.dart';
import 'trainings_history_screen.dart';
import '../i18n/i18n.dart';

/// Список упражнений-шаблонов (решение пользователя: "Упражнения" и
/// "Тренировки" объединены визуально в одну плитку) — тап по упражнению
/// открывает список ЕГО тренировок (`TrainingsHistoryScreen`), а не
/// сразу новую тренировку: там же, кнопкой "+", создают следующую по
/// этому упражнению. Приложение стартует пустым — без предустановленного
/// набора упражнений (раздел 10 ТЗ).
class ExercisesScreen extends StatelessWidget {
  const ExercisesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    // Считаем один раз: activeExercises каждый раз строит новый список,
    // а itemBuilder вызывается на каждую строку.
    final list = store.activeExercises;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Упражнения'))),
      // На пустом списке кнопка создания уже есть в самом EmptyState —
      // вторая, плавающая, с тем же действием рядом только дублировала
      // её и спорила за внимание. FAB нужен, когда список уже не пуст:
      // тогда центральной кнопки нет и создавать больше не откуда.
      floatingActionButton: list.isEmpty
          ? null
          : Raised3DButton(
              icon: Icons.add,
              label: tr('Упражнение'),
              baseColor: Theme.of(context).colorScheme.primary,
              onTap: () => _showCreateExerciseDialog(context),
            ),
      body: list.isEmpty
          ? EmptyState(
              icon: Icons.fitness_center,
              text: tr('Упражнений пока нет — приложение стартует полностью пустым.'),
              action: Raised3DButton(
                icon: Icons.add,
                label: tr('Создать первое'),
                baseColor: Theme.of(context).colorScheme.primary,
                onTap: () => _showCreateExerciseDialog(context),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final ex = list[i];
                final face = TargetFace.byCode(ex.targetFaceCode);
                final used = store.sessions.where((s) => s.exerciseId == ex.id).length;
                return SwipeToDelete(
                  itemKey: ex.id,
                  title: tr('Удалить упражнение?'),
                  message: used == 0
                      ? tr('«{name}» пропадёт из списка. Тренировок по нему пока нет.', {'name': ex.name})
                      : tr('«{name}» пропадёт из списка, но {used} {p} останутся в истории — вместе с названием упражнения.', {'name': ex.name, 'used': used, 'p': _sessionsWord(used)}),
                  onConfirmed: () => _deleteExercise(context, ex),
                  child: _ExerciseCard(
                    name: ex.name,
                    faceName: face.name,
                    totalShots: ex.totalShots,
                    seriesSize: ex.seriesSize,
                    series: ex.series,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => TrainingsHistoryScreen(exercise: ex)),
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// Склонение для «3 тренировки останутся».
  static String _sessionsWord(int n) {
    final n100 = n % 100;
    if (n100 >= 11 && n100 <= 14) return tr('тренировок');
    return switch (n % 10) {
      1 => tr('тренировка'),
      2 || 3 || 4 => tr('тренировки'),
      _ => tr('тренировок'),
    };
  }

  void _deleteExercise(BuildContext context, Exercise ex) {
    final store = context.read<AppDataStore>();
    final messenger = ScaffoldMessenger.of(context);
    store.deleteExercise(ex.id);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(tr('Упражнение «{name}» удалено', {'name': ex.name})),
        action: SnackBarAction(
          label: tr('Отменить'),
          onPressed: () => store.restoreExercise(ex.id),
        ),
      ),
    );
  }

  /// Создание упражнения — отдельный экран, а не диалог.
  ///
  /// Структура серий бывает из шести пунктов по три поля в каждом, и в
  /// диалог такое не помещается.
  void _showCreateExerciseDialog(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ExerciseEditorScreen()),
    );
  }
}

/// Карточка упражнения в списке "Тренировка".
///
/// Вместо прежнего `ListTile` с одной строкой-подписью: название,
/// мишень отдельной строкой и два числовых параметра чипами — по ним
/// упражнение и опознаётся, а в слитной подписи они терялись.
class _ExerciseCard extends StatelessWidget {
  final String name;
  final String faceName;
  final int totalShots;
  final int seriesSize;

  /// Описание серий. Пустой список — упражнение старого вида.
  final List<SeriesSpec> series;
  final VoidCallback onTap;

  const _ExerciseCard({
    required this.name,
    required this.faceName,
    required this.totalShots,
    required this.seriesSize,
    required this.series,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          // Вертикальный отступ -10% (решение пользователя) — высота
          // строки, не ширина.
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12.6),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.gps_fixed, size: 20, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(faceName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: series.isEmpty
                          // Старое упражнение описывается парой чисел.
                          ? [
                              _MiniChip(text: tr('{totalShots} выстр.', {'totalShots': totalShots})),
                              _MiniChip(text: tr('серия {seriesSize}', {'seriesSize': seriesSize})),
                            ]
                          // У свободной структуры важны сами серии, а не
                          // сумма: «Пристрелка 15 мин · Лёжа 10 · Стоя
                          // 10» — это и есть задание.
                          : [
                              for (final spec in series)
                                _MiniChip(
                                  text: spec.shotCount != null
                                      ? '${spec.name} ${spec.shotCount}'
                                      : spec.timeLimit != null
                                          ? tr('{name} {p} мин', {'name': spec.name, 'p': spec.timeLimit!.inMinutes})
                                          : spec.name,
                                  muted: !spec.counts,
                                ),
                            ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant, size: 28),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String text;

  /// Приглушённый вид — для серий без зачёта.
  final bool muted;

  const _MiniChip({required this.text, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: muted ? cs.surfaceContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: muted ? Border.all(color: cs.outlineVariant) : null,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: muted ? cs.outline : cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontStyle: muted ? FontStyle.italic : null,
        ),
      ),
    );
  }
}
