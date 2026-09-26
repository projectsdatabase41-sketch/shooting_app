import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../logic/scoring.dart';
import '../models/shot.dart';
import '../state/target_view_model.dart';
import 'comments_thread.dart';
import '../i18n/i18n.dart';

/// Меню действий над ОДНИМ выстрелом — открывается долгим нажатием на
/// строку в `ShotListSheet` (решение пользователя, пункт 8 списка
/// правок). Явно НЕ свайп: свайп по строке уже пробовали раньше для
/// удаления и убрали — он путался с прокруткой списка и с закрытием
/// шторки снизу вверх (см. комментарий в `shot_list_sheet.dart`).
class ShotActionsSheet extends StatelessWidget {
  final Shot shot;

  const ShotActionsSheet({super.key, required this.shot});

  static Future<void> show(BuildContext context, Shot shot) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<TargetViewModel>(),
        child: ShotActionsSheet(shot: shot),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<TargetViewModel>();
    // Выстрел мог уже уйти в корзину/измениться, пока меню открыто было
    // (маловероятно, но дешевле перечитать по id, чем держать снимок).
    final current = vm.session.shots.where((s) => s.id == shot.id).firstOrNull ?? shot;
    final hour = clockDirection(current);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              tr('Выстрел №{shotNumber} · {p} · {hour} ч', {'shotNumber': current.shotNumber, 'p': current.score.toStringAsFixed(1), 'hour': hour}),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.remove_red_eye_outlined),
            title: Text(tr('Посмотреть выстрел на мишени')),
            onTap: () {
              Navigator.of(context).pop();
              vm.selectAndJumpToTarget(vm.session.shots.indexWhere((s) => s.id == current.id));
            },
          ),
          ListTile(
            leading: const Icon(Icons.notes_outlined),
            title: Text(tr('Заметка')),
            onTap: () {
              Navigator.of(context).pop();
              CommentsThreadSheet.showForShot(context, current.id);
            },
          ),
          ListTile(
            leading: Icon(current.isFavorite ? Icons.star : Icons.star_border),
            title: Text(current.isFavorite ? tr('Убрать из избранного') : tr('Избранное')),
            onTap: () {
              vm.toggleFavorite(current.id);
              Navigator.of(context).pop();
            },
          ),
          if (vm.canEditShots)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(tr('Удалить')),
              onTap: () {
                vm.deleteShot(current.id);
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
