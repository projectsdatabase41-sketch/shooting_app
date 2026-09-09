import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/target_view_model.dart';

/// Список избранных выстрелов текущей тренировки — открывается кнопкой
/// со звёздочкой в шапке `ShotListSheet` (решение пользователя, пункт 8
/// списка правок: звёздочка и корзина в шапке ОТКРЫВАЮТ списки, а не
/// просто фильтруют текущий на месте). Тот же принцип, что `TrashSheet`.
class FavoritesSheet extends StatelessWidget {
  const FavoritesSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<TargetViewModel>(),
        child: const FavoritesSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    final favorites = vm.session.shots.where((s) => s.isFavorite).toList();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                Text('Избранное', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
          ),
          if (favorites.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('Пусто'))
          else
            ...favorites.map((shot) => ListTile(
                  leading: const Icon(Icons.star, color: Colors.amber),
                  title: Text('№${shot.shotNumber} · ${shot.score.toStringAsFixed(1)}'),
                  subtitle: Text('X:${shot.xMm.toStringAsFixed(1)} Y:${shot.yMm.toStringAsFixed(1)}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.star_border),
                    tooltip: 'Убрать из избранного',
                    onPressed: () => vm.toggleFavorite(shot.id),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    vm.selectAndJumpToTarget(vm.session.shots.indexOf(shot));
                  },
                )),
        ],
      ),
    );
  }
}
