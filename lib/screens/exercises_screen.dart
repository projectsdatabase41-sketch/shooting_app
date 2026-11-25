import '../logic/friendly_error.dart';
import '../services/starter_exercises.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/exercise.dart';
import '../models/series_spec.dart';
import '../models/target_face.dart';
import '../services/supabase_auth_service.dart';
import '../services/supabase_service.dart';
import '../state/app_data_store.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass_pill.dart';
import '../widgets/stance_icon.dart';
import '../widgets/swipe_to_delete.dart';
import 'exercise_editor_screen.dart';
import 'trainings_history_screen.dart';
import '../i18n/i18n.dart';
import '../services/user_profile.dart';

/// Список упражнений-шаблонов (решение пользователя: "Упражнения" и
/// "Тренировки" объединены визуально в одну плитку) — тап по упражнению
/// открывает список ЕГО тренировок (`TrainingsHistoryScreen`), а не
/// сразу новую тренировку: там же, кнопкой "+", создают следующую по
/// этому упражнению. Приложение стартует пустым — без предустановленного
/// набора упражнений (раздел 10 ТЗ).
class ExercisesScreen extends StatefulWidget {
  const ExercisesScreen({super.key});

  @override
  State<ExercisesScreen> createState() => _ExercisesScreenState();
}

