import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/exercise.dart';
import '../models/training_session.dart';
import '../state/app_data_store.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/raised_3d_button.dart';
import '../widgets/swipe_to_delete.dart';
import 'exercise_history_detail_screen.dart';
import 'target_screen.dart';

/// Список тренировок. Без `exercise` — вся история разом (раньше это
/// была отдельная вкладка); с `exercise` — только тренировки ПО ЭТОМУ
/// упражнению, открывается тапом по нему из "Упражнения" (решение
/// пользователя: визуально объединить упражнения и тренировки в одну
/// плитку — открыл упражнение, увидел, что по нему настреляно, и тут же
/// кнопкой "+" начал следующую тренировку РОВНО по нему).
///
/// Тап на тренировку открывает экран мишени в режиме просмотра истории
/// (правка разрешена только если тренировка ещё не завершена — см.
/// canEdit, часть C.2).
///
/// Оформление: карточки вместо голых `ListTile` — в списке важны три
/// вещи сразу (что за упражнение, когда, с каким результатом) плюс
/// статус, а `ListTile` с `trailing: Text` их не различал по важности.
class TrainingsHistoryScreen extends StatelessWidget {
  final Exercise? exercise;
  const TrainingsHistoryScreen({super.key, this.exercise});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final ex = exercise;
    final sessions = ex == null ? store.sessions : store.sessions.where((s) => s.exerciseId == ex.id).toList();
    final df = DateFormat('dd.MM.yyyy · HH:mm');

    return Scaffold(
      appBar: AppBar(title: Text(ex?.label ?? 'Тренировки')),
      floatingActionButton: ex == null
          ? null
          : Raised3DButton(
              icon: Icons.add,
              label: 'Тренировка',
              baseColor: Theme.of(context).colorScheme.primary,
              onTap: () => _startTraining(context, ex),
            ),
      body: sessions.isEmpty
          ? EmptyState(
              icon: Icons.history,
              text: ex == null
                  ? 'Тренировок пока нет. Начните первую на вкладке «Упражнения».'
                  : 'У «${ex.label}» пока нет тренировок.',
              action: ex == null
                  ? null
                  : Raised3DButton(
                      icon: Icons.add,
                      label: 'Создать первую',
                      baseColor: Theme.of(context).colorScheme.primary,
                      onTap: () => _startTraining(context, ex),
                    ),
            )
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(16, 16, 16, ex == null ? 32 : 96),
              itemCount: sessions.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final s = sessions[i];
                final exercise = store.exerciseFor(s);
                final when = s.startedAt == null ? '' : ' от ${df.format(s.startedAt!)}';
                final empty = s.shots.isEmpty;
                return SwipeToDelete(
                  itemKey: s.id,
                  // Пустую тренировку удалять не жалко, и длинное
                  // предупреждение здесь только раздражает.
                  title: empty ? 'Зря создал?' : 'Удалить тренировку?',
                  // Про необратимость — прямым текстом: тренировка
                  // стирается из базы вместе с выстрелами, вернуть её
                  // будет неоткуда.
                  message: empty
                      ? 'В этой тренировке нет ни одного выстрела.'
                      : 'Тренировка$when и все ${s.shots.length} выстрелов '
                          'будут удалены из базы без возможности восстановить.',
                  confirmLabel: empty ? 'Да' : 'Удалить навсегда',
                  cancelLabel: empty ? 'Нет' : 'Отмена',
                  onConfirmed: () => store.deleteSession(s.id),
                  onConfirmedLocalOnly: empty ? null : () => store.deleteSessionLocalOnly(s.id),
                  child: _SessionCard(
                    title: exercise?.label ?? s.exerciseId,
                    subtitle: s.startedAt == null ? 'Не начата' : df.format(s.startedAt!),
                    shots: s.shots.length,
                    totalScore: s.totalScore,
                    totalWhole: _wholeScore(s),
                    status: s.status,
                    // Завершённую тренировку открываем новым экраном
                    // просмотра (раздел 8 ТЗ: перестраиваемые блоки —
                    // мишень со слайдером, серии, статистика, чат),
                    // незавершённую — рабочим столом тренировки как
                    // раньше, там же и продолжают запись.
                    onTap: exercise == null
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => s.status == SessionStatus.finished
                                    ? ExerciseHistoryDetailScreen(session: s, exercise: exercise)
                                    : TargetScreen(session: s, exercise: exercise),
                              ),
                            ),
                  ),
                );
              },
            ),
    );
  }

  void _startTraining(BuildContext context, Exercise exercise) {
    final session = TrainingSession(
      id: const Uuid().v4(),
      exerciseId: exercise.id,
      targetFaceCode: exercise.targetFaceCode,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TargetScreen(session: session, exercise: exercise),
      ),
    );
  }
}

/// Сумма целыми габаритами: у каждого выстрела берётся целая часть.
/// Округлять готовую сумму нельзя — 10.9 + 10.9 это 20 очков целыми,
/// а не 22.
int _wholeScore(TrainingSession s) {
  var sum = 0;
  for (final shot in s.shots) {
    sum += shot.score.floor();
  }
  return sum;
}

class _SessionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final int shots;
  final double totalScore;

  /// Тот же результат целыми габаритами — считается по выстрелам, а не
  /// округлением суммы.
  final int totalWhole;
  final SessionStatus status;
  final VoidCallback? onTap;

  const _SessionCard({
    required this.title,
    required this.subtitle,
    required this.shots,
    required this.totalScore,
    required this.totalWhole,
    required this.status,
    this.onTap,
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
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text('$subtitle · $shots выстр.', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    _StatusChip(status: status),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    // Через дробь: слева с десятыми, справа целыми —
                    // ровно так, как результат объявляют на стрельбище.
                    // Слово «очков» убрано: подпись ниже и так говорит,
                    // что это за числа.
                    '${totalScore.toStringAsFixed(1)} / $totalWhole',
                    style: theme.textTheme.titleLarge?.copyWith(color: AppTheme.accentFor(cs)),
                  ),
                  Text(
                    'с десятыми / целыми',
                    style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final SessionStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final (String label, Color bg, Color fg) = switch (status) {
      SessionStatus.notStarted => ('Не начата', cs.surfaceContainerHigh, cs.onSurfaceVariant),
      SessionStatus.running => ('Идёт', cs.secondaryContainer, cs.onSecondaryContainer),
      SessionStatus.paused => ('Пауза', cs.surfaceContainerHighest, cs.onSurfaceVariant),
      SessionStatus.finished => ('Завершена', cs.primaryContainer, cs.onPrimaryContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}
