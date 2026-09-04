import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/shot.dart';
import '../state/target_view_model.dart';
import 'comments_thread.dart';
import 'trash_sheet.dart';

/// Шторка списка выстрелов (раздел 5 ТЗ) — 85% высоты экрана. Наверху:
/// добавить/удалить/корзина(бейдж)/фильтр избранного/комментарии
/// текущего выстрела (скрыты в режиме "только просмотр" — раздел 7 ТЗ).
/// Список разбит на группы по сериям, тап по строке — выбрать и закрыть.
/// Свайп по строке вправо/влево — в избранное/из избранного.
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
  bool _favoritesOnly = false;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final shots = vm.session.shots;
    final grouped = <int, List<Shot>>{};
    for (final s in shots) {
      grouped.putIfAbsent(s.seriesNo, () => []).add(s);
    }
    final seriesNumbers = grouped.keys.toList()..sort();

    return SafeArea(
      child: Column(
        children: [
          _Header(favoritesOnly: _favoritesOnly, onToggleFavorites: () => setState(() => _favoritesOnly = !_favoritesOnly)),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: seriesNumbers.length,
              itemBuilder: (context, i) {
                final seriesNo = seriesNumbers[i];
                final seriesShots = grouped[seriesNo]!;
                final sum = seriesShots.fold(0.0, (a, s) => a + s.score); // сумма по ВСЕЙ серии, фильтр не сужает
                final visibleRows = _favoritesOnly ? seriesShots.where((s) => s.isFavorite).toList() : seriesShots;
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
                          vm.exercise.specFor(seriesNo)?.name ?? 'Серия $seriesNo',
                          '${seriesShots.length} выстр.',
                          'Σ ${sum.toStringAsFixed(1)}',
                          if (!vm.exercise.countsSeries(seriesNo)) 'без зачёта',
                        ].join(' · '),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    for (final shot in visibleRows)
                      Dismissible(
                        key: ValueKey(shot.id),
                        // Фон свайпа "в избранное" — янтарный контейнер
                        // темы вместо жёсткого Colors.amber: в тёмной
                        // теме иконка на ярко-жёлтом не читалась.
                        background: Container(
                          color: Theme.of(context).colorScheme.secondaryContainer,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.only(left: 16),
                          child: Icon(Icons.star, color: Theme.of(context).colorScheme.onSecondaryContainer),
                        ),
                        secondaryBackground: Container(
                          color: Theme.of(context).colorScheme.secondaryContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: Icon(Icons.star_border, color: Theme.of(context).colorScheme.onSecondaryContainer),
                        ),
                        confirmDismiss: (_) async {
                          vm.toggleFavorite(shot.id);
                          return false; // не удаляем строку, только переключаем избранное
                        },
                        child: ListTile(
                          title: Text(shot.score.toStringAsFixed(1)),
                          subtitle: Text('X:${shot.xMm.toStringAsFixed(1)} Y:${shot.yMm.toStringAsFixed(1)}'),
                          trailing: Icon(shot.isFavorite ? Icons.star : Icons.star_border, size: 18),
                          onTap: () {
                            vm.selectIndex(vm.session.shots.indexOf(shot));
                            Navigator.of(context).pop();
                          },
                        ),
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

class _Header extends StatelessWidget {
  final bool favoritesOnly;
  final VoidCallback onToggleFavorites;

  const _Header({required this.favoritesOnly, required this.onToggleFavorites});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          // «Добавить» и «Удалить последний» убраны: выстрел ставится
          // на мишени, а удаление — свайпом по строке списка. Кнопка
          // «удалить текущий» в шапке к тому же била по выбранному
          // выстрелу, а не по тому, на который смотрит палец.
          if (vm.canEdit)
            Badge(
              label: Text('${vm.session.trash.length}'),
              isLabelVisible: vm.session.trash.isNotEmpty,
              child: IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Корзина',
                onPressed: () => TrashSheet.show(context),
              ),
            ),
          IconButton(
            icon: Icon(favoritesOnly ? Icons.star : Icons.star_border),
            tooltip: 'Только избранное',
            onPressed: onToggleFavorites,
          ),
          if (vm.selectedShot != null)
            IconButton(
              icon: const Icon(Icons.comment_outlined),
              tooltip: 'Комментарии к выстрелу',
              onPressed: () => CommentsThreadSheet.showForShot(context, vm.selectedShot!.id),
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
