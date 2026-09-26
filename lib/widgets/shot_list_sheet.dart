import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/shot.dart';
import '../services/comments_repository.dart';
import '../state/app_data_store.dart';
import '../state/target_view_model.dart';
import 'add_shot_dialog.dart';
import 'favorites_sheet.dart';
import 'shot_actions_sheet.dart';
import 'trash_sheet.dart';
import '../i18n/i18n.dart';

/// Шторка списка выстрелов (раздел 5 ТЗ) — 85% высоты экрана. Наверху:
/// корзина/избранное (бейджи, открывают отдельные списки — решение
/// пользователя, пункт 8 списка правок) плюс комментарии текущего
/// выстрела и кнопка "+" ручного добавления. Список разбит на группы по
/// сериям.
///
/// Тап по строке — выбрать выстрел и сразу перейти на мишень. Долгое
/// нажатие (НЕ свайп — свайп по строке уже пробовали и убрали, см. ниже)
/// открывает меню действий (`ShotActionsSheet`): там же теперь и
/// избранное/удаление, поэтому отдельных кнопок на самой строке больше
/// нет — это и короче саму строку делает.
///
/// Свайп по строке когда-то был для удаления, и его убрали:
/// список и так прокручивается и открывается снизу вверх, свайп путался
/// с обоими жестами.
class ShotListSheet extends StatefulWidget {
  const ShotListSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: ChangeNotifierProvider.value(
          value: context.read<TargetViewModel>(),
          child: const ShotListSheet(),
        ),
      ),
    );
  }

  @override
  State<ShotListSheet> createState() => _ShotListSheetState();
}

class _ShotListSheetState extends State<ShotListSheet> {
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final store = context.watch<AppDataStore>();
    final repo = CommentsRepository(store.db);
    final shots = vm.session.shots;
    final grouped = <int, List<Shot>>{};
    for (final s in shots) {
      grouped.putIfAbsent(s.seriesNo, () => []).add(s);
    }
    final seriesNumbers = grouped.keys.toList()..sort();

    return SafeArea(
      child: Column(
        children: [
          const _Header(),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: seriesNumbers.length,
              itemBuilder: (context, i) {
                final seriesNo = seriesNumbers[i];
                final seriesShots = grouped[seriesNo]!;
                final sum = seriesShots.fold(0.0, (a, s) => a + s.score);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        // У упражнения со свободной структурой серия
                        // называется своим именем: «Пристрелка» говорит
                        // больше, чем «Серия 1». Незачётная помечается
                        // явно — иначе непонятно, почему её сумма не
                        // сходится с итогом тренировки.
                        [
                          vm.exercise.specFor(seriesNo)?.name ?? tr('Серия {seriesNo}', {'seriesNo': seriesNo}),
                          tr('{length} выстр.', {'length': seriesShots.length}),
                          'Σ ${sum.toStringAsFixed(1)}',
                          if (!vm.exercise.countsSeries(seriesNo)) tr('без зачёта'),
                        ].join(' · '),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    for (final shot in seriesShots)
                      _ShotRow(
                        shot: shot,
                        hasNote: repo.forShot(vm.session.id, shot.id).isNotEmpty,
                        onTap: () => vm.selectAndJumpToTarget(vm.session.shots.indexOf(shot)),
                        onLongPress: () => ShotActionsSheet.show(context, shot),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка выстрела: слева номер + результат (крупнее), справа
/// координаты. На 20% ниже прежней (решение пользователя, пункт 1
/// списка правок) — компактной строку и делает как раз отсутствие
/// кнопок на ней (см. класс выше).
class _ShotRow extends StatelessWidget {
  final Shot shot;
  final bool hasNote;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ShotRow({
    required this.shot,
    required this.hasNote,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey(shot.id),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        // Прежний ListTile давал ~56px строку; тут — заметно компактнее
        // (плотный вертикальный отступ вместо стандартного), это и есть
        // те самые "минус 20%".
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            if (shot.isFavorite) ...[
              Icon(Icons.star, size: 16, color: Colors.amber.shade700),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: theme.textTheme.bodyMedium,
                  children: [
                    TextSpan(text: '${shot.shotNumber} '),
                    TextSpan(
                      text: shot.score.toStringAsFixed(1),
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            if (hasNote) ...[
              Icon(Icons.notes_outlined, size: 15, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
            ],
            Text(
              'X ${shot.xMm.toStringAsFixed(1)}  Y ${shot.yMm.toStringAsFixed(1)}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final favoritesCount = vm.session.shots.where((s) => s.isFavorite).length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          if (vm.canEditShots)
            Badge(
              label: Text('${vm.session.trash.length}'),
              isLabelVisible: vm.session.trash.isNotEmpty,
              child: IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: tr('Корзина'),
                onPressed: () => TrashSheet.show(context),
              ),
            ),
          Badge(
            label: Text('$favoritesCount'),
            isLabelVisible: favoritesCount > 0,
            child: IconButton(
              icon: const Icon(Icons.star_border),
              tooltip: tr('Избранное'),
              onPressed: () => FavoritesSheet.show(context),
            ),
          ),
          if (vm.canEditShots)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: tr('Добавить выстрел'),
              onPressed: () => AddShotDialog.show(context),
            ),
          const Spacer(),
          // Крестик только у шторки. Как страница рабочего стола список
          // закрывать некуда — закрытие увело бы с самого рабочего
          // стола.
          if (Navigator.of(context).canPop())
            IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}
