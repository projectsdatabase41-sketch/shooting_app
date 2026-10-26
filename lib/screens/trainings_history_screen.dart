import '../logic/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../logic/session_filter.dart';
import '../models/exercise.dart';
import '../models/training_session.dart';
import '../services/supabase_auth_service.dart';
import '../services/supabase_service.dart';
import '../state/app_data_store.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_pill.dart';
import '../widgets/session_filter_sheet.dart';
import '../widgets/swipe_to_delete.dart';
import 'exercise_history_detail_screen.dart';
import 'target_screen.dart';
import '../i18n/i18n.dart';

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
class TrainingsHistoryScreen extends StatefulWidget {
  final Exercise? exercise;
  const TrainingsHistoryScreen({super.key, this.exercise});

  @override
  State<TrainingsHistoryScreen> createState() => _TrainingsHistoryScreenState();
}

class _TrainingsHistoryScreenState extends State<TrainingsHistoryScreen> {
  SessionFilter _filter = SessionFilter();

  Future<void> _openFilter(AppDataStore store) async {
    final r = await showSessionFilterSheet(context, _filter, store.db);
    if (r != null && mounted) setState(() => _filter = r);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = context.watch<AppDataStore>();
    final ex = widget.exercise;
    final all = ex == null
        ? store.sessions
        : store.sessions.where((s) => s.exerciseId == ex.id).toList();
    // Заметки к выстрелам нужны только фильтру «с заметками».
    final noted = <String>{
      if (_filter.onlyWithNotes)
        for (final r in store.db.db.select("SELECT DISTINCT session_id FROM comments WHERE level = 'shot'")) '${r['session_id']}',
    };
    final sessions = _filter.isEmpty ? all : [for (final s in all) if (_filter.matches(s, hasNotes: noted.contains(s.id))) s];
    final df = DateFormat('dd.MM.yyyy · HH:mm');
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(ex?.label ?? tr('Тренировки'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          Badge(
            isLabelVisible: !_filter.isEmpty,
            label: Text('${_filter.count}'),
            child: GlassCircleButton(
              icon: const BoldIcon(Icons.filter_list),
              tooltip: tr('Фильтр'),
              onTap: () => _openFilter(store),
            ),
          ),
          if (ex != null) const SizedBox(width: 6),
          if (ex != null)
            GlassCircleButton(
              icon: const BoldIcon(Icons.add),
              tooltip: tr('Новая тренировка'),
              onTap: () => _startTraining(context, ex),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _pullFromCloud(context),
        child: sessions.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(top: topInset + GlassHeader.height),
                children: [
                  EmptyState(
                    icon: Icons.history,
                    text: all.isNotEmpty
                        ? tr('По фильтру ничего не найдено.')
                        : ex == null
                        ? tr(
                            'Тренировок пока нет. Начните первую на вкладке «Упражнения».')
                        : tr('У «{label}» пока нет тренировок.',
                            {'label': ex.label}),
                    action: all.isNotEmpty
                        ? TextButton(onPressed: () => setState(() => _filter = SessionFilter()), child: Text(tr('Сбросить фильтр')))
                        : ex == null
                        ? null
                        : FilledButton.icon(
                            icon: const Icon(Icons.add),
                            label: Text(tr('Создать первую')),
                            onPressed: () => _startTraining(context, ex),
                          ),
                  ),
                ],
              )
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                    16, topInset + GlassHeader.height + 8, 16, 32),
                itemCount: sessions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final s = sessions[i];
                  final exercise = store.exerciseFor(s);
                  final when = s.startedAt == null
                      ? ''
                      : tr(' от {p}', {'p': df.format(s.startedAt!)});
                  final empty = s.shots.isEmpty;
                  return SwipeToDelete(
                    itemKey: s.id,
                    // Пустую тренировку удалять не жалко, и длинное
                    // предупреждение здесь только раздражает.
                    title:
                        empty ? tr('Зря создал?') : tr('Удалить тренировку?'),
                    // Про необратимость — прямым текстом: тренировка
                    // стирается из базы вместе с выстрелами, вернуть её
                    // будет неоткуда.
                    message: empty
                        ? tr('В этой тренировке нет ни одного выстрела.')
                        : tr(
                            'Тренировка{when} и все {length} выстрелов будут удалены из базы без возможности восстановить.',
                            {'when': when, 'length': s.shots.length}),
                    confirmLabel: empty ? tr('Да') : tr('Удалить навсегда'),
                    cancelLabel: empty ? tr('Нет') : tr('Отмена'),
                    // Помечает на удаление сразу и толкает в облако тут же —
                    // иначе строка повисает pending_delete до следующей
                    // синхронизации, а «Восстановить всё из облака» на
                    // экране настроек снимает такие незавершённые отметки
                    // как зависшие, воскрешая то, что человек только что
                    // удалил (жалоба: "нажал удалить, потом восстановить —
                    // и всё вернулось").
                    onConfirmed: () {
                      store.deleteSession(s.id);
                      store.syncInBackground();
                    },
                    onConfirmedLocalOnly:
                        empty ? null : () => store.deleteSessionLocalOnly(s.id),
                    child: _SessionCard(
                      title: exercise?.label ?? s.exerciseId,
                      subtitle: s.startedAt == null
                          ? tr('Не начата')
                          : df.format(s.startedAt!),
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
                                  builder: (_) =>
                                      s.status == SessionStatus.finished
                                          ? ExerciseHistoryDetailScreen(
                                              session: s, exercise: exercise)
                                          : TargetScreen(
                                              session: s, exercise: exercise),
                                ),
                              ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _pullFromCloud(BuildContext context) async {
    final store = context.read<AppDataStore>();
    final sync = SupabaseSyncService(SupabaseAuthService(store.db));
    try {
      await sync.pull(store);
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
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
                    Text(
                        tr('{subtitle} · {shots} выстр.',
                            {'subtitle': subtitle, 'shots': shots}),
                        style: theme.textTheme.bodySmall),
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
                    style: theme.textTheme.titleLarge
                        ?.copyWith(color: AppTheme.accentFor(cs)),
                  ),
                  Text(
                    tr('с десятыми / целыми'),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant),
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
      SessionStatus.notStarted => (
          tr('Не начата'),
          cs.surfaceContainerHigh,
          cs.onSurfaceVariant
        ),
      SessionStatus.running => (
          tr('Идёт'),
          cs.secondaryContainer,
          cs.onSecondaryContainer
        ),
      SessionStatus.paused => (
          tr('Пауза'),
          cs.surfaceContainerHighest,
          cs.onSurfaceVariant
        ),
      SessionStatus.finished => (
          tr('Завершена'),
          cs.primaryContainer,
          cs.onPrimaryContainer
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        label,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}