class _ExercisesScreenState extends State<ExercisesScreen> {
  @override
  void initState() {
    super.initState();
    // Первое открытие: типовые упражнения по профилю (вид стрельбы, пол).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) StarterExercises.seedIfNeeded(context.read<AppDataStore>());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = context.watch<AppDataStore>();
    // Считаем один раз: activeExercises каждый раз строит новый список,
    // а itemBuilder вызывается на каждую строку.
    // Только спортсмену: упражнения, подходящие по данным профиля (вид стрельбы, пол) либо уже с тренировками.
    final list = store.isCoach
        ? store.activeExercises
        : [
            for (final e in store.activeExercises)
              if (UserProfile.exerciseRelevant(store.db, e.targetFaceCode, e.gender.name) || store.sessions.any((s) => s.exerciseId == e.id)) e
          ];
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassHeader(
        title: Text(tr('Упражнения'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        actions: [
          GlassCircleButton(
            icon: const BoldIcon(Icons.add),
            tooltip: tr('Новое упражнение'),
            onTap: () => _showCreateExerciseDialog(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _pullFromCloud(context),
        child: list.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(top: topInset + GlassHeader.height),
                children: [
                  EmptyState(
                    icon: Icons.fitness_center,
                    text: tr(
                        'Упражнений пока нет — приложение стартует полностью пустым.'),
                    action: FilledButton.icon(
                      icon: const Icon(Icons.add),
                      label: Text(tr('Создать первое')),
                      onPressed: () => _showCreateExerciseDialog(context),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                    16, topInset + GlassHeader.height + 8, 16, 32),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final ex = list[i];
                  final face = TargetFace.byCode(ex.targetFaceCode);
                  final used =
                      store.sessions.where((s) => s.exerciseId == ex.id).length;
                  return SwipeToDelete(
                    itemKey: ex.id,
                    title: tr('Удалить упражнение?'),
                    message: used == 0
                        ? tr(
                            '«{name}» будет удалено насовсем — или можно просто скрыть его из списка.',
                            {
                                'name': ex.shownName
                              })
                        : tr(
                            '«{name}»: {used} {p} останутся в истории. «Скрыть» — можно вернуть кнопкой «Восстановить всё из облака»; «Удалить навсегда» — стирает упражнение без возможности восстановить, тренировки останутся без его названия.',
                            {
                                'name': ex.shownName,
                                'used': used,
                                'p': _sessionsWord(used)
                              }),
                    confirmLabel: tr('Удалить навсегда'),
                    localOnlyLabel: tr('Скрыть'),
                    onConfirmed: () => store.deleteExerciseForever(ex.id),
                    onConfirmedLocalOnly: () => _deleteExercise(context, ex),
                    child: _ExerciseCard(
                      onRename: () => _rename(context, ex),
                      onMerge: () => _merge(context, ex),
                      name: ex.shownName,
                      faceName: face.name,
                      totalShots: ex.totalShots,
                      seriesSize: ex.seriesSize,
                      series: ex.series,
                      stance: _stanceFor(ex),
                      weapon: _weaponFor(face),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) =>
                                TrainingsHistoryScreen(exercise: ex)),
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

  Future<void> _rename(BuildContext context, Exercise ex) async {
    final store = context.read<AppDataStore>();
    final ctl = TextEditingController(text: ex.shownName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Название упражнения')),
        content: TextField(controller: ctl, autofocus: true, textCapitalization: TextCapitalization.sentences),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: Text(tr('Сохранить'))),
        ],
      ),
    );
    ctl.dispose();
    if (name != null && name.isNotEmpty) store.renameExercise(ex.id, name);
  }

  /// Объединение: все тренировки выбранного упражнения переходят в другое, выбранное — скрывается.
  Future<void> _merge(BuildContext context, Exercise ex) async {
    final store = context.read<AppDataStore>();
    final others = [for (final e in store.activeExercises) if (e.id != ex.id) e]
      ..sort((a, b) => (a.targetFaceCode == ex.targetFaceCode ? 0 : 1).compareTo(b.targetFaceCode == ex.targetFaceCode ? 0 : 1));
    if (others.isEmpty) return;
    final target = await showDialog<Exercise>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Перенести тренировки «{name}» в…', {'name': ex.shownName})),
        children: [
          for (final e in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e),
              child: Text(e.shownName + (e.targetFaceCode == ex.targetFaceCode ? '' : ' · ${TargetFace.byCode(e.targetFaceCode).name}')),
            ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Объединить упражнения?')),
        content: Text(tr('Тренировки «{a}» перейдут в «{b}», а «{a}» будет скрыто.', {'a': ex.shownName, 'b': target.shownName})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Отмена'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Объединить'))),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    final n = store.mergeExercises(ex.id, target.id);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Перенесено тренировок: {n}', {'n': n}))));
  }

  void _deleteExercise(BuildContext context, Exercise ex) {
    final store = context.read<AppDataStore>();
    final messenger = ScaffoldMessenger.of(context);
    store.deleteExercise(ex.id);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(tr('Упражнение «{name}» удалено', {'name': ex.shownName})),
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
  final StanceKind stance;
  final WeaponKind weapon;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onMerge;

  const _ExerciseCard({
    required this.onRename,
    required this.onMerge,
    required this.name,
    required this.faceName,
    required this.totalShots,
    required this.seriesSize,
    required this.series,
    required this.stance,
    required this.weapon,
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
                child: Center(
                  child: StanceIcon(
                    size: 24,
                    stance: stance,
                    weapon: weapon,
                    color: cs.onPrimaryContainer,
                    semanticLabel: tr('Изготовка'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(faceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: series.isEmpty
                          // Старое упражнение описывается парой чисел.
                          ? [
                              _MiniChip(
                                  text: tr('{totalShots} выстр.',
                                      {'totalShots': totalShots})),
                              _MiniChip(
                                  text: tr('серия {seriesSize}',
                                      {'seriesSize': seriesSize})),
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
                                          ? tr('{name} {p} мин', {
                                              'name': spec.name,
                                              'p': spec.timeLimit!.inMinutes
                                            })
                                          : spec.name,
                                  muted: !spec.counts,
                                ),
                            ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: tr('Действия'),
                icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant),
                onSelected: (v) => v == 'rename' ? onRename() : onMerge(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'rename', child: Text(tr('Переименовать'))),
                  PopupMenuItem(value: 'merge', child: Text(tr('Объединить с другим…'))),
                ],
              ),
              // Стрелка справа убрана: тап по всей плитке и так открывает
              // упражнение (отзыв 16.11 «убрать её, и так понятно»).
            ],
          ),
        ),
      ),
    );
  }
}

/// Изготовка для значка карточки упражнения (отзыв a69f8d83).
///
/// Признаки, которые реально есть в данных упражнения:
/// - три положения по названию: «3 положения», «три положения», «3П»,
///   «3×40»/«3x20» (стартовый набор: «Винтовка 50 м, 3 положения — …»,
///   нормативы: «МВ-3×40»); либо свободная структура серий, где по названиям
///   серий встречаются все три изготовки («лёжа», «с колена», «стоя» —
///   слова те же, что в `stanceFromName` из finals/bot.dart);
/// - одиночная изготовка — теми же словами в названии, затем в названиях серий.
/// Признаков не хватает — характерное значение по умолчанию: standing.
StanceKind _stanceFor(Exercise ex) {
  final name = '${ex.name} ${ex.shownName}'.toLowerCase();
  if (name.contains('3 полож') ||
      name.contains('три полож') ||
      name.contains('3п') ||
      RegExp(r'3\s*[×x]').hasMatch(name)) {
    return StanceKind.allThree;
  }
  var prone = false, kneeling = false, standing = false;
  for (final spec in ex.series) {
    final s = spec.name.toLowerCase();
    if (s.contains('лёж')) prone = true;
    if (s.contains('колен')) kneeling = true;
    if (s.contains('стоя') || s.contains('стойк')) standing = true;
  }
  if (prone && kneeling && standing) return StanceKind.allThree;
  // Одиночная изготовка — по названию упражнения, затем по названиям серий.
  return _stanceOfWord(name) ?? _stanceOfSeries(ex.series) ?? StanceKind.standing;
}

StanceKind? _stanceOfWord(String s) {
  if (s.contains('лёж')) return StanceKind.prone;
  if (s.contains('колен')) return StanceKind.kneeling;
  if (s.contains('стоя') || s.contains('стойк')) return StanceKind.standing;
  return null;
}

StanceKind? _stanceOfSeries(List<SeriesSpec> series) {
  for (final spec in series) {
    if (spec.counts) {
      final found = _stanceOfWord(spec.name.toLowerCase());
      if (found != null) return found;
    }
  }
  return null;
}

/// Оружие для значка — по коду мишени, как и во всём приложении
/// (`UserProfile.exerciseRelevant` различает дисциплины префиксом «pistol»);
/// IPSC тоже считается пистолетом (`TargetFace.isIpsc` —
/// «пистолет/ружьё»). Не пистолетная мишень — по умолчанию rifle.
WeaponKind _weaponFor(TargetFace face) =>
    face.code.startsWith('pistol') || face.isIpsc
        ? WeaponKind.pistol
        : WeaponKind.rifle;

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
