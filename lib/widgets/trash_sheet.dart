import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/target_view_model.dart';

/// Корзина удалённых выстрелов текущей тренировки (раздел 5 ТЗ, часть
/// B.5). "Вернуть" на каждый выстрел, "Очистить" для ручной окончательной
/// очистки. Автоматически и безвозвратно очищается при "Завершить".
class TrashSheet extends StatelessWidget {
  const TrashSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<TargetViewModel>(),
        child: const TrashSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Text('Корзина', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                TextButton(
                  onPressed: vm.session.trash.isEmpty ? null : vm.clearTrash,
                  child: const Text('Очистить'),
                ),
              ],
            ),
          ),
          if (vm.session.trash.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('Пусто')),
          ...vm.session.trash.map((shot) => ListTile(
                title: Text('Выстрел ${shot.shotNumber} · ${shot.score.toStringAsFixed(1)}'),
                subtitle: Text('X:${shot.xMm.toStringAsFixed(1)} Y:${shot.yMm.toStringAsFixed(1)}'),
                trailing: TextButton(
                  onPressed: () => vm.restoreFromTrash(shot.id),
                  child: const Text('Вернуть'),
                ),
              )),
        ],
      ),
    );
  }
}
