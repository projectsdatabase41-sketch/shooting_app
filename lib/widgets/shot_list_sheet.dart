import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/shot.dart';
import '../state/target_view_model.dart';
import 'comments_thread.dart';
import 'trash_sheet.dart';

/// Шторка списка выстрелов (раздел 5 ТЗ) — 85% высоты экрана. Наверху:
/// корзина(бейдж)/фильтр избранного/комментарии текущего выстрела
/// (скрыты в режиме "только просмотр" — раздел 7 ТЗ). Список разбит на
/// группы по сериям, тап по строке — выбрать и закрыть.
///
/// У каждой строки — две отдельные кнопки, «в избранное» и «удалить»
/// (решение пользователя, взамен свайпа): свайп по строке в списке,
/// который и так прокручивается и открывается снизу вверх, слишком
/// легко путался с прокруткой и с закрытием шторки.
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
                      ListTile(
                        key: ValueKey(shot.id),
                        // Номер — исходный, из shot.shotNumber: при фильтре
                        // "только избранное" строки не идут подряд, и без
                        // номера непонятно, каким по счёту был выстрел
                        // (раздел 19 старого ТЗ — этого не хватало).
                        title: Text('№${shot.shotNumber} · ${shot.score.toStringAsFixed(1)}'),
                        subtitle: Text('X:${shot.xMm.toStringAsFixed(1)} Y:${shot.yMm.toStringAsFixed(1)}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: Icon(shot.isFavorite ? Icons.star : Icons.star_border),
                              tooltip: shot.isFavorite ? 'Убрать из избранного' : 'В избранное',
                              onPressed: () => vm.toggleFavorite(shot.id),
                            ),
                            if (vm.canEdit)
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Удалить',
                                onPressed: () => vm.deleteShot(shot.id),
                              ),
                          ],
                        ),
                        onTap: () {
                          vm.selectIndex(vm.session.shots.indexOf(shot));
                          Navigator.of(context).pop();
                        },
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
