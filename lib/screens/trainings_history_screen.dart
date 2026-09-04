import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/training_session.dart';
import '../state/app_data_store.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/swipe_to_delete.dart';
import 'target_screen.dart';

/// Вкладка "История" (по составу навигации из макетов — переименование
/// вкладки "Тренировки" из раздела 1 ТЗ). Список завершённых/начатых
/// тренировок по датам, тап открывает экран мишени в режиме просмотра
/// истории (правка разрешена только если тренировка ещё не завершена —
/// см. canEdit, часть C.2).
///
/// Оформление: карточки вместо голых `ListTile` — в списке важны три
/// вещи сразу (что за упражнение, когда, с каким результатом) плюс
/// статус, а `ListTile` с `trailing: Text` их не различал по важности.
class TrainingsHistoryScreen extends StatelessWidget {
  const TrainingsHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppDataStore>();
    final sessions = store.sessions;
    final df = DateFormat('dd.MM.yyyy · HH:mm');

    return Scaffold(
      appBar: AppBar(title: const Text('История')),
      body: sessions.isEmpty
          ? const EmptyState(
              icon: Icons.history,
              text: 'Тренировок пока нет. Начните первую на вкладке «Тренировка».',
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
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
                  child: _SessionCard(
                    title: exercise?.label ?? s.exerciseId,
                    subtitle: s.startedAt == null ? 'Не начата' : df.format(s.startedAt!),
                    shots: s.shots.length,
                    totalScore: s.totalScore,
                    totalWhole: _wholeScore(s),
                    status: s.status,
                    onTap: exercise == null
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => TargetScreen(session: s, exercise: exercise),
                              ),
                            ),
                  ),
                );
              },
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
